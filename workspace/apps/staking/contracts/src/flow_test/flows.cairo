use core::num::traits::Zero;
use snforge_std::start_cheat_block_number_global;
use staking::constants::{MIN_ATTESTATION_WINDOW, PREV_CONTRACT_VERSION, STRK_IN_FRIS};
use staking::errors::GenericError;
use staking::flow_test::utils::MainnetClassHashes::MAINNET_POOL_CLASS_HASH_V0;
use staking::flow_test::utils::{
    AttestationTrait, Delegator, FlowTrait, RewardSupplierTrait, Staker, StakingTrait,
    SystemDelegatorTrait, SystemPoolTrait, SystemStakerTrait, SystemState, SystemTrait, SystemType,
    upgrade_implementation,
};
use staking::pool::errors::Error as PoolError;
use staking::pool::interface_v0::{
    PoolMemberInfo, PoolMemberInfoIntoInternalPoolMemberInfoV1Trait, PoolMemberInfoTrait,
};
use staking::staking::errors::Error as StakingError;
use staking::staking::interface::{StakerInfoV1, StakerInfoV1Trait};
use staking::staking::interface_v0::{StakerInfo, StakerInfoTrait};
use staking::staking::objects::{EpochInfoTrait, StakerInfoIntoInternalStakerInfoV1ITrait};
use staking::test_utils::constants::{EPOCH_DURATION, UPGRADE_GOVERNOR};
use staking::test_utils::{
    calculate_block_offset, calculate_pool_member_rewards, calculate_pool_rewards,
    calculate_pool_rewards_with_pool_balance, declare_pool_contract, declare_pool_eic_contract,
    deserialize_option, pool_update_rewards, staker_update_old_rewards,
};
use staking::types::{Amount, Commission, Index};
use staking::utils::{compute_rewards_per_strk, compute_rewards_rounded_down};
use starknet::{ClassHash, ContractAddress, Store};
use starkware_utils::components::replaceability::interface::{EICData, ImplementationData};
use starkware_utils::errors::{Describable, ErrorDisplay};
use starkware_utils::math::abs::wide_abs_diff;
use starkware_utils::types::time::time::Time;
use starkware_utils_testing::test_utils::{
    TokenTrait, assert_panic_with_error, cheat_caller_address_once, set_account_as_upgrade_governor,
};
/// Flow - Basic Stake:
/// Staker - Stake with pool - cover if pool_enabled=true
/// Staker increase_stake - cover if pool amount = 0 in calc_rew
/// Delegator delegate (and create) to Staker
/// Staker increase_stake - cover pool amount > 0 in calc_rew
/// Delegator increase_delegate
/// Exit and check
#[derive(Drop, Copy)]
pub(crate) struct BasicStakeFlow {}
pub(crate) impl BasicStakeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<BasicStakeFlow, TTokenState> {
    fn get_pool_address(self: BasicStakeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: BasicStakeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: BasicStakeFlow, ref system: SystemState<TTokenState>) {}

    fn test(self: BasicStakeFlow, ref system: SystemState<TTokenState>, system_type: SystemType) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let staker = system.new_staker(amount: stake_amount * 2);
        system.stake(:staker, amount: stake_amount, pool_enabled: true, commission: 200);
        system.advance_epoch_and_attest(:staker);

        system.increase_stake(:staker, amount: stake_amount / 2);
        system.advance_epoch_and_attest(:staker);

        let pool = system.staking.get_pool(:staker);
        let delegator = system.new_delegator(amount: stake_amount);
        system.delegate(:delegator, :pool, amount: stake_amount / 2);
        system.advance_epoch_and_attest(:staker);

        system.increase_stake(:staker, amount: stake_amount / 4);
        system.advance_epoch_and_attest(:staker);

        system.increase_delegate(:delegator, :pool, amount: stake_amount / 4);
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: stake_amount * 3 / 4);
        system.advance_epoch_and_attest(:staker);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());

        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);
        system.staker_exit_action(:staker);

        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: pool) < 100);
        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount * 2);
        assert!(system.token.balance_of(account: delegator.delegator.address) == stake_amount);
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address)
                + system.token.balance_of(account: pool),
        );
    }
}

/// Flow:
/// Staker Stake
/// Delegator delegate
/// Staker exit_intent
/// Staker exit_action
/// Delegator partially exit_intent
/// Delegator exit_action
/// Delegator exit_intent
/// Delegator exit_action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorIntentAfterStakerActionFlow {}
pub(crate) impl DelegatorIntentAfterStakerActionFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorIntentAfterStakerActionFlow, TTokenState> {
    fn get_pool_address(self: DelegatorIntentAfterStakerActionFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: DelegatorIntentAfterStakerActionFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorIntentAfterStakerActionFlow, ref system: SystemState<TTokenState>,
    ) {}

    fn test(
        self: DelegatorIntentAfterStakerActionFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let pool = system.staking.get_pool(:staker);
        let delegator = system.new_delegator(amount: stake_amount);
        system.delegate(:delegator, :pool, amount: stake_amount);
        system.advance_epoch_and_attest(:staker);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());

        system.staker_exit_action(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: stake_amount / 2);
        system.delegator_exit_action(:delegator, :pool);

        system.delegator_exit_intent(:delegator, :pool, amount: stake_amount / 2);
        system.delegator_exit_action(:delegator, :pool);

        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(
            system.token.balance_of(account: pool) > 100,
        ); // TODO: Change this after implement calculate_rewards.
        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount * 2);
        assert!(system.token.balance_of(account: delegator.delegator.address) == stake_amount);
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());
        assert!(
            system.token.balance_of(account: delegator.reward.address).is_zero(),
        ); // TODO: Change this after implement calculate_rewards.
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address)
                + system.token.balance_of(account: pool),
        );
    }
}

/// Flow:
/// Staker - Stake without pool - cover if pool_enabled=false
/// Staker increase_stake - cover if pool amount=none in update_rewards
/// Staker claim_rewards
/// Staker set_open_for_delegation
/// Delegator delegate - cover delegating after opening an initially closed pool
/// Exit and check
#[derive(Drop, Copy)]
pub(crate) struct SetOpenForDelegationFlow {}
pub(crate) impl SetOpenForDelegationFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<SetOpenForDelegationFlow, TTokenState> {
    fn get_pool_address(self: SetOpenForDelegationFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: SetOpenForDelegationFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: SetOpenForDelegationFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: SetOpenForDelegationFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let initial_stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: initial_stake_amount * 2);
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;

        system.stake(:staker, amount: initial_stake_amount, pool_enabled: false, :commission);
        system.advance_epoch_and_attest(:staker);

        system.increase_stake(:staker, amount: initial_stake_amount / 2);
        system.advance_epoch_and_attest(:staker);

        assert!(system.token.balance_of(account: staker.reward.address).is_zero());
        system.staker_claim_rewards(:staker);
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());

        let pool = system.set_open_for_delegation(:staker, :commission);
        system.advance_epoch_and_attest(:staker);

        let delegator = system.new_delegator(amount: initial_stake_amount);
        system.delegate(:delegator, :pool, amount: initial_stake_amount / 2);
        system.advance_epoch_and_attest(:staker);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());

        system.delegator_exit_intent(:delegator, :pool, amount: initial_stake_amount / 2);

        system.delegator_exit_action(:delegator, :pool);
        system.staker_exit_action(:staker);

        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(
            system.token.balance_of(account: pool) > 100,
        ); // TODO: Change this after implement calculate_rewards.
        assert!(
            system.token.balance_of(account: staker.staker.address) == initial_stake_amount * 2,
        );
        assert!(
            system.token.balance_of(account: delegator.delegator.address) == initial_stake_amount,
        );
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());
        assert!(
            system.token.balance_of(account: delegator.reward.address).is_zero(),
        ); // TODO: Change this after implement calculate_rewards.
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address)
                + system.token.balance_of(account: pool),
        );
    }
}

/// Flow:
/// Staker Stake
/// Delegator delegate
/// Delegator exit_intent partial amount
/// Delegator exit_intent with lower amount - cover lowering partial undelegate
/// Delegator exit_intent with zero amount - cover clearing an intent
/// Delegator exit_intent all amount
/// Delegator exit_action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorIntentFlow {}
pub(crate) impl DelegatorIntentFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorIntentFlow, TTokenState> {
    fn get_pool_address(self: DelegatorIntentFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: DelegatorIntentFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: DelegatorIntentFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: DelegatorIntentFlow, ref system: SystemState<TTokenState>, system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount);
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let pool = system.staking.get_pool(:staker);
        let delegated_amount = stake_amount;
        let delegator = system.new_delegator(amount: delegated_amount);
        system.delegate(:delegator, :pool, amount: delegated_amount);
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount / 2);
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount / 4);
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount / 2);
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: Zero::zero());
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.advance_epoch_and_attest(:staker);
        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);
        system.advance_epoch_and_attest(:staker);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: pool) < 100);
        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: delegator.delegator.address) == delegated_amount);
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address)
                + system.token.balance_of(account: pool),
        );
    }
}

// Flow 8:
// Staker1 stake
// Staker2 stake
// Delegator delegate to staker1's pool
// Staker1 exit_intent
// Delegator exit_intent - get current block_timestamp as exit time
// Staker1 exit_action - cover staker action with while having a delegator in intent
// Delegator switch part of intent to staker2's pool - cover switching from a dead staker (should
// not matter he is back alive)
// Delegator exit_action in staker1's original pool - cover delegator exit action with dead staker
// Delegator claim rewards in staker2's pool - cover delegator claim rewards with dead staker
// Delegator exit_intent for remaining amount in staker1's original pool (the staker is dead there)
// Delegator exit_action in staker1's original pool - cover full delegator exit with dead staker
// Staker1 exit_intent
// Staker2 exit_intent
// Staker1 exit_action
// Staker2 exit_action
// Delegator exit_intent for full amount in staker2's pool
// Delegator exit_action for full amount in staker2's pool
#[derive(Drop, Copy)]
pub(crate) struct OperationsAfterDeadStakerFlow {}
pub(crate) impl OperationsAfterDeadStakerFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<OperationsAfterDeadStakerFlow, TTokenState> {
    fn get_pool_address(self: OperationsAfterDeadStakerFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: OperationsAfterDeadStakerFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: OperationsAfterDeadStakerFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: OperationsAfterDeadStakerFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let delegated_amount = stake_amount;
        let staker1 = system.new_staker(amount: stake_amount);
        let staker2 = system.new_staker(amount: stake_amount);
        let delegator = system.new_delegator(amount: delegated_amount);
        let commission = 200;

        system.stake(staker: staker1, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(staker: staker1);

        system.stake(staker: staker2, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(staker: staker1);
        system.advance_epoch_and_attest(staker: staker2);

        let staker1_pool = system.staking.get_pool(staker: staker1);
        system.delegate(:delegator, pool: staker1_pool, amount: delegated_amount);
        system.advance_epoch_and_attest(staker: staker1);

        system.staker_exit_intent(staker: staker1);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.advance_epoch_and_attest(staker: staker2);

        // After the following, delegator has 1/2 in staker1, and 1/2 in intent.
        system.delegator_exit_intent(:delegator, pool: staker1_pool, amount: delegated_amount / 2);
        system.advance_epoch_and_attest(staker: staker2);

        system.staker_exit_action(staker: staker1);

        // After the following, delegator has delegated_amount / 2 in staker1, delegated_amount
        // / 4 in intent, and delegated_amount / 4 in staker2.
        let staker2_pool = system.staking.get_pool(staker: staker2);
        system
            .switch_delegation_pool(
                :delegator,
                from_pool: staker1_pool,
                to_staker: staker2.staker.address,
                to_pool: staker2_pool,
                amount: delegated_amount / 4,
            );
        system.advance_epoch_and_attest(staker: staker2);

        // After the following, delegator has delegated_amount / 2 in staker1, and
        // delegated_amount / 4 in staker2.
        system.delegator_exit_action(:delegator, pool: staker1_pool);
        system.advance_epoch_and_attest(staker: staker2);

        // Claim rewards from second pool and see that the rewards are increasing.
        assert!(system.token.balance_of(account: delegator.reward.address).is_zero());
        system.delegator_claim_rewards(:delegator, pool: staker2_pool);
        let delegator_reward_before_advance_epoch = system
            .token
            .balance_of(account: delegator.reward.address);
        assert!(delegator_reward_before_advance_epoch.is_non_zero());

        // Advance epoch and claim rewards again, and see that the rewards are increasing.
        system.advance_epoch();
        system.delegator_claim_rewards(:delegator, pool: staker2_pool);
        let delegator_reward_after_advance_epoch = system
            .token
            .balance_of(account: delegator.reward.address);
        assert!(delegator_reward_after_advance_epoch > delegator_reward_before_advance_epoch);

        // Advance epoch and attest.
        system.advance_epoch_and_attest(staker: staker2);
        system.advance_epoch();

        // After the following, delegator has delegated_amount / 4 in staker2.
        system.delegator_exit_intent(:delegator, pool: staker1_pool, amount: delegated_amount / 2);
        system.delegator_exit_action(:delegator, pool: staker1_pool);
        system.delegator_claim_rewards(:delegator, pool: staker1_pool);

        // Clean up and make all parties exit.
        system.staker_exit_intent(staker: staker2);
        system.advance_time(time: system.staking.get_exit_wait_window());

        system.staker_exit_action(staker: staker2);
        system.delegator_exit_intent(:delegator, pool: staker2_pool, amount: delegated_amount / 4);
        system.delegator_exit_action(:delegator, pool: staker2_pool);
        system.delegator_claim_rewards(:delegator, pool: staker2_pool);

        // ------------- Flow complete, now asserts -------------

        // Assert pools' balances are low.
        assert!(system.token.balance_of(account: staker1_pool) < 100);
        assert!(system.token.balance_of(account: staker2_pool) < 100);

        // Assert all staked amounts were transferred back.
        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: staker1.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: staker2.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: delegator.delegator.address) == delegated_amount);

        // Asserts reward addresses are not empty.
        assert!(system.token.balance_of(account: staker1.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: staker2.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());

        // Assert all funds that moved from rewards supplier, were moved to correct addresses.
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker1.reward.address)
                + system.token.balance_of(account: staker2.reward.address)
                + system.token.balance_of(account: delegator.reward.address)
                + system.token.balance_of(account: staker1_pool)
                + system.token.balance_of(account: staker2_pool),
        );
    }
}

// Flow:
// Staker stake with commission 100%
// Delegator delegate
// Staker update_commission to 0%
// Delegator exit_intent
// Delegator exit_action, should get rewards
// Staker exit_intent
// Staker exit_action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorDidntUpdateAfterStakerUpdateCommissionFlow {}
pub(crate) impl DelegatorDidntUpdateAfterStakerUpdateCommissionFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorDidntUpdateAfterStakerUpdateCommissionFlow, TTokenState> {
    fn get_pool_address(
        self: DelegatorDidntUpdateAfterStakerUpdateCommissionFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(
        self: DelegatorDidntUpdateAfterStakerUpdateCommissionFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorDidntUpdateAfterStakerUpdateCommissionFlow,
        ref system: SystemState<TTokenState>,
    ) {}

    fn test(
        self: DelegatorDidntUpdateAfterStakerUpdateCommissionFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let delegated_amount = stake_amount;
        let staker = system.new_staker(amount: stake_amount);
        let delegator = system.new_delegator(amount: delegated_amount);
        let commission = 10000;

        // Stake with commission 100%
        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        // Update commission to 0%
        system.update_commission(:staker, commission: Zero::zero());
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.advance_epoch_and_attest(:staker);
        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);

        // Clean up and make all parties exit.
        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        // ------------- Flow complete, now asserts -------------

        // Assert pool balance is zero.
        assert!(system.token.balance_of(account: pool) == 0);

        // Assert all staked amounts were transferred back.
        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: delegator.delegator.address) == delegated_amount);

        // Assert staker reward address is not empty.
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());

        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());

        // Assert all funds that moved from rewards supplier, were moved to correct addresses.
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address),
        );
    }
}

// Flow:
// Staker stake with commission 100%
// Delegator delegate
// Staker update_commission to 0%
// Delegator claim rewards
// Delegator exit_intent
// Delegator exit_action, should get rewards
// Staker exit_intent
// Staker exit_action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorUpdatedAfterStakerUpdateCommissionFlow {}
pub(crate) impl DelegatorUpdatedAfterStakerUpdateCommissionFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorUpdatedAfterStakerUpdateCommissionFlow, TTokenState> {
    fn get_pool_address(
        self: DelegatorUpdatedAfterStakerUpdateCommissionFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(
        self: DelegatorUpdatedAfterStakerUpdateCommissionFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorUpdatedAfterStakerUpdateCommissionFlow,
        ref system: SystemState<TTokenState>,
    ) {}

    fn test(
        self: DelegatorUpdatedAfterStakerUpdateCommissionFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let delegated_amount = stake_amount;
        let staker = system.new_staker(amount: stake_amount);
        let delegator = system.new_delegator(amount: delegated_amount);
        let commission = 10000;

        // Stake with commission 100%.
        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);
        system.advance_epoch_and_attest(:staker);
        assert!(system.token.balance_of(account: pool).is_zero());

        // Update commission to 0%.
        system.update_commission(:staker, commission: Zero::zero());
        system.advance_epoch_and_attest(:staker);
        assert!(system.token.balance_of(account: pool).is_non_zero());

        // Delegator claim_rewards.
        system.delegator_claim_rewards(:delegator, :pool);
        assert!(
            system.token.balance_of(account: delegator.reward.address) == Zero::zero(),
        ); // TODO: Change this after implement calculate_rewards.
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);

        // Clean up and make all parties exit.
        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        // ------------- Flow complete, now asserts -------------

        // Assert pool balance is high.
        assert!(system.token.balance_of(account: pool) > 100);

        // Assert all staked amounts were transferred back.
        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: delegator.delegator.address) == delegated_amount);

        // Asserts reward addresses are not empty.
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());

        // Assert all funds that moved from rewards supplier, were moved to correct addresses.
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address)
                + system.token.balance_of(account: pool),
        );
    }
}

/// Flow:
/// Staker Stake
/// Delegator delegate
/// Delegator exit_intent
/// Staker exit_intent
/// Staker exit_action
/// Delegator exit_action
#[derive(Drop, Copy)]
pub(crate) struct StakerIntentLastActionFirstFlow {}
pub(crate) impl StakerIntentLastActionFirstFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerIntentLastActionFirstFlow, TTokenState> {
    fn get_pool_address(self: StakerIntentLastActionFirstFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: StakerIntentLastActionFirstFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: StakerIntentLastActionFirstFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: StakerIntentLastActionFirstFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let initial_stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: initial_stake_amount * 2);
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;

        system.stake(:staker, amount: initial_stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let pool = system.staking.get_pool(:staker);
        let delegator = system.new_delegator(amount: initial_stake_amount);
        system.delegate(:delegator, :pool, amount: initial_stake_amount / 2);
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: initial_stake_amount / 2);
        system.advance_epoch_and_attest(:staker);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());

        system.staker_exit_action(:staker);

        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);

        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: pool) < 100);
        assert!(
            system.token.balance_of(account: staker.staker.address) == initial_stake_amount * 2,
        );
        assert!(
            system.token.balance_of(account: delegator.delegator.address) == initial_stake_amount,
        );
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address)
                + system.token.balance_of(account: pool),
        );
    }
}

/// Test InternalStakerInfo migration with staker_info function.
/// Flow:
/// Staker stake without pool
/// Upgrade
/// staker_info
#[derive(Drop, Copy)]
pub(crate) struct StakerInfoAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) staker_info: Option<StakerInfo>,
}
pub(crate) impl StakerInfoAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerInfoAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: StakerInfoAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: StakerInfoAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::Some(self.staker.unwrap().staker.address)
    }

    fn setup(ref self: StakerInfoAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: false, :commission);

        let staker_info = system.staker_info(:staker);

        self.staker = Option::Some(staker);
        self.staker_info = Option::Some(staker_info);

        system.advance_time(time: one_week);
        system.staking.update_global_index_if_needed();
    }

    fn test(
        self: StakerInfoAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker_info_after_upgrade = system.staker_info_v1(staker: self.staker.unwrap());
        let expected_staker_info = staker_update_old_rewards(
            staker_info: self.staker_info.unwrap(), global_index: system.staking.get_global_index(),
        )
            .to_v1();
        assert!(staker_info_after_upgrade == expected_staker_info);
    }
}

/// Test InternalStakerInfo migration with staker_info function.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// staker_info
#[derive(Drop, Copy)]
pub(crate) struct StakerInfoWithPoolAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) staker_info: Option<StakerInfo>,
    pub(crate) pool_address: Option<ContractAddress>,
}
pub(crate) impl StakerInfoWithPoolAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerInfoWithPoolAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: StakerInfoWithPoolAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: StakerInfoWithPoolAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: StakerInfoWithPoolAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        let staker_info = system.staker_info(:staker);

        self.staker = Option::Some(staker);
        self.staker_info = Option::Some(staker_info);
        self.pool_address = Option::Some(pool);

        system.advance_time(time: one_week);
        system.staking.update_global_index_if_needed();
    }

    fn test(
        self: StakerInfoWithPoolAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker_info_after_upgrade = system.staker_info_v1(staker: self.staker.unwrap());
        let mut expected_staker_info = staker_update_old_rewards(
            staker_info: self.staker_info.unwrap(), global_index: system.staking.get_global_index(),
        )
            .to_v1();
        assert!(staker_info_after_upgrade == expected_staker_info);
    }
}

/// Test InternalStakerInfo migration with staker_info function.
/// Flow:
/// Staker stake with pool
/// Staker unstake_intent
/// Upgrade
/// staker_info
#[derive(Drop, Copy)]
pub(crate) struct StakerInfoUnstakeAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) staker_info: Option<StakerInfo>,
    pub(crate) pool_address: Option<ContractAddress>,
}
pub(crate) impl StakerInfoUnstakeAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerInfoUnstakeAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: StakerInfoUnstakeAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: StakerInfoUnstakeAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: StakerInfoUnstakeAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        system.advance_time(time: one_week);

        system.staker_exit_intent(:staker);

        let staker_info = system.staker_info(:staker);

        self.staker = Option::Some(staker);
        self.staker_info = Option::Some(staker_info);
        self.pool_address = Option::Some(system.staking.get_pool(:staker));

        system.advance_time(time: one_week);
    }

    fn test(
        self: StakerInfoUnstakeAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker_info_after_upgrade = system.staker_info_v1(staker: self.staker.unwrap());
        let mut expected_staker_info = self.staker_info.unwrap();
        expected_staker_info.index = Zero::zero();
        assert!(staker_info_after_upgrade == expected_staker_info.to_v1());
    }
}

/// Test InternalStakerInfo migration with internal_staker_info function.
/// Flow:
/// Staker stake without pool
/// Upgrade
/// internal_staker_info
#[derive(Drop, Copy)]
pub(crate) struct InternalStakerInfoAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) staker_info: Option<StakerInfo>,
}
pub(crate) impl InternalStakerInfoAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<InternalStakerInfoAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: InternalStakerInfoAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: InternalStakerInfoAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::Some(self.staker.unwrap().staker.address)
    }

    fn setup(ref self: InternalStakerInfoAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: false, :commission);

        let staker_info = system.staker_info(:staker);

        self.staker = Option::Some(staker);
        self.staker_info = Option::Some(staker_info);

        system.advance_time(time: one_week);
        system.staking.update_global_index_if_needed();
    }

    fn test(
        self: InternalStakerInfoAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let internal_staker_info_after_upgrade = system
            .internal_staker_info(staker: self.staker.unwrap());
        let global_index = system.staking.get_global_index();
        let mut expected_staker_info = staker_update_old_rewards(
            staker_info: self.staker_info.unwrap(), :global_index,
        )
            .to_v1();
        assert!(internal_staker_info_after_upgrade == expected_staker_info.to_internal());
    }
}

/// Test InternalStakerInfo migration with internal_staker_info function.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// internal_staker_info
#[derive(Drop, Copy)]
pub(crate) struct InternalStakerInfoWithPoolAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) staker_info: Option<StakerInfo>,
    pub(crate) pool_address: Option<ContractAddress>,
}
pub(crate) impl InternalStakerInfoWithPoolAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<InternalStakerInfoWithPoolAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(
        self: InternalStakerInfoWithPoolAfterUpgradeFlow,
    ) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(
        self: InternalStakerInfoWithPoolAfterUpgradeFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: InternalStakerInfoWithPoolAfterUpgradeFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        let staker_info = system.staker_info(:staker);

        self.staker = Option::Some(staker);
        self.staker_info = Option::Some(staker_info);
        self.pool_address = Option::Some(pool);
        system.advance_time(time: one_week);
        system.staking.update_global_index_if_needed();
    }

    fn test(
        self: InternalStakerInfoWithPoolAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let internal_staker_info_after_upgrade = system
            .internal_staker_info(staker: self.staker.unwrap());
        let global_index = system.staking.get_global_index();
        let mut expected_staker_info = staker_update_old_rewards(
            staker_info: self.staker_info.unwrap(), :global_index,
        )
            .to_v1();
        assert!(internal_staker_info_after_upgrade == expected_staker_info.to_internal());
    }
}

/// Test InternalStakerInfo migration with internal_staker_info function.
/// Flow:
/// Staker stake with pool
/// Staker unstake_intent
/// Upgrade
/// internal_staker_info
#[derive(Drop, Copy)]
pub(crate) struct InternalStakerInfoUnstakeAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) staker_info: Option<StakerInfo>,
    pub(crate) pool_address: Option<ContractAddress>,
}
pub(crate) impl InternalStakerInfoUnstakeAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<InternalStakerInfoUnstakeAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(
        self: InternalStakerInfoUnstakeAfterUpgradeFlow,
    ) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(
        self: InternalStakerInfoUnstakeAfterUpgradeFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: InternalStakerInfoUnstakeAfterUpgradeFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        system.advance_time(time: one_week);

        system.staker_exit_intent(:staker);

        let staker_info = system.staker_info(:staker);

        self.staker = Option::Some(staker);
        self.staker_info = Option::Some(staker_info);
        self.pool_address = Option::Some(system.staking.get_pool(:staker));

        system.advance_time(time: one_week);
    }

    fn test(
        self: InternalStakerInfoUnstakeAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let internal_staker_info_after_upgrade = system
            .internal_staker_info(staker: self.staker.unwrap());
        let expected_staker_info: StakerInfoV1 = self.staker_info.unwrap().to_v1();
        assert!(internal_staker_info_after_upgrade == expected_staker_info.to_internal());
    }
}

/// Test pool upgrade flow.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// Delegator exit_intent
/// Delegator exit_action
#[derive(Drop, Copy)]
pub(crate) struct PoolUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegated_amount: Amount,
}
pub(crate) impl PoolUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolUpgradeFlow, TTokenState> {
    fn get_pool_address(self: PoolUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: PoolUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
        self.delegated_amount = delegated_amount;
    }

    fn test(self: PoolUpgradeFlow, ref system: SystemState<TTokenState>, system_type: SystemType) {
        let pool = self.pool_address.unwrap();
        let delegator = self.delegator.unwrap();
        let delegated_amount = self.delegated_amount;
        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.delegator_exit_action(:delegator, :pool);
        assert!(system.token.balance_of(account: pool) == Zero::zero());
        assert!(system.token.balance_of(account: delegator.delegator.address) == delegated_amount);
    }
}

/// Test pool member info migration with internal_pool_member_info, get_internal_pool_member_info
/// and pool_member_info_v1 functions.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// internal_pool_member_info & get_internal_pool_member_info & pool_member_info_v1
#[derive(Drop, Copy)]
pub(crate) struct PoolMemberInfoAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegator_info: Option<PoolMemberInfo>,
}
pub(crate) impl PoolMemberInfoAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolMemberInfoAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: PoolMemberInfoAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: PoolMemberInfoAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolMemberInfoAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        let delegator_info = system.pool_member_info(:delegator, :pool);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
        self.delegator_info = Option::Some(delegator_info);

        system.advance_time(time: one_week);
        system.staking.update_global_index_if_needed();
    }

    fn test(
        self: PoolMemberInfoAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let delegator = self.delegator.unwrap();
        let pool = self.pool_address.unwrap();
        let pool_member_info = system.pool_member_info_v1(:delegator, :pool);
        let internal_pool_member_info_after_upgrade = system
            .internal_pool_member_info(:delegator, :pool);
        let get_internal_pool_member_info_after_upgrade = system
            .get_internal_pool_member_info(:delegator, :pool);
        let expected_pool_member_info = pool_update_rewards(
            pool_member_info: self.delegator_info.unwrap(),
            updated_index: system.staking.get_global_index(),
        );
        assert!(pool_member_info == expected_pool_member_info.to_v1());
        assert!(internal_pool_member_info_after_upgrade == expected_pool_member_info.to_internal());
        assert!(
            get_internal_pool_member_info_after_upgrade == Option::Some(
                expected_pool_member_info.to_internal(),
            ),
        );
    }
}

/// Test pool member info migration with internal_pool_member_info, get_internal_pool_member_info
/// and pool_member_info_v1 functions.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Delegator exit_intent
/// Upgrade
/// internal_pool_member_info & get_internal_pool_member_info & pool_member_info_v1
#[derive(Drop, Copy)]
pub(crate) struct PoolMemberInfoUndelegateAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegator_info: Option<PoolMemberInfo>,
}
pub(crate) impl PoolMemberInfoUndelegateAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolMemberInfoUndelegateAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: PoolMemberInfoUndelegateAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(
        self: PoolMemberInfoUndelegateAfterUpgradeFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: PoolMemberInfoUndelegateAfterUpgradeFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        system.advance_time(time: one_week);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);

        let delegator_info = system.pool_member_info(:delegator, :pool);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
        self.delegator_info = Option::Some(delegator_info);

        system.advance_time(time: one_week);
    }

    fn test(
        self: PoolMemberInfoUndelegateAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let delegator = self.delegator.unwrap();
        let pool = self.pool_address.unwrap();
        let pool_member_info = system.pool_member_info_v1(:delegator, :pool);
        let internal_pool_member_info_after_upgrade = system
            .internal_pool_member_info(:delegator, :pool);
        let get_internal_pool_member_info_after_upgrade = system
            .get_internal_pool_member_info(:delegator, :pool);
        let mut expected_pool_member_info = self.delegator_info.unwrap();
        expected_pool_member_info.index = system.staking.get_global_index();
        assert!(pool_member_info == expected_pool_member_info.to_v1());
        assert!(internal_pool_member_info_after_upgrade == expected_pool_member_info.to_internal());
        assert!(
            get_internal_pool_member_info_after_upgrade == Option::Some(
                expected_pool_member_info.to_internal(),
            ),
        );
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// Delegator increase delegate
#[derive(Drop, Copy)]
pub(crate) struct IncreaseDelegationAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegated_amount: Option<Amount>,
}
pub(crate) impl IncreaseDelegationAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<IncreaseDelegationAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: IncreaseDelegationAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: IncreaseDelegationAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: IncreaseDelegationAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let delegated_amount = stake_amount;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegator = system.new_delegator(amount: delegated_amount * 2);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
        self.delegated_amount = Option::Some(delegated_amount);
    }

    fn test(
        self: IncreaseDelegationAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let delegator = self.delegator.unwrap();
        let pool = self.pool_address.unwrap();
        let delegated_amount = self.delegated_amount.unwrap();
        system.increase_delegate(:delegator, :pool, amount: delegated_amount);

        let delegator_info = system.pool_member_info_v1(:delegator, :pool);
        assert!(delegator_info.amount == delegated_amount * 2);
    }
}

/// Flow:
/// Staker stake with pool
/// Upgrade
/// Staker increase_stake
#[derive(Drop, Copy)]
pub(crate) struct IncreaseStakeAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) stake_amount: Option<Amount>,
    pub(crate) pool_address: Option<ContractAddress>,
}
pub(crate) impl IncreaseStakeAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<IncreaseStakeAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: IncreaseStakeAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: IncreaseStakeAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: IncreaseStakeAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        self.staker = Option::Some(staker);
        self.stake_amount = Option::Some(stake_amount);
        let pool = system.staking.get_pool(:staker);
        self.pool_address = Option::Some(pool);
    }

    fn test(
        self: IncreaseStakeAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let stake_amount = self.stake_amount.unwrap();
        system.increase_stake(:staker, amount: stake_amount);

        let staker_info = system.staker_info_v1(:staker);
        assert!(staker_info.amount_own == stake_amount * 2);
    }
}

/// Test
/// Test delegator exit pool and enter again.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Attest
/// Attest
/// Attest
/// Delagator exit intent
/// Delegator exit action
/// Delegator delegate with the same address
/// Attest
/// Attest
/// Delegator claim rewards
/// Staker exit intent
/// Delegator exit intent
/// Staker exit action
/// Delegator exit action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorExitAndEnterAgainFlow {}
pub(crate) impl DelegatorExitAndEnterAgainFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorExitAndEnterAgainFlow, TTokenState> {
    fn get_pool_address(self: DelegatorExitAndEnterAgainFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: DelegatorExitAndEnterAgainFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: DelegatorExitAndEnterAgainFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: DelegatorExitAndEnterAgainFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let initial_stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: initial_stake_amount * 2);
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;
        let staking_contract = system.staking.address;
        let minting_curve_contract = system.minting_curve.address;

        system.stake(:staker, amount: initial_stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let pool = system.staking.get_pool(:staker);
        let delegator = system.new_delegator(amount: initial_stake_amount);
        let delegated_amount = initial_stake_amount / 2;
        system.delegate(:delegator, :pool, amount: delegated_amount);
        system.advance_epoch_and_attest(:staker);
        // Calculate pool rewards.
        let pool_rewards_epoch = calculate_pool_rewards(
            staker_address: staker.staker.address, :staking_contract, :minting_curve_contract,
        );
        system.advance_epoch_and_attest(:staker);
        system.advance_epoch_and_attest(:staker);

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);

        system.advance_epoch_and_attest(:staker);

        system.advance_exit_wait_window();

        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);

        let delegator_rewards_after_exit = system
            .token
            .balance_of(account: delegator.reward.address);

        assert!(delegator_rewards_after_exit == pool_rewards_epoch * 3);

        // Enter again in the same epoch of exit action.
        system.increase_delegate(:delegator, :pool, amount: delegated_amount);
        system.advance_epoch_and_attest(:staker);

        system.advance_epoch_and_attest(:staker);

        let rewards_from_claim = system.delegator_claim_rewards(:delegator, :pool);
        // Rewards claimed up to but not including current epoch rewards.
        assert!(rewards_from_claim == pool_rewards_epoch);
        assert!(
            system
                .token
                .balance_of(account: delegator.reward.address) == delegator_rewards_after_exit
                + pool_rewards_epoch,
        );

        // Staker and delegator exit.

        system.staker_exit_intent(:staker);
        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);

        system.advance_exit_wait_window();

        system.staker_exit_action(:staker);
        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);

        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: pool) == 0);
        assert!(
            system.token.balance_of(account: staker.staker.address) == initial_stake_amount * 2,
        );
        assert!(
            system.token.balance_of(account: delegator.delegator.address) == initial_stake_amount,
        );
        assert!(system.token.balance_of(account: staker.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address),
        );
    }
}


/// Test delegator exit pool and enter again with switch.
/// Flow:
/// Staker1 stake with pool1
/// Staker2 stake with pool2
/// Staker1 attest
/// Delegator delegate pool1
/// Staker1 attest
/// Staker1 attest
/// Staker1 attest
/// Delagator exit intent pool1
/// Delegator full switch to pool2
/// Delegator claim rewards pool1
/// Delegator exit intent pool2
/// Delegator full switch to pool1
/// Staker1 attest
/// Staker1 attest
/// Delegator claim rewards pool1
/// Staker1 exit intent
/// Delegator exit intent pool1
/// Staker1 exit action
/// Delegator exit action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorExitAndEnterAgainWithSwitchFlow {}
pub(crate) impl DelegatorExitAndEnterAgainWithSwitchFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorExitAndEnterAgainWithSwitchFlow, TTokenState> {
    fn get_pool_address(self: DelegatorExitAndEnterAgainWithSwitchFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(
        self: DelegatorExitAndEnterAgainWithSwitchFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorExitAndEnterAgainWithSwitchFlow, ref system: SystemState<TTokenState>,
    ) {}

    fn test(
        self: DelegatorExitAndEnterAgainWithSwitchFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let initial_stake_amount = min_stake * 2;
        let staker1 = system.new_staker(amount: initial_stake_amount * 2);
        let staker2 = system.new_staker(amount: initial_stake_amount * 2);
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;
        let staking_contract = system.staking.address;
        let minting_curve_contract = system.minting_curve.address;

        system
            .stake(staker: staker1, amount: initial_stake_amount, pool_enabled: true, :commission);
        system
            .stake(staker: staker2, amount: initial_stake_amount, pool_enabled: true, :commission);
        let pool1 = system.staking.get_pool(staker: staker1);
        let pool2 = system.staking.get_pool(staker: staker2);

        system.advance_epoch_and_attest(staker: staker1);

        let delegator = system.new_delegator(amount: initial_stake_amount);
        let delegated_amount = initial_stake_amount / 2;
        system.delegate(:delegator, pool: pool1, amount: delegated_amount);
        system.advance_epoch_and_attest(staker: staker1);
        // Calculate pool rewards.
        let pool_rewards_epoch = calculate_pool_rewards(
            staker_address: staker1.staker.address, :staking_contract, :minting_curve_contract,
        );
        system.advance_epoch_and_attest(staker: staker1);
        system.advance_epoch_and_attest(staker: staker1);

        system.delegator_exit_intent(:delegator, pool: pool1, amount: delegated_amount);

        system.advance_epoch_and_attest(staker: staker1);

        system
            .switch_delegation_pool(
                :delegator,
                from_pool: pool1,
                to_staker: staker2.staker.address,
                to_pool: pool2,
                amount: delegated_amount,
            );

        let rewards = system.delegator_claim_rewards(:delegator, pool: pool1);

        let delegator_rewards_after_exit = system
            .token
            .balance_of(account: delegator.reward.address);

        assert!(rewards == pool_rewards_epoch * 3);
        assert!(delegator_rewards_after_exit == pool_rewards_epoch * 3);

        // Switch back.
        system.delegator_exit_intent(:delegator, pool: pool2, amount: delegated_amount);

        system
            .switch_delegation_pool(
                :delegator,
                from_pool: pool2,
                to_staker: staker1.staker.address,
                to_pool: pool1,
                amount: delegated_amount,
            );

        system.advance_epoch_and_attest(staker: staker1);

        system.advance_epoch_and_attest(staker: staker1);

        let rewards_from_claim = system.delegator_claim_rewards(:delegator, pool: pool1);
        // Rewards claimed up to but not including current epoch rewards.
        assert!(rewards_from_claim == pool_rewards_epoch);
        assert!(
            system
                .token
                .balance_of(account: delegator.reward.address) == delegator_rewards_after_exit
                + pool_rewards_epoch,
        );

        // Staker 1 and delegator exit.

        system.staker_exit_intent(staker: staker1);
        system.delegator_exit_intent(:delegator, pool: pool1, amount: delegated_amount);

        system.advance_exit_wait_window();

        system.staker_exit_action(staker: staker1);
        system.delegator_exit_action(:delegator, pool: pool1);
        system.delegator_claim_rewards(:delegator, pool: pool1);
        system.delegator_claim_rewards(:delegator, pool: pool2);

        assert!(system.token.balance_of(account: pool1) == 0);
        assert!(
            system.token.balance_of(account: staker1.staker.address) == initial_stake_amount * 2,
        );
        assert!(
            system.token.balance_of(account: delegator.delegator.address) == initial_stake_amount,
        );
        assert!(system.token.balance_of(account: staker1.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker1.reward.address)
                + system.token.balance_of(account: delegator.reward.address),
        );
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Delegator full exit_intent
/// Upgrade
/// Delegator exit_action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorActionAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
}
pub(crate) impl DelegatorActionAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorActionAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: DelegatorActionAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: DelegatorActionAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: DelegatorActionAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);
        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
    }

    fn test(
        self: DelegatorActionAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let pool = self.pool_address.unwrap();
        let delegator = self.delegator.unwrap();

        let result = system.safe_delegator_exit_action(:delegator, :pool);
        assert_panic_with_error(
            :result, expected_error: GenericError::INTENT_WINDOW_NOT_FINISHED.describe(),
        );

        system.advance_time(time: system.staking.get_exit_wait_window());
        system.delegator_exit_action(:delegator, :pool);
        system.delegator_claim_rewards(:delegator, :pool);

        let pool_member_info = system.pool_member_info_v1(:delegator, :pool);
        assert!(pool_member_info.amount.is_zero());
        assert!(pool_member_info.unclaimed_rewards.is_zero());
        assert!(pool_member_info.unpool_amount.is_zero());
        assert!(pool_member_info.unpool_time.is_none());
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// Delegator exit_intent
#[derive(Drop, Copy)]
pub(crate) struct DelegatorIntentAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegated_amount: Option<Amount>,
}
pub(crate) impl DelegatorIntentAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorIntentAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: DelegatorIntentAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: DelegatorIntentAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: DelegatorIntentAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegator = system.new_delegator(amount: stake_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: stake_amount);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
        self.delegated_amount = Option::Some(stake_amount);
    }

    fn test(
        self: DelegatorIntentAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let delegator = self.delegator.unwrap();
        let pool = self.pool_address.unwrap();
        let delegated_amount = self.delegated_amount.unwrap();
        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);

        let delegator_info = system.pool_member_info_v1(:delegator, :pool);
        assert!(delegator_info.unpool_amount == delegated_amount);
        assert!(delegator_info.amount.is_zero());
        assert!(delegator_info.unpool_time.is_some());
    }
}

/// Flow:
/// Staker stake with pool
/// Upgrade
/// Staker exit_intent
#[derive(Drop, Copy)]
pub(crate) struct StakerIntentAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) pool_address: Option<ContractAddress>,
}
pub(crate) impl StakerIntentAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerIntentAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: StakerIntentAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: StakerIntentAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: StakerIntentAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        self.staker = Option::Some(staker);
        let pool = system.staking.get_pool(:staker);
        self.pool_address = Option::Some(pool);
    }

    fn test(
        self: StakerIntentAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        system.staker_exit_intent(:staker);

        let staker_info = system.staker_info_v1(:staker);
        assert!(staker_info.unstake_time.is_some());
    }
}

/// Flow:
/// Staker stake with pool
/// Staker exit_intent
/// Upgrade
/// Staker exit_action
#[derive(Drop, Copy)]
pub(crate) struct StakerActionAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) pool_address: Option<ContractAddress>,
}

pub(crate) impl StakerActionAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerActionAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: StakerActionAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: StakerActionAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: StakerActionAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.staker_exit_intent(:staker);

        self.staker = Option::Some(staker);
        let pool = system.staking.get_pool(:staker);
        self.pool_address = Option::Some(pool);
    }

    fn test(
        self: StakerActionAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let staker_info = system.staker_info_v1(:staker);
        assert!(staker_info.unstake_time.is_some());

        let result = system.safe_staker_exit_action(:staker);
        assert_panic_with_error(
            :result, expected_error: GenericError::INTENT_WINDOW_NOT_FINISHED.describe(),
        );

        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        assert!(system.get_staker_info(:staker).is_none());
    }
}

/// Flow:
/// Staker stake
/// Staker exit_intent
/// Upgrade
/// Staker attest
#[derive(Drop, Copy)]
pub(crate) struct StakerAttestAfterIntentFlow {
    pub(crate) staker: Option<Staker>,
}

pub(crate) impl StakerAttestAfterIntentFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerAttestAfterIntentFlow, TTokenState> {
    fn get_pool_address(self: StakerAttestAfterIntentFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: StakerAttestAfterIntentFlow) -> Option<ContractAddress> {
        Option::Some(self.staker.unwrap().staker.address)
    }

    fn setup(ref self: StakerAttestAfterIntentFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: false, :commission);
        system.staker_exit_intent(:staker);

        self.staker = Option::Some(staker);
    }

    fn test(
        self: StakerAttestAfterIntentFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();

        system.advance_epoch_and_attest(:staker);
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// Delegator partial undelegate
/// Delegator switch
#[derive(Drop, Copy)]
pub(crate) struct DelegatorPartialIntentAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegated_amount: Option<Amount>,
}
pub(crate) impl DelegatorPartialIntentAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorPartialIntentAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: DelegatorPartialIntentAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: DelegatorPartialIntentAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorPartialIntentAfterUpgradeFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
        self.delegated_amount = Option::Some(delegated_amount);
    }

    fn test(
        self: DelegatorPartialIntentAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let delegator = self.delegator.unwrap();
        let pool = self.pool_address.unwrap();
        let delegated_amount = self.delegated_amount.unwrap();
        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount / 2);

        let commission = 200;
        let second_staker = system.new_staker(amount: delegated_amount);
        system
            .stake(
                staker: second_staker, amount: delegated_amount, pool_enabled: true, :commission,
            );
        let second_pool = system.staking.get_pool(staker: second_staker);
        system
            .switch_delegation_pool(
                :delegator,
                from_pool: pool,
                to_staker: second_staker.staker.address,
                to_pool: second_pool,
                amount: delegated_amount / 2,
            );

        let delegator_info_first_pool = system.pool_member_info_v1(:delegator, :pool);
        assert!(delegator_info_first_pool.amount == delegated_amount / 2);
        let delegator_info_second_pool = system.pool_member_info_v1(:delegator, pool: second_pool);
        assert!(delegator_info_second_pool.amount == delegated_amount / 2);
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// Change commission
#[derive(Drop, Copy)]
pub(crate) struct ChangeCommissionAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) commission: Option<Commission>,
}
pub(crate) impl ChangeCommissionAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<ChangeCommissionAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: ChangeCommissionAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: ChangeCommissionAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: ChangeCommissionAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        self.staker = Option::Some(staker);
        self.pool_address = Option::Some(pool);
        self.commission = Option::Some(commission);
    }

    fn test(
        self: ChangeCommissionAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let pool = self.pool_address.unwrap();
        let new_commission = self.commission.unwrap() - 1;
        system.update_commission(:staker, commission: new_commission);

        assert!(new_commission == system.contract_parameters_v1(:pool).commission);
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// Delegator claim rewards
#[derive(Drop, Copy)]
pub(crate) struct DelegatorClaimRewardsAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
}
pub(crate) impl DelegatorClaimRewardsAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorClaimRewardsAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: DelegatorClaimRewardsAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: DelegatorClaimRewardsAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorClaimRewardsAfterUpgradeFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);

        system.advance_time(time: one_week);
        system.staking.update_global_index_if_needed();
    }

    fn test(
        self: DelegatorClaimRewardsAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let pool = self.pool_address.unwrap();
        let delegator = self.delegator.unwrap();

        let unclaimed_rewards = system.pool_member_info_v1(:delegator, :pool).unclaimed_rewards;
        assert!(unclaimed_rewards == system.delegator_claim_rewards(:delegator, :pool));
        assert!(unclaimed_rewards == system.token.balance_of(account: delegator.reward.address));

        let unclaimed_rewards_after_claim = system
            .pool_member_info_v1(:delegator, :pool)
            .unclaimed_rewards;
        assert!(unclaimed_rewards_after_claim == Zero::zero());
    }
}

#[derive(Drop, Copy)]
pub(crate) struct PoolMigrationAssertionsFlow {
    pub(crate) staker_no_pool: Option<Staker>,
    pub(crate) staker_with_pool: Option<Staker>,
}
pub(crate) impl PoolMigrationAssertionsFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolMigrationAssertionsFlow, TTokenState> {
    fn get_pool_address(self: PoolMigrationAssertionsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: PoolMigrationAssertionsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolMigrationAssertionsFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker_no_pool = system.new_staker(amount: stake_amount * 2);
        system
            .stake(
                staker: staker_no_pool, amount: stake_amount, pool_enabled: false, commission: 200,
            );
        let staker_with_pool = system.new_staker(amount: stake_amount * 2);
        system
            .stake(
                staker: staker_with_pool, amount: stake_amount, pool_enabled: true, commission: 200,
            );
        self.staker_no_pool = Option::Some(staker_no_pool);
        self.staker_with_pool = Option::Some(staker_with_pool);
    }

    #[feature("safe_dispatcher")]
    fn test(
        self: PoolMigrationAssertionsFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        // Should catch MISSING_POOL_CONTRACT.
        let staker_no_pool = self.staker_no_pool.unwrap();
        let result = system.safe_dispatcher_pool_migration(staker: staker_no_pool);
        assert_panic_with_error(
            :result, expected_error: StakingError::MISSING_POOL_CONTRACT.describe(),
        );

        // Should catch CALLER_IS_NOT_POOL_CONTRACT.
        let staker_with_pool = self.staker_with_pool.unwrap();
        let result = system.safe_dispatcher_pool_migration(staker: staker_with_pool);
        assert_panic_with_error(
            :result, expected_error: StakingError::CALLER_IS_NOT_POOL_CONTRACT.describe(),
        );
    }
}

#[derive(Drop, Copy)]
pub(crate) struct PoolEICFlow {
    pub(crate) pool_address: Option<ContractAddress>,
}
pub(crate) impl PoolEICFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolEICFlow, TTokenState> {
    fn get_pool_address(self: PoolEICFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: PoolEICFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolEICFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        system.stake(staker: staker, amount: stake_amount, pool_enabled: true, commission: 200);
        let pool = system.staking.get_pool(:staker);
        self.pool_address = Option::Some(pool);
    }

    fn test(self: PoolEICFlow, ref system: SystemState<TTokenState>, system_type: SystemType) {
        let pool_contract = self.pool_address.unwrap();
        let upgrade_governor = UPGRADE_GOVERNOR();
        let pool_contract_admin = system.staking.get_pool_contract_admin();
        set_account_as_upgrade_governor(
            contract: pool_contract,
            account: upgrade_governor,
            governance_admin: pool_contract_admin,
        );

        let final_index = system.staking.get_global_index();

        // Upgrade.
        let eic_data = EICData {
            eic_hash: declare_pool_eic_contract(),
            eic_init_data: [MAINNET_POOL_CLASS_HASH_V0().into()].span(),
        };
        let implementation_data = ImplementationData {
            impl_hash: declare_pool_contract(), eic_data: Option::Some(eic_data), final: false,
        };
        upgrade_implementation(
            contract_address: pool_contract, :implementation_data, :upgrade_governor,
        );
        // Test.
        let map_selector = selector!("prev_class_hash");
        let storage_address = snforge_std::map_entry_address(
            :map_selector, keys: [PREV_CONTRACT_VERSION].span(),
        );
        let prev_class_hash = *snforge_std::load(
            target: pool_contract, :storage_address, size: Store::<ClassHash>::size().into(),
        )
            .at(0);
        assert!(prev_class_hash.try_into().unwrap() == MAINNET_POOL_CLASS_HASH_V0());

        let mut span_final_staker_index = snforge_std::load(
            target: pool_contract,
            storage_address: selector!("final_staker_index"),
            size: Store::<Option<Index>>::size().into(),
        )
            .span();
        let final_staker_index: Option<Index> = deserialize_option(ref span_final_staker_index);
        assert!(final_staker_index == Option::Some(final_index));
        // TODO: Test rewards_info.
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Delegator full intent
/// Upgrade
/// Delegator full switch
#[derive(Drop, Copy)]
pub(crate) struct DelegatorSwitchAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegated_amount: Option<Amount>,
}
pub(crate) impl DelegatorSwitchAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorSwitchAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: DelegatorSwitchAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: DelegatorSwitchAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: DelegatorSwitchAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);
        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
        self.delegated_amount = Option::Some(delegated_amount);
    }

    fn test(
        self: DelegatorSwitchAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let delegator = self.delegator.unwrap();
        let pool = self.pool_address.unwrap();
        let delegated_amount = self.delegated_amount.unwrap();

        let commission = 200;
        let second_staker = system.new_staker(amount: delegated_amount);
        system
            .stake(
                staker: second_staker, amount: delegated_amount, pool_enabled: true, :commission,
            );
        let second_pool = system.staking.get_pool(staker: second_staker);
        system
            .switch_delegation_pool(
                :delegator,
                from_pool: pool,
                to_staker: second_staker.staker.address,
                to_pool: second_pool,
                amount: delegated_amount,
            );

        // Although the delegator has switched their entire delegated amount to the second pool,
        // they remain a member of the original pool. Keeping the delegator in the pool ensures they
        // can still receive any additional rewards that they may get for the current epoch.
        let delegator_info_first_pool = system.pool_member_info_v1(:delegator, :pool);
        assert!(delegator_info_first_pool.amount.is_zero());

        let delegator_info_second_pool = system.pool_member_info_v1(:delegator, pool: second_pool);
        assert!(delegator_info_second_pool.amount == delegated_amount);
    }
}

/// Test staker_migration.
#[derive(Drop, Copy)]
pub(crate) struct StakerMigrationFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) staker_info: Option<StakerInfo>,
}
pub(crate) impl StakerMigrationFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerMigrationFlow, TTokenState> {
    fn get_pool_address(self: StakerMigrationFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: StakerMigrationFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: StakerMigrationFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: false, :commission);

        let staker_info = system.staker_info(:staker);

        self.staker = Option::Some(staker);
        self.staker_info = Option::Some(staker_info);

        system.advance_time(time: one_week);
        system.staking.update_global_index_if_needed();
    }

    fn test(
        self: StakerMigrationFlow, ref system: SystemState<TTokenState>, system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let staker_address = staker.staker.address;
        system.staker_migration(staker_address);
        let internal_staker_info = system.internal_staker_info(:staker);
        let global_index = system.staking.get_global_index();
        let mut expected_staker_info = staker_update_old_rewards(
            staker_info: self.staker_info.unwrap(), :global_index,
        )
            .to_v1();
        assert!(internal_staker_info == expected_staker_info.to_internal());
        // TODO: Test initialization of staker balance trace.
    }
}

// TODO: Test pool migration - including pool_unclaimed_rewards and staker_index, including errors
// from convert_internal_staker_info

/// Test claim_rewards with multiple delegators.
#[derive(Drop, Copy)]
pub(crate) struct ClaimRewardsMultipleDelegatorsFlow {}
pub(crate) impl ClaimRewardsMultipleDelegatorsFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<ClaimRewardsMultipleDelegatorsFlow, TTokenState> {
    fn get_pool_address(self: ClaimRewardsMultipleDelegatorsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: ClaimRewardsMultipleDelegatorsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: ClaimRewardsMultipleDelegatorsFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: ClaimRewardsMultipleDelegatorsFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount);
        let commission = 200;
        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);

        let delegated_amount = min_stake;
        let delegator_1 = system.new_delegator(amount: delegated_amount);
        let delegator_2 = system.new_delegator(amount: delegated_amount);
        let delegator_3 = system.new_delegator(amount: delegated_amount);

        system.delegate(delegator: delegator_1, :pool, amount: delegated_amount);
        system.delegate(delegator: delegator_2, :pool, amount: delegated_amount / 2);
        system.delegate(delegator: delegator_3, :pool, amount: delegated_amount / 4);

        let pool_balance = delegated_amount + delegated_amount / 2 + delegated_amount / 4;

        system.advance_epoch_and_attest(:staker);

        // Compute pool rewards.
        let pool_rewards = calculate_pool_rewards(
            staker_address: staker.staker.address,
            staking_contract: system.staking.address,
            minting_curve_contract: system.minting_curve.address,
        );

        system.advance_epoch();

        // Compute expected rewards for each pool member.
        let expected_rewards_1 = calculate_pool_member_rewards(
            :pool_rewards, pool_member_balance: delegated_amount, :pool_balance,
        );
        let expected_rewards_2 = calculate_pool_member_rewards(
            :pool_rewards, pool_member_balance: delegated_amount / 2, :pool_balance,
        );
        let expected_rewards_3 = calculate_pool_member_rewards(
            :pool_rewards, pool_member_balance: delegated_amount / 4, :pool_balance,
        );

        // Claim rewards, and validate the results.
        let calculates_rewards_1 = system
            .pool_member_info_v1(delegator: delegator_1, :pool)
            .unclaimed_rewards;
        let calculates_rewards_2 = system
            .pool_member_info_v1(delegator: delegator_2, :pool)
            .unclaimed_rewards;
        let calculates_rewards_3 = system
            .pool_member_info_v1(delegator: delegator_3, :pool)
            .unclaimed_rewards;

        let actual_reward_1 = system.delegator_claim_rewards(delegator: delegator_1, :pool);
        let actual_reward_2 = system.delegator_claim_rewards(delegator: delegator_2, :pool);
        let actual_reward_3 = system.delegator_claim_rewards(delegator: delegator_3, :pool);

        assert!(system.staker_info_v1(:staker).get_pool_info().amount == pool_balance);

        assert!(calculates_rewards_1 == expected_rewards_1);
        assert!(calculates_rewards_2 == expected_rewards_2);
        assert!(calculates_rewards_3 == expected_rewards_3);

        assert!(actual_reward_1 == expected_rewards_1);
        assert!(actual_reward_2 == expected_rewards_2);
        assert!(actual_reward_3 == expected_rewards_3);

        assert!(
            system
                .token
                .balance_of(account: delegator_1.reward.address) == expected_rewards_1
                .into(),
        );
        assert!(
            system
                .token
                .balance_of(account: delegator_2.reward.address) == expected_rewards_2
                .into(),
        );
        assert!(
            system
                .token
                .balance_of(account: delegator_3.reward.address) == expected_rewards_3
                .into(),
        );
    }
}

/// Test Pool claim_rewards few times.
/// Flow:
/// Staker stake with pool
/// attest
/// Delegator delegate
/// attest
/// attest
/// Delegator claim_rewards
/// attest
/// attest
/// Delegator claim_rewards - Cover claim after claim
/// Delegator pool_member_info - Cover calculate after claim no rewards
/// Delegator claim_rewards - Cover claim after claim no rewards
/// Exit intent staker and delegator
/// Exit action staker and delegator
/// Delegator claim_rewards - Cover claim after exit action
#[derive(Drop, Copy)]
pub(crate) struct PoolClaimAfterClaimFlow {}
pub(crate) impl PoolClaimAfterClaimFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolClaimAfterClaimFlow, TTokenState> {
    fn get_pool_address(self: PoolClaimAfterClaimFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: PoolClaimAfterClaimFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolClaimAfterClaimFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: PoolClaimAfterClaimFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount);
        let commission = 200;
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        system.advance_epoch_and_attest(:staker);
        system.advance_epoch_and_attest(:staker);

        let first_claim = system.delegator_claim_rewards(:delegator, :pool);

        system.advance_epoch_and_attest(:staker);
        system.advance_epoch_and_attest(:staker);

        let second_claim = system.delegator_claim_rewards(:delegator, :pool);
        assert!(second_claim == 2 * first_claim);

        let pool_member_info = system
            .pool_member_info_v1(:delegator, :pool); // Calculate after claim.
        assert!(pool_member_info.unclaimed_rewards == 0);

        let rewards_before = system.token.balance_of(account: delegator.reward.address);
        assert!(rewards_before == second_claim + first_claim);
        let claimed_rewards = system
            .delegator_claim_rewards(:delegator, :pool); // Claim after claim.
        assert!(claimed_rewards == 0);
        assert!(rewards_before == system.token.balance_of(account: delegator.reward.address));

        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);
        system.staker_exit_intent(:staker);

        system.advance_exit_wait_window();

        system.delegator_exit_action(:delegator, :pool);
        system.staker_exit_action(:staker);

        system.delegator_claim_rewards(:delegator, :pool);

        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: delegator.delegator.address) == delegated_amount);
        assert!(system.token.balance_of(account: pool) == 0);
        assert!(system.token.balance_of(account: delegator.reward.address).is_non_zero());
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: delegator.reward.address),
        );
    }
}

/// Test pool member change balance calculate rewards flow.
/// Flow:
/// Staker stake with pool
/// advance epoch and attest
/// Delegator1 delegate
/// advance epoch and attest
/// Delegator2 delegate
/// advance epoch and attest
/// Delegator1 increase delegate - Cover already got rewards for current epoch
/// advance epoch
/// Delegator1 increase delegate - Cover still didnt get rewards for current epoch
/// attest
/// advance epoch
/// Delegator1 increase delegate - Cover no rewards at all for current epoch
/// advance epoch
/// advance epoch and attest
/// Delegator1 exit intent full amount - Cover balance change to zero
/// advance epoch and attest
/// Delegator1 exit intent partial amount - Cover balance change to non-zero
/// advance epoch and attest
/// advance epoch and attest
/// Delegator1 exit action
/// Delegator1 increase delegate - Cover more than one reward between balance changes
/// advance epoch and attest
/// advance epoch
/// Delegator1 pool_member_info (calculate_rewards)
/// Delegator2 pool_member_info (calculate_rewards)
/// Delegator1 claim_rewards
/// Delegator2 claim_rewards
#[derive(Drop, Copy)]
pub(crate) struct ChangeBalanceClaimRewardsFlow {}
pub(crate) impl ChangeBalanceClaimRewardsFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<ChangeBalanceClaimRewardsFlow, TTokenState> {
    fn get_pool_address(self: ChangeBalanceClaimRewardsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: ChangeBalanceClaimRewardsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: ChangeBalanceClaimRewardsFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: ChangeBalanceClaimRewardsFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount);
        let staker_address = staker.staker.address;
        let commission = 200;
        let staking_contract = system.staking.address;
        let minting_curve_contract = system.minting_curve.address;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);
        system.advance_epoch_and_attest(:staker);

        let mut delegator_1_rewards: Amount = 0;
        let mut delegator_2_rewards: Amount = 0;
        let mut pool_balance: Amount = 0;
        let mut sigma: Amount = 0;

        let delegator_1 = system.new_delegator(amount: stake_amount);
        let mut delegated_amount_1 = stake_amount / 4;
        system.delegate(delegator: delegator_1, :pool, amount: delegated_amount_1);

        system.advance_epoch_and_attest(:staker);
        // Delelgator 1 is the only delegator in the pool.
        pool_balance += delegated_amount_1;
        delegator_1_rewards +=
            calculate_pool_rewards(:staker_address, :staking_contract, :minting_curve_contract);

        let delegated_amount_2 = delegated_amount_1;
        let delegator_2 = system.new_delegator(amount: delegated_amount_2);
        system.delegate(delegator: delegator_2, :pool, amount: delegated_amount_2);

        system.advance_epoch_and_attest(:staker);
        pool_balance += delegated_amount_2;
        let pool_rewards = calculate_pool_rewards(
            :staker_address, :staking_contract, :minting_curve_contract,
        );
        delegator_1_rewards +=
            calculate_pool_member_rewards(
                :pool_rewards, pool_member_balance: delegated_amount_1, :pool_balance,
            );
        sigma += compute_rewards_per_strk(staking_rewards: pool_rewards, total_stake: pool_balance);

        system.increase_delegate(delegator: delegator_1, :pool, amount: stake_amount / 4);

        system.advance_epoch();

        delegated_amount_1 += stake_amount / 4;
        pool_balance += stake_amount / 4;
        system.advance_block_into_attestation_window(:staker);

        system.increase_delegate(delegator: delegator_1, :pool, amount: stake_amount / 4);

        system.attest(:staker);
        let pool_rewards = calculate_pool_rewards_with_pool_balance(
            :staker_address,
            :staking_contract,
            :minting_curve_contract,
            :pool_balance,
            staker_balance: stake_amount,
        );
        delegator_1_rewards +=
            calculate_pool_member_rewards(
                :pool_rewards, pool_member_balance: delegated_amount_1, :pool_balance,
            );
        sigma += compute_rewards_per_strk(staking_rewards: pool_rewards, total_stake: pool_balance);

        system.advance_epoch();
        delegated_amount_1 += stake_amount / 4;
        pool_balance += stake_amount / 4;

        system.increase_delegate(delegator: delegator_1, :pool, amount: stake_amount / 4);

        system.advance_epoch();
        delegated_amount_1 += stake_amount / 4;
        pool_balance += stake_amount / 4;

        system.advance_epoch_and_attest(:staker);
        let pool_rewards = calculate_pool_rewards(
            :staker_address, :staking_contract, :minting_curve_contract,
        );
        delegator_1_rewards +=
            calculate_pool_member_rewards(
                :pool_rewards, pool_member_balance: delegated_amount_1, :pool_balance,
            );
        sigma += compute_rewards_per_strk(staking_rewards: pool_rewards, total_stake: pool_balance);

        system
            .delegator_exit_intent(
                delegator: delegator_1, :pool, amount: stake_amount,
            ); // Full exit intent.

        system.advance_epoch_and_attest(:staker);
        delegated_amount_1 = 0;
        pool_balance -= stake_amount;

        let pool_rewards = calculate_pool_rewards(
            :staker_address, :staking_contract, :minting_curve_contract,
        );
        sigma += compute_rewards_per_strk(staking_rewards: pool_rewards, total_stake: pool_balance);

        system
            .delegator_exit_intent(
                delegator: delegator_1, :pool, amount: stake_amount / 4,
            ); // Partial exit intent.

        // More than one reward between balance changes.
        system.advance_epoch_and_attest(:staker);
        delegated_amount_1 += 3 * stake_amount / 4;
        pool_balance += 3 * stake_amount / 4;

        let pool_rewards = calculate_pool_rewards(
            :staker_address, :staking_contract, :minting_curve_contract,
        );
        let from_sigma = sigma;
        sigma += compute_rewards_per_strk(staking_rewards: pool_rewards, total_stake: pool_balance);

        system.advance_epoch_and_attest(:staker);
        sigma += compute_rewards_per_strk(staking_rewards: pool_rewards, total_stake: pool_balance);
        delegator_1_rewards +=
            compute_rewards_rounded_down(amount: delegated_amount_1, interest: sigma - from_sigma);

        system.advance_exit_wait_window();
        system.delegator_exit_action(delegator: delegator_1, :pool);
        system.increase_delegate(delegator: delegator_1, :pool, amount: stake_amount / 4);

        system.advance_epoch_and_attest(:staker);
        delegated_amount_1 += stake_amount / 4;
        pool_balance += stake_amount / 4;

        let pool_rewards = calculate_pool_rewards(
            :staker_address, :staking_contract, :minting_curve_contract,
        );
        delegator_1_rewards +=
            calculate_pool_member_rewards(
                :pool_rewards, pool_member_balance: delegated_amount_1, :pool_balance,
            );
        sigma += compute_rewards_per_strk(staking_rewards: pool_rewards, total_stake: pool_balance);

        system.advance_epoch();

        delegator_2_rewards =
            compute_rewards_rounded_down(amount: delegated_amount_2, interest: sigma);

        let calculated_rewards_1 = system
            .pool_member_info_v1(delegator: delegator_1, :pool)
            .unclaimed_rewards;
        let calculated_rewards_2 = system
            .pool_member_info_v1(delegator: delegator_2, :pool)
            .unclaimed_rewards;

        let actual_rewards_1 = system.delegator_claim_rewards(delegator: delegator_1, :pool);
        let actual_rewards_2 = system.delegator_claim_rewards(delegator: delegator_2, :pool);

        assert!(system.token.balance_of(account: pool) < 100);
        assert!(calculated_rewards_1 == delegator_1_rewards);
        assert!(calculated_rewards_2 == delegator_2_rewards);
        assert!(actual_rewards_1 == delegator_1_rewards);
        assert!(actual_rewards_2 == delegator_2_rewards);
        assert!(
            system.token.balance_of(account: delegator_1.reward.address) == delegator_1_rewards,
        );
        assert!(
            system.token.balance_of(account: delegator_2.reward.address) == delegator_2_rewards,
        );
    }
}

/// Test Claim Rewards After Upgrade.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// advance_time
/// Upgrade
/// attest
/// attest
/// attest
/// pool_member_info (calculate_rewards)
/// claim_rewards
#[derive(Drop, Copy)]
pub(crate) struct PoolClaimRewardsAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) staker: Option<Staker>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegator_info: Option<PoolMemberInfo>,
}
pub(crate) impl PoolClaimRewardsAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolClaimRewardsAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: PoolClaimRewardsAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: PoolClaimRewardsAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolClaimRewardsAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        system.advance_time(time: one_week);

        let delegator_info = system.pool_member_info(:delegator, :pool);

        self.pool_address = Option::Some(pool);
        self.staker = Option::Some(staker);
        self.delegator = Option::Some(delegator);
        self.delegator_info = Option::Some(delegator_info);
    }

    fn test(
        self: PoolClaimRewardsAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let delegator = self.delegator.unwrap();
        let delegator_info = self.delegator_info.unwrap();
        let pool = self.pool_address.unwrap();

        system.advance_epoch_and_attest(:staker);
        system.advance_epoch_and_attest(:staker);
        system.advance_epoch_and_attest(:staker);
        system.advance_epoch_and_attest(:staker);

        let staking_contract = system.staking.address;
        let minting_curve_contract = system.minting_curve.address;

        // Calculate pool rewards
        let pool_rewards_one_epoch = calculate_pool_rewards(
            staker_address: staker.staker.address, :staking_contract, :minting_curve_contract,
        );
        let pool_total_rewards = pool_rewards_one_epoch * 3;

        let expected_pool_rewards = pool_total_rewards + delegator_info.unclaimed_rewards;

        let pool_member_info = system.pool_member_info_v1(:delegator, :pool);

        let actual_pool_rewards = system.delegator_claim_rewards(delegator: delegator, :pool);

        assert!(pool_member_info.unclaimed_rewards == expected_pool_rewards);
        assert!(expected_pool_rewards == actual_pool_rewards);
        assert!(
            expected_pool_rewards == system.token.balance_of(account: delegator.reward.address),
        );
    }
}

/// Test change balance after upgrade.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// advance_time
/// Upgrade
/// attest
/// add_to_delegation_pool
/// attest
/// attest
/// claim_rewards
#[derive(Drop, Copy)]
pub(crate) struct PoolChangeBalanceAfterUpgradeFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) staker: Option<Staker>,
    pub(crate) delegator: Option<Delegator>,
    pub(crate) delegator_info: Option<PoolMemberInfo>,
    pub(crate) delegated_amount: Amount,
}
pub(crate) impl PoolChangeBalanceAfterUpgradeFlowmpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolChangeBalanceAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: PoolChangeBalanceAfterUpgradeFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: PoolChangeBalanceAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolChangeBalanceAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        let delegated_amount = stake_amount / 2;
        let delegator = system.new_delegator(amount: 2 * delegated_amount);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);

        system.advance_time(time: one_week);

        let delegator_info = system.pool_member_info(:delegator, :pool);

        self.pool_address = Option::Some(pool);
        self.staker = Option::Some(staker);
        self.delegator = Option::Some(delegator);
        self.delegator_info = Option::Some(delegator_info);
        self.delegated_amount = delegated_amount;
    }

    fn test(
        self: PoolChangeBalanceAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let delegator = self.delegator.unwrap();
        let delegator_info = self.delegator_info.unwrap();
        let pool = self.pool_address.unwrap();
        let staking_contract = system.staking.address;
        let minting_curve_contract = system.minting_curve.address;

        system.advance_epoch_and_attest(:staker);

        // Calculate pool rewards
        let pool_rewards_first_epoch = calculate_pool_rewards(
            staker_address: staker.staker.address, :staking_contract, :minting_curve_contract,
        );
        assert!(pool_rewards_first_epoch.is_non_zero());

        system.add_to_delegation_pool(:delegator, :pool, amount: self.delegated_amount);

        system.advance_epoch_and_attest(:staker);
        system.advance_epoch_and_attest(:staker);

        // Calculate pool rewards
        let pool_rewards_second_epoch = calculate_pool_rewards(
            staker_address: staker.staker.address, :staking_contract, :minting_curve_contract,
        );
        assert!(pool_rewards_second_epoch > pool_rewards_first_epoch);

        let expected_pool_rewards = pool_rewards_first_epoch
            + pool_rewards_second_epoch
            + delegator_info.unclaimed_rewards;

        let actual_pool_rewards = system.delegator_claim_rewards(:delegator, :pool);

        assert!(expected_pool_rewards == actual_pool_rewards);
        assert!(
            expected_pool_rewards == system.token.balance_of(account: delegator.reward.address),
        );
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Delegator full exit intent
/// Upgrade
/// Staker attest
/// Delegator claim rewards
#[derive(Drop, Copy)]
pub(crate) struct DelegatorIntentBeforeClaimRewardsAfterFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
}
pub(crate) impl DelegatorIntentBeforeClaimRewardsAfterFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorIntentBeforeClaimRewardsAfterFlow, TTokenState> {
    fn get_pool_address(
        self: DelegatorIntentBeforeClaimRewardsAfterFlow,
    ) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(
        self: DelegatorIntentBeforeClaimRewardsAfterFlow,
    ) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorIntentBeforeClaimRewardsAfterFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let delegator = system.new_delegator(amount: stake_amount);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: stake_amount);
        system.delegator_exit_intent(delegator: delegator, :pool, amount: stake_amount);

        self.staker = Option::Some(staker);
        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
    }

    fn test(
        self: DelegatorIntentBeforeClaimRewardsAfterFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let pool = self.pool_address.unwrap();
        let delegator = self.delegator.unwrap();

        system.advance_epoch_and_attest(:staker);
        system.advance_epoch();

        assert!(system.delegator_claim_rewards(:delegator, :pool).is_zero());
    }
}

/// Flow:
/// Staker stake without pool
/// Upgrade
/// Set open for delegation
/// Delegator delegate
#[derive(Drop, Copy)]
pub(crate) struct SetOpenForDelegationAfterUpgradeFlow {
    pub(crate) staker: Option<Staker>,
}
pub(crate) impl SetOpenForDelegationAfterUpgradeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<SetOpenForDelegationAfterUpgradeFlow, TTokenState> {
    fn get_pool_address(self: SetOpenForDelegationAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: SetOpenForDelegationAfterUpgradeFlow) -> Option<ContractAddress> {
        Option::Some(self.staker.unwrap().staker.address)
    }

    fn setup(ref self: SetOpenForDelegationAfterUpgradeFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let commission = 200;

        let staker = system.new_staker(amount: stake_amount);
        system.stake(:staker, amount: stake_amount, pool_enabled: false, :commission);
        self.staker = Option::Some(staker);
    }

    fn test(
        self: SetOpenForDelegationAfterUpgradeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let commission = 200;
        let amount = 1000;
        let staker = self.staker.unwrap();

        let pool = system.set_open_for_delegation(:staker, :commission);

        let delegator = system.new_delegator(amount: amount * 2);
        let total_stake_before = system.staking.get_total_stake();
        system.delegate(:delegator, :pool, :amount);

        let delegator_info = system.pool_member_info_v1(:delegator, :pool);
        assert!(delegator_info.amount == amount);
        assert!(system.staking.get_total_stake() == total_stake_before + amount);
    }
}

/// Flow:
/// Staker stake
/// Staker attest
/// Advance epoch
/// Staker increase stake
/// Staker exit intent (same epoch)
/// Staker exit action
#[derive(Drop, Copy)]
pub(crate) struct IncreaseStakeIntentSameEpochFlow {}
pub(crate) impl IncreaseStakeIntentSameEpochFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<IncreaseStakeIntentSameEpochFlow, TTokenState> {
    fn get_pool_address(self: IncreaseStakeIntentSameEpochFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: IncreaseStakeIntentSameEpochFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: IncreaseStakeIntentSameEpochFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: IncreaseStakeIntentSameEpochFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        system.stake(:staker, amount: stake_amount, pool_enabled: false, commission: 200);
        system.advance_epoch_and_attest(:staker);

        system.increase_stake(:staker, amount: stake_amount);
        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());

        assert!(system.token.balance_of(account: staker.staker.address).is_zero());
        system.staker_exit_action(:staker);
        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount * 2);
    }
}

/// Flow:
/// First staker stake with pool
/// First delegator delegate
/// Second staker stake with pool
/// Second delegator delegate
/// Assert total stake
#[derive(Drop, Copy)]
pub(crate) struct AssertTotalStakeAfterMultiStakeFlow {}
pub(crate) impl AssertTotalStakeAfterMultiStakeFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<AssertTotalStakeAfterMultiStakeFlow, TTokenState> {
    fn get_pool_address(self: AssertTotalStakeAfterMultiStakeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: AssertTotalStakeAfterMultiStakeFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: AssertTotalStakeAfterMultiStakeFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: AssertTotalStakeAfterMultiStakeFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let stake_amount = system.staking.get_min_stake() * 2;
        let commission = 200;

        let first_staker = system.new_staker(amount: stake_amount);
        system.stake(staker: first_staker, amount: stake_amount, pool_enabled: true, :commission);

        let first_delegator = system.new_delegator(amount: stake_amount);
        let first_pool = system.staking.get_pool(staker: first_staker);
        system.delegate(delegator: first_delegator, pool: first_pool, amount: stake_amount);

        let second_staker = system.new_staker(amount: stake_amount);
        system.stake(staker: second_staker, amount: stake_amount, pool_enabled: true, :commission);

        let second_delegator = system.new_delegator(amount: stake_amount);
        let second_pool = system.staking.get_pool(staker: second_staker);
        system.delegate(delegator: second_delegator, pool: second_pool, amount: stake_amount);

        assert!(system.staking.get_total_stake() == stake_amount * 4);
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Staker attest
/// Delegator full exit intent
/// Delegator exit action
#[derive(Drop, Copy)]
pub(crate) struct DelegateIntentSameEpochFlow {}
pub(crate) impl DelegateIntentSameEpochFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegateIntentSameEpochFlow, TTokenState> {
    fn get_pool_address(self: DelegateIntentSameEpochFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: DelegateIntentSameEpochFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: DelegateIntentSameEpochFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: DelegateIntentSameEpochFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount);
        let delegated_amount = stake_amount;
        let delegator = system.new_delegator(amount: delegated_amount);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch();
        system.advance_block_into_attestation_window(:staker);

        let pool = system.staking.get_pool(:staker);
        system.delegate(:delegator, :pool, amount: delegated_amount);
        system.attest(:staker);
        system.delegator_exit_intent(:delegator, :pool, amount: delegated_amount);
        system.advance_time(time: system.staking.get_exit_wait_window());

        assert!(system.token.balance_of(account: delegator.delegator.address).is_zero());
        system.delegator_exit_action(:delegator, :pool);
        assert!(system.token.balance_of(account: delegator.delegator.address) == delegated_amount);

        let delegator_info = system.pool_member_info_v1(:delegator, :pool);
        assert!(delegator_info.amount.is_zero());
        assert!(delegator_info.unclaimed_rewards.is_zero());
    }
}

/// Test Pool claim_rewards flow.
/// Flow:
/// Staker stake with pool
/// attest
/// Delegator1 delegate
/// Delegator2 delegate
/// Delegator3 delegate
/// Delegator1 claim_rewards
/// attest
/// Delegator1 claim_rewards - Cover zero epochs
/// attest
/// Delegator2 claim_rewards - Cover one epoch
/// attest
/// Delegator3 claim_rewards - Cover two epochs
/// attest
/// Delegator2 claim_rewards
/// Exit intent staker and all delegators
/// Exit action staker and all delegators
#[derive(Drop, Copy)]
pub(crate) struct PoolClaimRewardsFlow {}
pub(crate) impl PoolClaimRewardsFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<PoolClaimRewardsFlow, TTokenState> {
    fn get_pool_address(self: PoolClaimRewardsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: PoolClaimRewardsFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: PoolClaimRewardsFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: PoolClaimRewardsFlow, ref system: SystemState<TTokenState>, system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount);
        let commission = 200;
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch_and_attest(:staker);

        let delegated_amount_1 = stake_amount / 2;
        let delegator_1 = system.new_delegator(amount: delegated_amount_1);
        let delegated_amount_2 = stake_amount / 4;
        let delegator_2 = system.new_delegator(amount: delegated_amount_2);
        let delegated_amount_3 = stake_amount / 8;
        let delegator_3 = system.new_delegator(amount: delegated_amount_3);
        let pool = system.staking.get_pool(:staker);
        system.delegate(delegator: delegator_1, :pool, amount: delegated_amount_1);
        system.delegate(delegator: delegator_2, :pool, amount: delegated_amount_2);
        system.delegate(delegator: delegator_3, :pool, amount: delegated_amount_3);

        let rewards_1 = system.delegator_claim_rewards(delegator: delegator_1, :pool);
        assert!(rewards_1 == Zero::zero());
        assert!(system.token.balance_of(account: delegator_1.reward.address) == Zero::zero());

        system.advance_epoch_and_attest(:staker);

        let rewards_1 = system
            .delegator_claim_rewards(delegator: delegator_1, :pool); // Cover zero epochs
        assert!(rewards_1 == Zero::zero());
        assert!(system.token.balance_of(account: delegator_1.reward.address) == Zero::zero());

        system.advance_epoch_and_attest(:staker);

        system.delegator_claim_rewards(delegator: delegator_2, :pool); // Cover one epoch

        system.advance_epoch_and_attest(:staker);

        system.delegator_claim_rewards(delegator: delegator_3, :pool); // Cover two epochs

        system.advance_epoch_and_attest(:staker);

        system.delegator_claim_rewards(delegator: delegator_2, :pool);

        system.delegator_exit_intent(delegator: delegator_1, :pool, amount: delegated_amount_1);
        system.delegator_exit_intent(delegator: delegator_2, :pool, amount: delegated_amount_2);
        system.delegator_exit_intent(delegator: delegator_3, :pool, amount: delegated_amount_3);
        system.staker_exit_intent(:staker);

        system.advance_time(time: system.staking.get_exit_wait_window());
        system.advance_epoch();

        system.delegator_exit_action(delegator: delegator_1, :pool);
        system.delegator_exit_action(delegator: delegator_2, :pool);
        system.delegator_exit_action(delegator: delegator_3, :pool);
        system.staker_exit_action(:staker);

        system.delegator_claim_rewards(delegator: delegator_1, :pool);
        system.delegator_claim_rewards(delegator: delegator_2, :pool);
        system.delegator_claim_rewards(delegator: delegator_3, :pool);

        let rewards_1 = system.token.balance_of(account: delegator_1.reward.address);
        let rewards_2 = system.token.balance_of(account: delegator_2.reward.address);
        let rewards_3 = system.token.balance_of(account: delegator_3.reward.address);

        assert!(system.token.balance_of(account: staker.staker.address) == stake_amount);
        assert!(
            system.token.balance_of(account: delegator_1.delegator.address) == delegated_amount_1,
        );
        assert!(
            system.token.balance_of(account: delegator_2.delegator.address) == delegated_amount_2,
        );
        assert!(
            system.token.balance_of(account: delegator_3.delegator.address) == delegated_amount_3,
        );
        assert!(system.token.balance_of(account: pool) == 0);
        assert!(rewards_1 > rewards_2);
        assert!(rewards_2 > rewards_3);
        assert!(rewards_3.is_non_zero());
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + rewards_1
                + rewards_2
                + rewards_3,
        );
    }
}

/// Flow:
/// Staker stake with pool
/// Upgrade
/// Staker migration - should fail
#[derive(Drop, Copy)]
pub(crate) struct StakerMigrationHasPoolFlow {
    pub(crate) staker_address: Option<ContractAddress>,
}
pub(crate) impl StakerMigrationHasPoolFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<StakerMigrationHasPoolFlow, TTokenState> {
    fn get_pool_address(self: StakerMigrationHasPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: StakerMigrationHasPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: StakerMigrationHasPoolFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let staker = system.new_staker(amount: stake_amount * 2);
        let commission = 200;

        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);

        self.staker_address = Option::Some(staker.staker.address);
    }

    fn test(
        self: StakerMigrationHasPoolFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker_address.unwrap();
        system.staker_migration(staker_address: staker);
    }
}

/// Flow:
/// Staker stake
/// Staker Attest
/// Staker exit intent
/// Staker exit action
/// Second staker stake with same operational address
/// Second staker Attest
/// Second staker exit intent
/// Second staker exit action
#[derive(Drop, Copy)]
pub(crate) struct TwoStakersSameOperationalAddressFlow {}
pub(crate) impl TwoStakersSameOperationalAddressFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<TwoStakersSameOperationalAddressFlow, TTokenState> {
    fn get_pool_address(self: TwoStakersSameOperationalAddressFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: TwoStakersSameOperationalAddressFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: TwoStakersSameOperationalAddressFlow, ref system: SystemState<TTokenState>,
    ) {}

    fn test(
        self: TwoStakersSameOperationalAddressFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;

        let first_staker = system.new_staker(amount: stake_amount);
        system.stake(staker: first_staker, amount: stake_amount, pool_enabled: false, :commission);
        system.advance_epoch_and_attest(staker: first_staker);

        system.staker_exit_intent(staker: first_staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(staker: first_staker);

        let mut second_staker = system.new_staker(amount: stake_amount);
        second_staker.operational.address = first_staker.operational.address;
        system.stake(staker: second_staker, amount: stake_amount, pool_enabled: false, :commission);
        system.advance_epoch_and_attest(staker: second_staker);

        system.staker_exit_intent(staker: second_staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(staker: second_staker);

        assert!(system.token.balance_of(account: system.staking.address).is_zero());
        assert!(system.token.balance_of(account: first_staker.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: second_staker.staker.address) == stake_amount);
        assert!(system.token.balance_of(account: first_staker.reward.address).is_non_zero());
        assert!(system.token.balance_of(account: second_staker.reward.address).is_non_zero());
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: first_staker.reward.address)
                + system.token.balance_of(account: second_staker.reward.address),
        );
    }
}

/// Flow:
/// Staker stake with pool
/// First delegator delegate
/// Second delegator delegate
/// Third delegator delegate
/// First delegator full exit intent
/// Second delegator partial exit intent
/// Staker exit intent
/// Staker exit action
/// Upgrade (without upgrading the pool)
/// First delegator claim rewards
/// Second delegator claim rewards
/// Third delegator claim rewards
#[derive(Drop, Copy)]
pub(crate) struct ClaimRewardsWithNonUpgradedPoolFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) first_delegator: Option<Delegator>,
    pub(crate) first_delegator_info: Option<PoolMemberInfo>,
    pub(crate) second_delegator: Option<Delegator>,
    pub(crate) second_delegator_info: Option<PoolMemberInfo>,
    pub(crate) third_delegator: Option<Delegator>,
    pub(crate) third_delegator_info: Option<PoolMemberInfo>,
}
pub(crate) impl ClaimRewardsWithNonUpgradedPoolFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<ClaimRewardsWithNonUpgradedPoolFlow, TTokenState> {
    fn get_pool_address(self: ClaimRewardsWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: ClaimRewardsWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: ClaimRewardsWithNonUpgradedPoolFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        let staker = system.new_staker(amount: stake_amount);
        system.stake(staker: staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);

        let first_delegator = system.new_delegator(amount: stake_amount);
        let second_delegator = system.new_delegator(amount: stake_amount);
        let third_delegator = system.new_delegator(amount: stake_amount);

        system.delegate(delegator: first_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: second_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: third_delegator, :pool, amount: stake_amount);
        system.advance_time(time: one_week);

        system.delegator_exit_intent(delegator: first_delegator, :pool, amount: stake_amount);
        system.delegator_exit_intent(delegator: second_delegator, :pool, amount: stake_amount / 2);
        system.advance_time(time: one_week);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        self.pool_address = Option::Some(pool);
        self.first_delegator = Option::Some(first_delegator);
        self
            .first_delegator_info =
                Option::Some(system.pool_member_info(delegator: first_delegator, :pool));
        self.second_delegator = Option::Some(second_delegator);
        self
            .second_delegator_info =
                Option::Some(system.pool_member_info(delegator: second_delegator, :pool));
        self.third_delegator = Option::Some(third_delegator);
        self
            .third_delegator_info =
                Option::Some(system.pool_member_info(delegator: third_delegator, :pool));
    }

    fn test(
        self: ClaimRewardsWithNonUpgradedPoolFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let pool = self.pool_address.unwrap();
        let first_delegator = self.first_delegator.unwrap();
        let first_delegator_info = self.first_delegator_info.unwrap();
        let second_delegator = self.second_delegator.unwrap();
        let second_delegator_info = self.second_delegator_info.unwrap();
        let third_delegator = self.third_delegator.unwrap();
        let third_delegator_info = self.third_delegator_info.unwrap();

        assert!(
            first_delegator_info
                .unclaimed_rewards == system
                .delegator_claim_rewards(delegator: first_delegator, :pool),
        );
        assert!(
            second_delegator_info
                .unclaimed_rewards == system
                .delegator_claim_rewards(delegator: second_delegator, :pool),
        );
        assert!(
            third_delegator_info
                .unclaimed_rewards == system
                .delegator_claim_rewards(delegator: third_delegator, :pool),
        );
    }
}

#[derive(Drop, Copy)]
pub(crate) struct DelegatorActionWithNonUpgradedPoolFlow {
    pub(crate) staker: Option<Staker>,
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) first_delegator: Option<Delegator>,
    pub(crate) first_delegator_info: Option<PoolMemberInfo>,
    pub(crate) second_delegator: Option<Delegator>,
    pub(crate) second_delegator_info: Option<PoolMemberInfo>,
    pub(crate) third_delegator: Option<Delegator>,
    pub(crate) third_delegator_info: Option<PoolMemberInfo>,
    pub(crate) initial_reward_supplier_balance: Option<Amount>,
}
pub(crate) impl DelegatorActionWithNonUpgradedPoolFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorActionWithNonUpgradedPoolFlow, TTokenState> {
    fn get_pool_address(self: DelegatorActionWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: DelegatorActionWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorActionWithNonUpgradedPoolFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let initial_reward_supplier_balance = system
            .token
            .balance_of(account: system.reward_supplier.address);
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        let staker = system.new_staker(amount: stake_amount);
        system.stake(staker: staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);

        let first_delegator = system.new_delegator(amount: stake_amount);
        let second_delegator = system.new_delegator(amount: stake_amount);
        let third_delegator = system.new_delegator(amount: stake_amount);

        system.delegate(delegator: first_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: second_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: third_delegator, :pool, amount: stake_amount);
        system.advance_time(time: one_week);

        system.delegator_exit_intent(delegator: first_delegator, :pool, amount: stake_amount);
        system.delegator_exit_intent(delegator: second_delegator, :pool, amount: stake_amount / 2);
        system.advance_time(time: one_week);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        self.staker = Option::Some(staker);
        self.pool_address = Option::Some(pool);
        self.first_delegator = Option::Some(first_delegator);
        self
            .first_delegator_info =
                Option::Some(system.pool_member_info(delegator: first_delegator, :pool));
        self.second_delegator = Option::Some(second_delegator);
        self
            .second_delegator_info =
                Option::Some(system.pool_member_info(delegator: second_delegator, :pool));
        self.third_delegator = Option::Some(third_delegator);
        self
            .third_delegator_info =
                Option::Some(system.pool_member_info(delegator: third_delegator, :pool));
        self.initial_reward_supplier_balance = Option::Some(initial_reward_supplier_balance);
    }

    fn test(
        self: DelegatorActionWithNonUpgradedPoolFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let staker = self.staker.unwrap();
        let pool = self.pool_address.unwrap();
        let first_delegator = self.first_delegator.unwrap();
        let first_delegator_info = self.first_delegator_info.unwrap();
        let second_delegator = self.second_delegator.unwrap();
        let second_delegator_info = self.second_delegator_info.unwrap();
        let third_delegator = self.third_delegator.unwrap();
        let third_delegator_info = self.third_delegator_info.unwrap();
        let initial_reward_supplier_balance = self.initial_reward_supplier_balance.unwrap();
        let one_week = Time::weeks(count: 1);

        // First delegator full exit action.
        system.delegator_exit_action(delegator: first_delegator, :pool);
        assert!(
            system
                .token
                .balance_of(account: first_delegator.delegator.address) == first_delegator_info
                .unpool_amount,
        );
        assert!(
            system
                .token
                .balance_of(account: first_delegator.reward.address) == first_delegator_info
                .unclaimed_rewards,
        );

        // Advancing time in order to make sure that it doesn't add rewards.
        system.advance_time(time: one_week);

        // Second delegator partial exit action.
        system.delegator_exit_action(delegator: second_delegator, :pool);
        assert!(
            system
                .token
                .balance_of(account: second_delegator.delegator.address) == second_delegator_info
                .unpool_amount,
        );

        // Second delegator full exit intent and action.
        system
            .delegator_exit_intent(
                delegator: second_delegator, :pool, amount: second_delegator_info.amount,
            );
        system.delegator_exit_action(delegator: second_delegator, :pool);
        assert!(
            system
                .token
                .balance_of(account: second_delegator.delegator.address) == second_delegator_info
                .unpool_amount
                + second_delegator_info.amount,
        );
        assert!(
            system
                .token
                .balance_of(account: second_delegator.reward.address) == second_delegator_info
                .unclaimed_rewards,
        );

        // Third delegator full exit intent and action.
        system
            .delegator_exit_intent(
                delegator: third_delegator, :pool, amount: third_delegator_info.amount,
            );
        system.delegator_exit_action(delegator: third_delegator, :pool);
        assert!(
            system
                .token
                .balance_of(account: third_delegator.delegator.address) == third_delegator_info
                .amount,
        );
        assert!(
            system
                .token
                .balance_of(account: third_delegator.reward.address) == third_delegator_info
                .unclaimed_rewards,
        );

        // Assert pool balance is near-zero.
        assert!(system.token.balance_of(account: pool) < 100);

        // Assert all staked amounts were transferred back.
        assert!(system.token.balance_of(account: system.staking.address).is_zero());

        // Assert all funds that moved from rewards supplier, were moved to correct addresses.
        assert!(wide_abs_diff(system.reward_supplier.get_unclaimed_rewards(), STRK_IN_FRIS) < 100);
        assert!(
            initial_reward_supplier_balance == system
                .token
                .balance_of(account: system.reward_supplier.address)
                + system.token.balance_of(account: staker.reward.address)
                + system.token.balance_of(account: pool)
                + system.token.balance_of(account: first_delegator.reward.address)
                + system.token.balance_of(account: second_delegator.reward.address)
                + system.token.balance_of(account: third_delegator.reward.address),
        );
    }
}

/// Flow:
/// Staker stake with pool
/// First delegator delegate
/// Second delegator delegate
/// Third delegator delegate
/// First delegator full exit intent
/// Second delegator partial exit intent
/// Staker exit intent
/// Staker exit action
/// Upgrade (without upgrading the pool)
/// New staker stake with pool
/// First delegator switch
/// Second delegator switch
#[derive(Drop, Copy)]
pub(crate) struct SwitchWithNonUpgradedPoolFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) first_delegator: Option<Delegator>,
    pub(crate) second_delegator: Option<Delegator>,
    pub(crate) stake_amount: Option<Amount>,
}
pub(crate) impl SwitchWithNonUpgradedPoolFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<SwitchWithNonUpgradedPoolFlow, TTokenState> {
    fn get_pool_address(self: SwitchWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: SwitchWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: SwitchWithNonUpgradedPoolFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        let staker = system.new_staker(amount: stake_amount);
        system.stake(staker: staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);

        let first_delegator = system.new_delegator(amount: stake_amount);
        let second_delegator = system.new_delegator(amount: stake_amount);
        let third_delegator = system.new_delegator(amount: stake_amount);

        system.delegate(delegator: first_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: second_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: third_delegator, :pool, amount: stake_amount);
        system.advance_time(time: one_week);

        system.delegator_exit_intent(delegator: first_delegator, :pool, amount: stake_amount);
        system.delegator_exit_intent(delegator: second_delegator, :pool, amount: stake_amount / 2);
        system.advance_time(time: one_week);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        self.pool_address = Option::Some(pool);
        self.first_delegator = Option::Some(first_delegator);
        self.second_delegator = Option::Some(second_delegator);
        self.stake_amount = Option::Some(stake_amount);
    }

    fn test(
        self: SwitchWithNonUpgradedPoolFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let pool = self.pool_address.unwrap();
        let first_delegator = self.first_delegator.unwrap();
        let second_delegator = self.second_delegator.unwrap();
        let stake_amount = self.stake_amount.unwrap();
        let commission = 200;

        let to_staker = system.new_staker(amount: stake_amount);
        system.stake(staker: to_staker, amount: stake_amount, pool_enabled: true, :commission);
        let to_pool = system.staking.get_pool(staker: to_staker);

        system
            .switch_delegation_pool(
                delegator: first_delegator,
                from_pool: pool,
                to_staker: to_staker.staker.address,
                :to_pool,
                amount: stake_amount,
            );
        assert!(system.get_pool_member_info(delegator: first_delegator, :pool).is_none());
        assert!(
            system
                .pool_member_info_v1(delegator: first_delegator, pool: to_pool)
                .amount == stake_amount,
        );

        system
            .switch_delegation_pool(
                delegator: second_delegator,
                from_pool: pool,
                to_staker: to_staker.staker.address,
                :to_pool,
                amount: stake_amount / 2,
            );
        assert!(
            system.pool_member_info(delegator: second_delegator, :pool).amount == stake_amount / 2,
        );
        assert!(
            system
                .pool_member_info_v1(delegator: second_delegator, pool: to_pool)
                .amount == stake_amount
                / 2,
        );
        // TODO: Intent and switch with a third delegator and catch `MISSING_UNDELEGATE_INTENT`.
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Delegator exit intent
/// Delegator exit action
/// Upgrade
/// Delegator enter
#[derive(Drop, Copy)]
pub(crate) struct DelegatorExitBeforeEnterAfterFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) delegator: Option<Delegator>,
}
pub(crate) impl DelegatorExitBeforeEnterAfterFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorExitBeforeEnterAfterFlow, TTokenState> {
    fn get_pool_address(self: DelegatorExitBeforeEnterAfterFlow) -> Option<ContractAddress> {
        self.pool_address
    }

    fn get_staker_address(self: DelegatorExitBeforeEnterAfterFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: DelegatorExitBeforeEnterAfterFlow, ref system: SystemState<TTokenState>) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        let staker = system.new_staker(amount: stake_amount);
        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);

        let delegator = system.new_delegator(amount: stake_amount);
        system.delegate(:delegator, :pool, amount: stake_amount);
        system.advance_time(time: one_week);

        system.delegator_exit_intent(:delegator, :pool, amount: stake_amount);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.delegator_exit_action(:delegator, :pool);

        self.pool_address = Option::Some(pool);
        self.delegator = Option::Some(delegator);
    }

    fn test(
        self: DelegatorExitBeforeEnterAfterFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let pool = self.pool_address.unwrap();
        let delegator = self.delegator.unwrap();
        let delegate_amount = 100;

        system.delegate(:delegator, :pool, amount: delegate_amount);
        assert!(system.pool_member_info_v1(:delegator, :pool).amount == delegate_amount);
    }
}

/// Flow:
/// Staker stake with pool
/// delegator delegate
/// Staker exit intent
/// Staker exit action
/// Upgrade (without upgrading the pool)
/// delegator exit intent
/// delegator exit action
#[derive(Drop, Copy)]
pub(crate) struct DelegatorIntentWithNonUpgradedPoolFlow {
    pub(crate) pool_address: Option<ContractAddress>,
    pub(crate) first_delegator: Option<Delegator>,
    pub(crate) first_delegator_info: Option<PoolMemberInfo>,
    pub(crate) second_delegator: Option<Delegator>,
    pub(crate) second_delegator_info: Option<PoolMemberInfo>,
    pub(crate) third_delegator: Option<Delegator>,
    pub(crate) third_delegator_info: Option<PoolMemberInfo>,
}
pub(crate) impl DelegatorIntentWithNonUpgradedPoolFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<DelegatorIntentWithNonUpgradedPoolFlow, TTokenState> {
    fn get_pool_address(self: DelegatorIntentWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: DelegatorIntentWithNonUpgradedPoolFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(
        ref self: DelegatorIntentWithNonUpgradedPoolFlow, ref system: SystemState<TTokenState>,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let commission = 200;
        let one_week = Time::weeks(count: 1);

        let staker = system.new_staker(amount: stake_amount);
        system.stake(staker: staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);

        let first_delegator = system.new_delegator(amount: stake_amount);
        let second_delegator = system.new_delegator(amount: stake_amount);
        let third_delegator = system.new_delegator(amount: stake_amount);

        system.delegate(delegator: first_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: second_delegator, :pool, amount: stake_amount);
        system.delegate(delegator: third_delegator, :pool, amount: stake_amount);
        system.advance_time(time: one_week);

        system.delegator_exit_intent(delegator: third_delegator, :pool, amount: stake_amount);
        system.advance_time(time: one_week);

        system.staker_exit_intent(:staker);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.staker_exit_action(:staker);

        self.pool_address = Option::Some(pool);
        self.first_delegator = Option::Some(first_delegator);
        self
            .first_delegator_info =
                Option::Some(system.pool_member_info(delegator: first_delegator, :pool));
        self.second_delegator = Option::Some(second_delegator);
        self
            .second_delegator_info =
                Option::Some(system.pool_member_info(delegator: second_delegator, :pool));
        self.third_delegator = Option::Some(third_delegator);
        self
            .third_delegator_info =
                Option::Some(system.pool_member_info(delegator: third_delegator, :pool));
    }

    fn test(
        self: DelegatorIntentWithNonUpgradedPoolFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let pool = self.pool_address.unwrap();
        let first_delegator = self.first_delegator.unwrap();
        let first_delegator_info = self.first_delegator_info.unwrap();
        let second_delegator = self.second_delegator.unwrap();
        let second_delegator_info = self.second_delegator_info.unwrap();
        let third_delegator = self.third_delegator.unwrap();
        let third_delegator_info = self.third_delegator_info.unwrap();

        system
            .delegator_exit_intent(
                delegator: first_delegator, :pool, amount: first_delegator_info.amount,
            );
        assert!(system.pool_member_info(delegator: first_delegator, :pool).amount.is_zero());
        assert!(
            system
                .pool_member_info(delegator: first_delegator, :pool)
                .unpool_amount == first_delegator_info
                .amount,
        );

        system
            .delegator_exit_intent(
                delegator: second_delegator, :pool, amount: second_delegator_info.amount / 2,
            );
        assert!(
            system
                .pool_member_info(delegator: second_delegator, :pool)
                .amount == second_delegator_info
                .amount
                / 2,
        );
        assert!(
            system
                .pool_member_info(delegator: second_delegator, :pool)
                .unpool_amount == second_delegator_info
                .amount
                / 2,
        );

        cheat_caller_address_once(
            contract_address: pool, caller_address: third_delegator.delegator.address,
        );
        let result = system
            .safe_delegator_exit_intent(
                delegator: third_delegator, :pool, amount: third_delegator_info.amount,
            );
        assert_panic_with_error(result, PoolError::UNDELEGATE_IN_PROGRESS.describe());
    }
}

/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Delegator exit intent
/// Delegator exit action
/// Delegator add to delegation
#[derive(Drop, Copy)]
pub(crate) struct AddToDelegationAfterExitActionFlow {}
pub(crate) impl AddToDelegationAfterExitActionFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<AddToDelegationAfterExitActionFlow, TTokenState> {
    fn get_pool_address(self: AddToDelegationAfterExitActionFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: AddToDelegationAfterExitActionFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: AddToDelegationAfterExitActionFlow, ref system: SystemState<TTokenState>) {}

    fn test(
        self: AddToDelegationAfterExitActionFlow,
        ref system: SystemState<TTokenState>,
        system_type: SystemType,
    ) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let commission = 200;

        let staker = system.new_staker(amount: stake_amount);
        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        let pool = system.staking.get_pool(:staker);

        let delegator = system.new_delegator(amount: stake_amount);
        system.delegate(:delegator, :pool, amount: stake_amount);

        system.delegator_exit_intent(:delegator, :pool, amount: stake_amount);
        system.advance_time(time: system.staking.get_exit_wait_window());
        system.delegator_exit_action(:delegator, :pool);
        assert!(system.pool_member_info_v1(:delegator, :pool).amount.is_zero());

        system.increase_delegate(:delegator, :pool, amount: stake_amount);
        system.advance_epoch_and_attest(:staker);
        system.advance_epoch();

        assert!(system.pool_member_info_v1(:delegator, :pool).amount == stake_amount);
        assert!(system.pool_member_info_v1(:delegator, :pool).unclaimed_rewards.is_non_zero());
    }
}

/// Flow:
/// Staker stake
/// Set epoch info
/// Staker attest
/// Advance epoch
/// Assert epoch rewards are changed
#[derive(Drop, Copy)]
pub(crate) struct SetEpochInfoFlow {}
pub(crate) impl SetEpochInfoFlowImpl<
    TTokenState, +TokenTrait<TTokenState>, +Drop<TTokenState>, +Copy<TTokenState>,
> of FlowTrait<SetEpochInfoFlow, TTokenState> {
    fn get_pool_address(self: SetEpochInfoFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn get_staker_address(self: SetEpochInfoFlow) -> Option<ContractAddress> {
        Option::None
    }

    fn setup(ref self: SetEpochInfoFlow, ref system: SystemState<TTokenState>) {}

    fn test(self: SetEpochInfoFlow, ref system: SystemState<TTokenState>, system_type: SystemType) {
        let min_stake = system.staking.get_min_stake();
        let stake_amount = min_stake * 2;
        let commission = 200;

        let staker = system.new_staker(amount: stake_amount);
        system.stake(:staker, amount: stake_amount, pool_enabled: true, :commission);
        system.advance_epoch();

        let target_block_before_set = system
            .attestation
            .unwrap()
            .get_current_epoch_target_attestation_block(
                operational_address: staker.operational.address,
            );
        let epoch_rewards_before_set = system.reward_supplier.calculate_current_epoch_rewards();
        assert!(epoch_rewards_before_set.is_non_zero());

        // Set new epoch info.
        let new_epoch_duration = EPOCH_DURATION * 15;
        let new_epoch_length = system.staking.get_epoch_info().epoch_len_in_blocks() * 15;
        system
            .staking
            .set_epoch_info(epoch_duration: new_epoch_duration, epoch_length: new_epoch_length);

        let target_block_after_set = system
            .attestation
            .unwrap()
            .get_current_epoch_target_attestation_block(
                operational_address: staker.operational.address,
            );
        assert!(target_block_after_set == target_block_before_set);

        let epoch_rewards_after_set = system.reward_supplier.calculate_current_epoch_rewards();
        assert!(epoch_rewards_after_set == epoch_rewards_before_set);

        // Advance block into attestation window and attest.
        start_cheat_block_number_global(
            block_number: MIN_ATTESTATION_WINDOW.into() + target_block_after_set,
        );
        system.attest(:staker);
        assert!(epoch_rewards_after_set == system.staker_info_v1(:staker).unclaimed_rewards_own);

        system.advance_epoch();
        let epoch_rewards_after_advance_epoch = system
            .reward_supplier
            .calculate_current_epoch_rewards();
        assert!(epoch_rewards_after_advance_epoch > epoch_rewards_before_set);
    }
}
// TODO: Implement this flow test.
/// Test calling pool migration after upgrade.
/// Should do nothing because pool migration is called in the upgrade proccess.
/// Flow:
/// Staker stake with pool
/// Delegator delegate
/// Upgrade
/// Pool call pool_migration - final index and pool balance as before.

// TODO: Implement this flow test.
// Stake
// Upgrade
// Attest at STARTING_EPOCH (should fail)


