#[starknet::contract]
pub mod Staking {
    use RolesComponent::InternalTrait as RolesInternalTrait;
    use core::num::traits::zero::Zero;
    use core::option::OptionTrait;
    use core::panics::panic_with_byte_array;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use staking::constants::{
        DEFAULT_EXIT_WAIT_WINDOW, MAX_EXIT_WAIT_WINDOW, PREV_CONTRACT_VERSION, STARTING_EPOCH,
    };
    use staking::errors::GenericError;
    use staking::pool::errors::Error as PoolError;
    use staking::pool::interface::{IPoolDispatcher, IPoolDispatcherTrait};
    use staking::reward_supplier::interface::{
        IRewardSupplierDispatcher, IRewardSupplierDispatcherTrait,
    };
    use staking::staking::errors::Error;
    use staking::staking::interface::{
        CommissionCommitment, ConfigEvents, Events, IStaking, IStakingAttestation, IStakingConfig,
        IStakingMigration, IStakingPause, IStakingPool, PauseEvents, StakerInfoV1,
        StakingContractInfoV1,
    };
    use staking::staking::objects::{
        AttestationInfo, AttestationInfoTrait, EpochInfo, EpochInfoTrait,
        InternalStakerInfoConvertTrait, InternalStakerInfoLatestTrait, InternalStakerInfoTrait,
        UndelegateIntentKey, UndelegateIntentValue, UndelegateIntentValueTrait,
        UndelegateIntentValueZero, VersionedInternalStakerInfo, VersionedInternalStakerInfoTrait,
    };
    use staking::staking::staker_balance_trace::trace::{
        MutableStakerBalanceTraceTrait, StakerBalance, StakerBalanceTrace, StakerBalanceTraceTrait,
        StakerBalanceTrait,
    };
    use staking::types::{
        Amount, Commission, Epoch, Index, InternalStakerInfoLatest, InternalStakerPoolInfoLatest,
        Version,
    };
    use staking::utils::{
        CheckedIERC20DispatcherTrait, compute_commission_amount_rounded_down,
        compute_new_delegated_stake, deploy_delegation_pool_contract,
    };
    use starknet::class_hash::ClassHash;
    use starknet::storage::{Map, StoragePathEntry};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starkware_utils::components::replaceability::ReplaceabilityComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent::InternalReplaceabilityTrait;
    use starkware_utils::components::roles::RolesComponent;
    use starkware_utils::errors::{Describable, OptionAuxTrait};
    use starkware_utils::interfaces::identity::Identity;
    use starkware_utils::math::utils::mul_wide_and_div;
    use starkware_utils::trace::trace::{MutableTraceTrait, Trace, TraceTrait};
    use starkware_utils::types::time::time::{Time, TimeDelta, Timestamp};
    pub const CONTRACT_IDENTITY: felt252 = 'Staking Core Contract';
    pub const CONTRACT_VERSION: felt252 = '2.0.0';

    pub const COMMISSION_DENOMINATOR: Commission = 10000;

    component!(path: ReplaceabilityComponent, storage: replaceability, event: ReplaceabilityEvent);
    component!(path: RolesComponent, storage: roles, event: RolesEvent);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl ReplaceabilityImpl =
        ReplaceabilityComponent::ReplaceabilityImpl<ContractState>;

    #[abi(embed_v0)]
    impl RolesImpl = RolesComponent::RolesImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        replaceability: ReplaceabilityComponent::Storage,
        #[substorage(v0)]
        roles: RolesComponent::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        // Deprecated global index of the staking system.
        // Was used in V0, to calculate the accrued interest.
        // global_index: Index,
        // Deprecated timestamp of the last global index update, used in V0.
        // global_index_last_update_timestamp: Timestamp,
        // Minimum amount of initial stake.
        min_stake: Amount,
        // Map staker address to their staker info.
        staker_info: Map<ContractAddress, VersionedInternalStakerInfo>,
        // Map operational address to staker address, as it must be a 1 to 1 mapping.
        operational_address_to_staker_address: Map<ContractAddress, ContractAddress>,
        // Map potential operational address to eligible staker address.
        eligible_operational_addresses: Map<ContractAddress, ContractAddress>,
        // A dispatcher of the token contract.
        token_dispatcher: IERC20Dispatcher,
        // Deprecated field of the total stake, used in V0.
        // total_stake: Amount,
        // The class hash of the delegation pool contract.
        pool_contract_class_hash: ClassHash,
        // Undelegate intents from pool contracts.
        pool_exit_intents: Map<UndelegateIntentKey, UndelegateIntentValue>,
        // A dispatcher of the reward supplier contract.
        reward_supplier_dispatcher: IRewardSupplierDispatcher,
        // Initial governor address of the spinned-off delegation pool contract.
        pool_contract_admin: ContractAddress,
        // Storage of the `pause` flag state.
        is_paused: bool,
        // Required delay (in seconds) between unstake intent and unstake action.
        exit_wait_window: TimeDelta,
        // Epoch info.
        epoch_info: EpochInfo,
        // The contract that staker sends attestation transaction to.
        attestation_contract: ContractAddress,
        // Map version to class hash of the contract.
        prev_class_hash: Map<Version, ClassHash>,
        // Stores checkpoints tracking total stake changes over time, with each checkpoint mapping
        // an epoch to the updated stake. Stakers that performed unstake_intent are not included.
        total_stake_trace: Trace,
        // Map staker address to their balance trace.
        staker_balance_trace: Map<ContractAddress, StakerBalanceTrace>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ReplaceabilityEvent: ReplaceabilityComponent::Event,
        #[flat]
        RolesEvent: RolesComponent::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        StakeBalanceChanged: Events::StakeBalanceChanged,
        NewDelegationPool: Events::NewDelegationPool,
        StakerExitIntent: Events::StakerExitIntent,
        StakerRewardAddressChanged: Events::StakerRewardAddressChanged,
        OperationalAddressChanged: Events::OperationalAddressChanged,
        NewStaker: Events::NewStaker,
        CommissionChanged: Events::CommissionChanged,
        StakerRewardClaimed: Events::StakerRewardClaimed,
        DeleteStaker: Events::DeleteStaker,
        RewardsSuppliedToDelegationPool: Events::RewardsSuppliedToDelegationPool,
        Paused: PauseEvents::Paused,
        Unpaused: PauseEvents::Unpaused,
        MinimumStakeChanged: ConfigEvents::MinimumStakeChanged,
        ExitWaitWindowChanged: ConfigEvents::ExitWaitWindowChanged,
        RewardSupplierChanged: ConfigEvents::RewardSupplierChanged,
        EpochInfoChanged: ConfigEvents::EpochInfoChanged,
        OperationalAddressDeclared: Events::OperationalAddressDeclared,
        RemoveFromDelegationPoolIntent: Events::RemoveFromDelegationPoolIntent,
        RemoveFromDelegationPoolAction: Events::RemoveFromDelegationPoolAction,
        ChangeDelegationPoolIntent: Events::ChangeDelegationPoolIntent,
        CommissionCommitmentSet: Events::CommissionCommitmentSet,
        StakerRewardsUpdated: Events::StakerRewardsUpdated,
    }

    #[constructor]
    pub fn constructor(
        ref self: ContractState,
        token_address: ContractAddress,
        min_stake: Amount,
        pool_contract_class_hash: ClassHash,
        reward_supplier: ContractAddress,
        pool_contract_admin: ContractAddress,
        governance_admin: ContractAddress,
        prev_class_hash: ClassHash,
        epoch_info: EpochInfo,
        attestation_contract: ContractAddress,
    ) {
        self.roles.initialize(:governance_admin);
        self.replaceability.initialize(upgrade_delay: Zero::zero());
        self.token_dispatcher.write(IERC20Dispatcher { contract_address: token_address });
        self.min_stake.write(min_stake);
        self.pool_contract_class_hash.write(pool_contract_class_hash);
        self
            .reward_supplier_dispatcher
            .write(IRewardSupplierDispatcher { contract_address: reward_supplier });
        self.pool_contract_admin.write(pool_contract_admin);
        self.exit_wait_window.write(DEFAULT_EXIT_WAIT_WINDOW);
        self.is_paused.write(false);
        self.prev_class_hash.write(PREV_CONTRACT_VERSION, prev_class_hash);
        self.epoch_info.write(epoch_info);
        self.attestation_contract.write(attestation_contract);
        self.total_stake_trace.insert(key: STARTING_EPOCH, value: Zero::zero());
    }

    #[abi(embed_v0)]
    impl _Identity of Identity<ContractState> {
        fn identify(self: @ContractState) -> felt252 nopanic {
            CONTRACT_IDENTITY
        }

        fn version(self: @ContractState) -> felt252 nopanic {
            CONTRACT_VERSION
        }
    }

    #[abi(embed_v0)]
    impl StakingImpl of IStaking<ContractState> {
        fn stake(
            ref self: ContractState,
            reward_address: ContractAddress,
            operational_address: ContractAddress,
            amount: Amount,
            pool_enabled: bool,
            commission: Commission,
        ) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let staker_address = get_caller_address();
            assert!(
                self.staker_info.read(staker_address).is_none(), "{}", GenericError::STAKER_EXISTS,
            );
            assert!(
                self.operational_address_to_staker_address.read(operational_address).is_zero(),
                "{}",
                GenericError::OPERATIONAL_EXISTS,
            );
            self.assert_staker_address_not_reused(:staker_address);
            assert!(amount >= self.min_stake.read(), "{}", Error::AMOUNT_LESS_THAN_MIN_STAKE);
            assert!(commission <= COMMISSION_DENOMINATOR, "{}", Error::COMMISSION_OUT_OF_RANGE);

            // Transfer funds from staker. Sufficient approvals is a pre-condition.
            let staking_contract = get_contract_address();
            let token_dispatcher = self.token_dispatcher.read();
            token_dispatcher
                .checked_transfer_from(
                    sender: staker_address, recipient: staking_contract, amount: amount.into(),
                );

            // If pool is enabled, deploy a pool contract.
            let pool_info = if pool_enabled {
                let pool_contract = self
                    .deploy_delegation_pool_from_staking_contract(
                        :staker_address,
                        :staking_contract,
                        token_address: token_dispatcher.contract_address,
                        :commission,
                    );
                Option::Some(InternalStakerPoolInfoLatest { pool_contract, commission })
            } else {
                Option::None
            };

            let staker_balance = StakerBalanceTrait::new(amount_own: amount);
            self.insert_staker_balance(:staker_address, :staker_balance);

            // Create the record for the staker.
            self
                .staker_info
                .write(
                    staker_address,
                    VersionedInternalStakerInfoTrait::new_latest(
                        :reward_address, :operational_address, :pool_info,
                    ),
                );

            // Update the operational address mapping, which is a 1 to 1 mapping.
            self.operational_address_to_staker_address.write(operational_address, staker_address);

            // Update total stake.
            self.add_to_total_stake(:amount);

            // Emit events.
            self
                .emit(
                    Events::NewStaker {
                        staker_address, reward_address, operational_address, self_stake: amount,
                    },
                );
            self
                .emit(
                    Events::StakeBalanceChanged {
                        staker_address,
                        old_self_stake: Zero::zero(),
                        old_delegated_stake: Zero::zero(),
                        new_self_stake: amount,
                        new_delegated_stake: Zero::zero(),
                    },
                );
        }

        fn increase_stake(
            ref self: ContractState, staker_address: ContractAddress, amount: Amount,
        ) -> Amount {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let caller_address = get_caller_address();
            let staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);
            assert!(
                caller_address == staker_address || caller_address == staker_info.reward_address,
                "{}",
                GenericError::CALLER_CANNOT_INCREASE_STAKE,
            );
            assert!(amount.is_non_zero(), "{}", GenericError::AMOUNT_IS_ZERO);

            // Update the staker info to account for accumulated rewards, before updating their
            // staked amount.
            let mut staker_balance = self.get_balance(:staker_address);
            let old_self_stake = staker_balance.amount_own();

            // Transfer funds from caller (which is either the staker or their reward address).
            let staking_contract_address = get_contract_address();
            let token_dispatcher = self.token_dispatcher.read();
            token_dispatcher
                .checked_transfer_from(
                    sender: caller_address,
                    recipient: staking_contract_address,
                    amount: amount.into(),
                );

            // Update staker's staked amount, and total stake.
            self.increase_staker_own_amount(:staker_address, :amount, ref :staker_balance);
            let new_self_stake = staker_balance.amount_own();

            // Emit events.
            let old_delegated_stake = staker_balance.pool_amount();
            let new_delegated_stake = old_delegated_stake;
            self
                .emit(
                    Events::StakeBalanceChanged {
                        staker_address,
                        old_self_stake,
                        old_delegated_stake,
                        new_self_stake,
                        new_delegated_stake,
                    },
                );
            staker_balance.total_amount()
        }

        fn claim_rewards(ref self: ContractState, staker_address: ContractAddress) -> Amount {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let mut staker_info = self.internal_staker_info(:staker_address);
            let caller_address = get_caller_address();
            let reward_address = staker_info.reward_address;
            assert!(
                caller_address == staker_address || caller_address == reward_address,
                "{}",
                Error::CLAIM_REWARDS_FROM_UNAUTHORIZED_ADDRESS,
            );

            // Transfer rewards to staker's reward address and write updated staker info to storage.
            // Note: `send_rewards_to_staker` alters `staker_info` thus commit to storage is
            // performed only after that.
            let amount = staker_info.unclaimed_rewards_own;
            let token_dispatcher = self.token_dispatcher.read();
            self.send_rewards_to_staker(:staker_address, ref :staker_info, :token_dispatcher);
            self.write_staker_info(:staker_address, :staker_info);
            amount
        }

        fn unstake_intent(ref self: ContractState) -> Timestamp {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let staker_address = get_caller_address();
            let mut staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);

            // Set the unstake time.
            let unstake_time = Time::now().add(delta: self.exit_wait_window.read());
            staker_info.unstake_time = Option::Some(unstake_time);
            self.write_staker_info(:staker_address, :staker_info);

            // Write off the staker's stake and delegated stake from the total stake.
            let staker_balance = self.get_balance(:staker_address);
            let total_amount = staker_balance.total_amount();
            self.remove_from_total_stake(amount: total_amount);

            let old_self_stake = staker_balance.amount_own();
            let old_delegated_stake = staker_balance.pool_amount();
            // Emit events.
            self
                .emit(
                    Events::StakerExitIntent {
                        staker_address, exit_timestamp: unstake_time, amount: total_amount,
                    },
                );
            self
                .emit(
                    Events::StakeBalanceChanged {
                        staker_address,
                        old_self_stake,
                        old_delegated_stake,
                        new_self_stake: Zero::zero(),
                        new_delegated_stake: Zero::zero(),
                    },
                );
            unstake_time
        }

        fn unstake_action(ref self: ContractState, staker_address: ContractAddress) -> Amount {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let mut staker_info = self.internal_staker_info(:staker_address);
            let unstake_time = staker_info
                .unstake_time
                .expect_with_err(Error::MISSING_UNSTAKE_INTENT);
            assert!(Time::now() >= unstake_time, "{}", GenericError::INTENT_WINDOW_NOT_FINISHED);

            // Send rewards to staker's reward address.
            // It must be part of this function's flow because staker_info is about to be erased.
            let token_dispatcher = self.token_dispatcher.read();
            self.send_rewards_to_staker(:staker_address, ref :staker_info, :token_dispatcher);

            // Return stake to staker, return delegated stake to pool, and remove staker.
            let staker_balance = self.get_balance(:staker_address);
            let staker_amount = staker_balance.amount_own();
            token_dispatcher
                .checked_transfer(recipient: staker_address, amount: staker_amount.into());
            self
                .transfer_to_pool_when_unstake(
                    :staker_address, staker_info: @staker_info, :staker_balance,
                );
            self.remove_staker(:staker_address, :staker_info);
            staker_amount
        }

        fn change_reward_address(ref self: ContractState, reward_address: ContractAddress) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let staker_address = get_caller_address();
            let mut staker_info = self.internal_staker_info(:staker_address);
            let old_address = staker_info.reward_address;

            // Update reward_address and commit to storage.
            staker_info.reward_address = reward_address;
            self.write_staker_info(:staker_address, :staker_info);

            // Emit event.
            self
                .emit(
                    Events::StakerRewardAddressChanged {
                        staker_address, new_address: reward_address, old_address,
                    },
                );
        }

        fn set_open_for_delegation(
            ref self: ContractState, commission: Commission,
        ) -> ContractAddress {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let staker_address = get_caller_address();
            let mut staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);
            assert!(commission <= COMMISSION_DENOMINATOR, "{}", Error::COMMISSION_OUT_OF_RANGE);
            assert!(staker_info.pool_info.is_none(), "{}", Error::STAKER_ALREADY_HAS_POOL);

            // Deploy delegation pool contract.
            let pool_contract = self
                .deploy_delegation_pool_from_staking_contract(
                    :staker_address,
                    staking_contract: get_contract_address(),
                    token_address: self.token_dispatcher.read().contract_address,
                    :commission,
                );

            // Update staker info and commit to storage.
            // No need to update rewards as there is no change in staked amount (own or delegated).
            staker_info
                .pool_info =
                    Option::Some(InternalStakerPoolInfoLatest { pool_contract, commission });
            self.write_staker_info(:staker_address, :staker_info);
            pool_contract
        }

        /// This function provides the staker info (with projected rewards).
        /// If the staker does not exist, it panics.
        /// This function assumes the staker trace is initialized.
        fn staker_info_v1(self: @ContractState, staker_address: ContractAddress) -> StakerInfoV1 {
            let internal_staker_info = self.internal_staker_info(:staker_address);
            let staker_balance = self.get_balance(:staker_address);
            let mut staker_info: StakerInfoV1 = internal_staker_info.into();
            // Set staker amount and pool amount from staker balance trace.
            staker_info.amount_own = staker_balance.amount_own();
            if let Option::Some(mut pool_info) = staker_info.pool_info {
                pool_info.amount = staker_balance.pool_amount();
                staker_info.pool_info = Option::Some(pool_info);
            }
            staker_info
        }

        // This function provides the staker info (with projected rewards) wrapped in an Option.
        // If the staker does not exist, it returns None.
        fn get_staker_info_v1(
            self: @ContractState, staker_address: ContractAddress,
        ) -> Option<StakerInfoV1> {
            if self.staker_info.read(staker_address).is_none() {
                return Option::None;
            }
            Option::Some(self.staker_info_v1(:staker_address))
        }

        fn get_current_epoch(self: @ContractState) -> Epoch {
            self.epoch_info.read().current_epoch()
        }

        fn get_epoch_info(self: @ContractState) -> EpochInfo {
            self.epoch_info.read()
        }


        fn contract_parameters_v1(self: @ContractState) -> StakingContractInfoV1 {
            StakingContractInfoV1 {
                min_stake: self.min_stake.read(),
                token_address: self.token_dispatcher.read().contract_address,
                attestation_contract: self.attestation_contract.read(),
                pool_contract_class_hash: self.pool_contract_class_hash.read(),
                reward_supplier: self.reward_supplier_dispatcher.read().contract_address,
                exit_wait_window: self.exit_wait_window.read(),
            }
        }

        fn get_total_stake(self: @ContractState) -> Amount {
            let total_stake_trace = self.total_stake_trace;
            // Trace is initialized with a zero stake at the first valid epoch, so it is safe to
            // unwrap.
            let (_, total_stake) = total_stake_trace.latest().unwrap().into();
            total_stake
        }

        fn get_current_total_staking_power(self: @ContractState) -> Amount {
            let total_stake_trace = self.total_stake_trace;
            let current_epoch = self.get_current_epoch();
            let (epoch, total_stake) = total_stake_trace.latest().unwrap();
            if epoch <= current_epoch {
                return total_stake;
            }

            let (epoch, total_stake) = total_stake_trace.penultimate().unwrap();
            assert!(epoch <= current_epoch, "{}", GenericError::INVALID_PENULTIMATE);
            total_stake
        }

        fn get_pool_exit_intent(
            self: @ContractState, undelegate_intent_key: UndelegateIntentKey,
        ) -> UndelegateIntentValue {
            let undelegate_intent_value = self.pool_exit_intents.read(undelegate_intent_key);
            // The following assertion serves as a sanity check.
            undelegate_intent_value.assert_valid();
            undelegate_intent_value
        }

        fn change_operational_address(
            ref self: ContractState, operational_address: ContractAddress,
        ) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            assert!(
                self.operational_address_to_staker_address.read(operational_address).is_zero(),
                "{}",
                GenericError::OPERATIONAL_EXISTS,
            );
            let staker_address = get_caller_address();
            let mut staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);
            assert!(
                self.eligible_operational_addresses.read(operational_address) == staker_address,
                "{}",
                Error::OPERATIONAL_NOT_ELIGIBLE,
            );

            // Set operational address and write to storage.
            let old_address = staker_info.operational_address;
            self.operational_address_to_staker_address.write(old_address, Zero::zero());
            staker_info.operational_address = operational_address;
            self.write_staker_info(:staker_address, :staker_info);
            self.operational_address_to_staker_address.write(operational_address, staker_address);

            // Emit event.
            self
                .emit(
                    Events::OperationalAddressChanged {
                        staker_address, new_address: operational_address, old_address,
                    },
                );
        }

        fn declare_operational_address(ref self: ContractState, staker_address: ContractAddress) {
            self.general_prerequisites();
            let operational_address = get_caller_address();
            assert!(
                self.operational_address_to_staker_address.read(operational_address).is_zero(),
                "{}",
                Error::OPERATIONAL_IN_USE,
            );
            if self.eligible_operational_addresses.read(operational_address) == staker_address {
                return;
            }
            self.eligible_operational_addresses.write(operational_address, staker_address);
            self.emit(Events::OperationalAddressDeclared { operational_address, staker_address });
        }

        fn update_commission(ref self: ContractState, commission: Commission) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            assert!(commission <= COMMISSION_DENOMINATOR, "{}", Error::COMMISSION_OUT_OF_RANGE);
            let staker_address = get_caller_address();
            let mut staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);

            let (pool_contract, old_commission) = {
                let pool_info = staker_info.get_pool_info();
                (pool_info.pool_contract, pool_info.commission)
            };

            if let Option::Some(commission_commitment) = staker_info.commission_commitment {
                if self.is_commission_commitment_active(:commission_commitment) {
                    assert!(
                        commission <= commission_commitment.max_commission,
                        "{}",
                        GenericError::INVALID_COMMISSION_WITH_COMMITMENT,
                    );
                    assert!(
                        commission != old_commission, "{}", GenericError::INVALID_SAME_COMMISSION,
                    );
                } else {
                    assert!(
                        commission < old_commission,
                        "{}",
                        GenericError::COMMISSION_COMMITMENT_EXPIRED,
                    );
                }
            } else {
                assert!(commission < old_commission, "{}", GenericError::INVALID_COMMISSION);
            }

            // Update commission in this contract, and in the associated pool contract.
            {
                let mut pool_info = staker_info.get_pool_info();
                pool_info.commission = commission;
                staker_info.pool_info = Option::Some(pool_info);
            }

            self.write_staker_info(:staker_address, :staker_info);

            // Emit event.
            self
                .emit(
                    Events::CommissionChanged {
                        staker_address, pool_contract, old_commission, new_commission: commission,
                    },
                );
        }

        fn set_commission_commitment(
            ref self: ContractState, max_commission: Commission, expiration_epoch: Epoch,
        ) {
            self.general_prerequisites();
            assert!(max_commission <= COMMISSION_DENOMINATOR, "{}", Error::COMMISSION_OUT_OF_RANGE);
            let staker_address = get_caller_address();
            let mut staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);
            let pool_info = staker_info.get_pool_info();
            let current_epoch = self.get_current_epoch();
            if let Option::Some(commission_commitment) = staker_info.commission_commitment {
                assert!(
                    !self.is_commission_commitment_active(:commission_commitment),
                    "{}",
                    Error::COMMISSION_COMMITMENT_EXISTS,
                );
            }
            assert!(pool_info.commission <= max_commission, "{}", Error::MAX_COMMISSION_TOO_LOW);
            assert!(expiration_epoch > current_epoch, "{}", Error::EXPIRATION_EPOCH_TOO_EARLY);
            assert!(
                expiration_epoch - current_epoch <= self.get_epoch_info().epochs_in_year(),
                "{}",
                Error::EXPIRATION_EPOCH_TOO_FAR,
            );
            let commission_commitment = CommissionCommitment { max_commission, expiration_epoch };
            staker_info.commission_commitment = Option::Some(commission_commitment);
            self.write_staker_info(:staker_address, :staker_info);
            self
                .emit(
                    Events::CommissionCommitmentSet {
                        staker_address, max_commission, expiration_epoch,
                    },
                );
        }

        fn get_staker_commission_commitment(
            self: @ContractState, staker_address: ContractAddress,
        ) -> CommissionCommitment {
            let staker_info = self.internal_staker_info(:staker_address);
            if staker_info.commission_commitment.is_none() {
                panic_with_byte_array(err: @Error::COMMISSION_COMMITMENT_NOT_SET.describe());
            }
            staker_info.commission_commitment.unwrap()
        }

        fn is_paused(self: @ContractState) -> bool {
            self.is_paused.read()
        }
    }

    #[abi(embed_v0)]
    impl StakingMigrationImpl of IStakingMigration<ContractState> {
        fn internal_staker_info(
            self: @ContractState, staker_address: ContractAddress,
        ) -> InternalStakerInfoLatest {
            let versioned_internal_staker_info = self.staker_info.read(staker_address);
            match versioned_internal_staker_info {
                VersionedInternalStakerInfo::None => panic_with_byte_array(
                    err: @GenericError::STAKER_NOT_EXISTS.describe(),
                ),
                VersionedInternalStakerInfo::V0(_) => panic_with_byte_array(
                    err: @Error::INTERNAL_STAKER_INFO_OUTDATED_VERSION.describe(),
                ),
                VersionedInternalStakerInfo::V1(internal_staker_info_v1) => internal_staker_info_v1,
            }
        }

        fn staker_migration(ref self: ContractState, staker_address: ContractAddress) {
            let versioned_internal_staker_info = self.staker_info.read(staker_address);
            match versioned_internal_staker_info {
                VersionedInternalStakerInfo::None => panic_with_byte_array(
                    err: @GenericError::STAKER_NOT_EXISTS.describe(),
                ),
                VersionedInternalStakerInfo::V0(internal_staker_info_v0) => {
                    if let Option::Some(_) = internal_staker_info_v0.pool_info() {
                        panic_with_byte_array(
                            err: @Error::STAKER_MIGRATION_NOT_ALLOWED_WITH_POOL.describe(),
                        )
                    }
                    self.convert_internal_staker_info(:staker_address)
                },
                VersionedInternalStakerInfo::V1(_) => panic_with_byte_array(
                    err: @Error::INTERNAL_STAKER_INFO_ALREADY_UPDATED.describe(),
                ),
            };
        }
    }

    #[abi(embed_v0)]
    impl StakingPoolImpl of IStakingPool<ContractState> {
        fn add_stake_from_pool(
            ref self: ContractState, staker_address: ContractAddress, amount: Amount,
        ) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);
            let pool_info = staker_info.get_pool_info();
            let pool_contract = pool_info.pool_contract;
            assert!(
                get_caller_address() == pool_contract, "{}", Error::CALLER_IS_NOT_POOL_CONTRACT,
            );

            // Transfer funds from the pool contract to the staking contract.
            // Sufficient approval is a pre-condition.
            let token_dispatcher = self.token_dispatcher.read();
            token_dispatcher
                .checked_transfer_from(
                    sender: pool_contract, recipient: get_contract_address(), amount: amount.into(),
                );

            // Update the staker's staked amount, and add to total_stake.
            let mut staker_balance = self.get_balance(:staker_address);
            let old_delegated_stake = staker_balance.pool_amount();
            let new_delegated_stake = old_delegated_stake + amount;
            self
                .update_staker_pool_amount(
                    :staker_address, ref :staker_balance, amount: new_delegated_stake,
                );
            self.add_to_total_stake(:amount);

            // Emit event.
            let self_stake = staker_balance.amount_own();
            self
                .emit(
                    Events::StakeBalanceChanged {
                        staker_address,
                        old_self_stake: self_stake,
                        old_delegated_stake,
                        new_self_stake: self_stake,
                        new_delegated_stake,
                    },
                );
        }

        fn remove_from_delegation_pool_intent(
            ref self: ContractState,
            staker_address: ContractAddress,
            identifier: felt252,
            amount: Amount,
        ) -> Timestamp {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let staker_info = self.internal_staker_info(:staker_address);
            self.assert_caller_is_pool_contract(staker_info: @staker_info);
            let mut staker_balance = self.get_balance(:staker_address);

            let (old_delegated_stake, pool_contract) = {
                let pool_info = staker_info.get_pool_info();
                (staker_balance.pool_amount(), pool_info.pool_contract)
            };

            // Update the delegated stake according to the new intent.
            let undelegate_intent_key = UndelegateIntentKey { pool_contract, identifier };
            let old_intent_amount = self.get_pool_exit_intent(:undelegate_intent_key).amount;
            let new_intent_amount = amount;
            // After this call, the staker balance will be updated.
            self
                .update_delegated_stake(
                    :staker_address,
                    :staker_info,
                    :old_intent_amount,
                    :new_intent_amount,
                    ref :staker_balance,
                );
            self
                .update_undelegate_intent_value(
                    :staker_info, :undelegate_intent_key, :new_intent_amount,
                );

            self
                .emit(
                    Events::RemoveFromDelegationPoolIntent {
                        staker_address,
                        pool_contract,
                        identifier,
                        old_intent_amount,
                        new_intent_amount,
                    },
                );
            // If the staker is in the process of unstaking (intent called),
            // an event indicating the staked amount (own and delegated) to be zero
            // had already been emitted, thus unneeded now.
            if staker_info.unstake_time.is_none() {
                let staker_amount_own = staker_balance.amount_own();
                self
                    .emit(
                        Events::StakeBalanceChanged {
                            staker_address,
                            old_self_stake: staker_amount_own,
                            old_delegated_stake,
                            new_self_stake: staker_amount_own,
                            new_delegated_stake: staker_balance.pool_amount(),
                        },
                    );
            }
            self.get_pool_exit_intent(:undelegate_intent_key).unpool_time
        }

        fn remove_from_delegation_pool_action(ref self: ContractState, identifier: felt252) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            let pool_contract = get_caller_address();
            let undelegate_intent_key = UndelegateIntentKey { pool_contract, identifier };
            let undelegate_intent = self.get_pool_exit_intent(:undelegate_intent_key);
            if undelegate_intent.amount.is_zero() {
                return;
            }
            assert!(
                Time::now() >= undelegate_intent.unpool_time,
                "{}",
                GenericError::INTENT_WINDOW_NOT_FINISHED,
            );

            // Clear the intent, and transfer the intent amount to the pool contract.
            self.clear_undelegate_intent(:undelegate_intent_key);
            let token_dispatcher = self.token_dispatcher.read();
            token_dispatcher
                .checked_transfer(
                    recipient: pool_contract, amount: undelegate_intent.amount.into(),
                );

            // Emit event.
            self
                .emit(
                    Events::RemoveFromDelegationPoolAction {
                        pool_contract, identifier, amount: undelegate_intent.amount,
                    },
                );
        }

        fn switch_staking_delegation_pool(
            ref self: ContractState,
            to_staker: ContractAddress,
            to_pool: ContractAddress,
            switched_amount: Amount,
            data: Span<felt252>,
            identifier: felt252,
        ) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            if switched_amount.is_zero() {
                return;
            }
            let from_pool = get_caller_address();
            let undelegate_intent_key = UndelegateIntentKey {
                pool_contract: from_pool, identifier,
            };
            let mut undelegate_intent_value = self.get_pool_exit_intent(:undelegate_intent_key);
            assert!(
                undelegate_intent_value.is_non_zero(), "{}", PoolError::MISSING_UNDELEGATE_INTENT,
            );
            assert!(
                switched_amount <= undelegate_intent_value.amount,
                "{}",
                GenericError::AMOUNT_TOO_HIGH,
            );
            let old_intent_amount = undelegate_intent_value.amount;
            assert!(to_pool != from_pool, "{}", Error::SELF_SWITCH_NOT_ALLOWED);

            let to_staker_info = self.internal_staker_info(staker_address: to_staker);

            // More asserts.
            assert!(to_staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);
            let to_staker_pool_info = to_staker_info.get_pool_info();
            let to_staker_pool_contract = to_staker_pool_info.pool_contract;
            assert!(to_pool == to_staker_pool_contract, "{}", Error::DELEGATION_POOL_MISMATCH);

            // Update `to_staker`'s delegated stake amount, and add to total stake.
            let mut to_staker_balance = self.get_balance(staker_address: to_staker);
            let old_delegated_stake = to_staker_balance.pool_amount();
            let new_delegated_stake = old_delegated_stake + switched_amount;
            self
                .update_staker_pool_amount(
                    staker_address: to_staker,
                    ref staker_balance: to_staker_balance,
                    amount: new_delegated_stake,
                );
            self.add_to_total_stake(amount: switched_amount);

            // Update the undelegate intent. If the amount is zero, clear the intent.
            undelegate_intent_value.amount -= switched_amount;
            if undelegate_intent_value.amount.is_zero() {
                self.clear_undelegate_intent(:undelegate_intent_key);
            } else {
                self.pool_exit_intents.write(undelegate_intent_key, undelegate_intent_value);
            }

            // Notify `to_pool` about the new delegation.
            let to_pool_dispatcher = IPoolDispatcher { contract_address: to_pool };
            to_pool_dispatcher
                .enter_delegation_pool_from_staking_contract(amount: switched_amount, :data);

            // Emit event.
            let to_staker_self_stake = to_staker_balance.amount_own();
            self
                .emit(
                    Events::StakeBalanceChanged {
                        staker_address: to_staker,
                        old_self_stake: to_staker_self_stake,
                        old_delegated_stake,
                        new_self_stake: to_staker_self_stake,
                        new_delegated_stake,
                    },
                );
            self
                .emit(
                    Events::ChangeDelegationPoolIntent {
                        pool_contract: from_pool,
                        identifier,
                        old_intent_amount,
                        new_intent_amount: undelegate_intent_value.amount,
                    },
                );
        }

        fn pool_migration(ref self: ContractState, staker_address: ContractAddress) -> Index {
            // Prerequisites and asserts.
            self.assert_caller_is_not_zero();
            let (staker_info, staker_index, pool_unclaimed_rewards) = self
                .convert_internal_staker_info(:staker_address);
            let pool_address = staker_info.get_pool_info().pool_contract;
            assert!(get_caller_address() == pool_address, "{}", Error::CALLER_IS_NOT_POOL_CONTRACT);

            // Send rewards to pool contract, and commit to storage.
            let token_dispatcher = self.token_dispatcher.read();
            self
                ._deprecated_send_rewards_to_delegation_pool_V0(
                    :staker_address, :staker_info, :pool_unclaimed_rewards, :token_dispatcher,
                );
            self.write_staker_info(:staker_address, :staker_info);

            staker_index
        }
    }

    #[abi(embed_v0)]
    impl StakingPauseImpl of IStakingPause<ContractState> {
        fn pause(ref self: ContractState) {
            self.roles.only_security_agent();
            if self.is_paused() {
                return;
            }
            self.is_paused.write(true);
            self.emit(PauseEvents::Paused { account: get_caller_address() });
        }

        fn unpause(ref self: ContractState) {
            self.roles.only_security_admin();
            if !self.is_paused() {
                return;
            }
            self.is_paused.write(false);
            self.emit(PauseEvents::Unpaused { account: get_caller_address() });
        }
    }

    #[abi(embed_v0)]
    impl StakingConfigImpl of IStakingConfig<ContractState> {
        fn set_min_stake(ref self: ContractState, min_stake: Amount) {
            self.roles.only_token_admin();
            let old_min_stake = self.min_stake.read();
            self.min_stake.write(min_stake);
            self
                .emit(
                    ConfigEvents::MinimumStakeChanged { old_min_stake, new_min_stake: min_stake },
                );
        }

        fn set_exit_wait_window(ref self: ContractState, exit_wait_window: TimeDelta) {
            self.roles.only_token_admin();
            assert!(exit_wait_window <= MAX_EXIT_WAIT_WINDOW, "{}", Error::ILLEGAL_EXIT_DURATION);
            let old_exit_window = self.exit_wait_window.read();
            self.exit_wait_window.write(exit_wait_window);
            self
                .emit(
                    ConfigEvents::ExitWaitWindowChanged {
                        old_exit_window, new_exit_window: exit_wait_window,
                    },
                );
        }

        fn set_reward_supplier(ref self: ContractState, reward_supplier: ContractAddress) {
            self.roles.only_token_admin();
            let old_reward_supplier = self.reward_supplier_dispatcher.read().contract_address;
            self
                .reward_supplier_dispatcher
                .write(IRewardSupplierDispatcher { contract_address: reward_supplier });
            self
                .emit(
                    ConfigEvents::RewardSupplierChanged {
                        old_reward_supplier, new_reward_supplier: reward_supplier,
                    },
                );
        }

        fn set_epoch_info(ref self: ContractState, epoch_duration: u32, epoch_length: u32) {
            self.roles.only_token_admin();
            let mut epoch_info = self.epoch_info.read();
            epoch_info.update(:epoch_duration, :epoch_length);
            self.epoch_info.write(epoch_info);
            self.emit(ConfigEvents::EpochInfoChanged { epoch_duration, epoch_length });
        }
    }

    #[abi(embed_v0)]
    impl StakingAttestationImpl of IStakingAttestation<ContractState> {
        /// Calculate and update rewards for the `staker_address` for the current epoch.
        /// Send pool rewards to the pool.
        /// This is called after the attestation contract validate that the staker has attested
        /// correctly.
        fn update_rewards_from_attestation_contract(
            ref self: ContractState, staker_address: ContractAddress,
        ) {
            // Prerequisites and asserts.
            self.general_prerequisites();
            assert!(
                get_caller_address() == self.attestation_contract.read(),
                "{}",
                Error::CALLER_IS_NOT_ATTESTATION_CONTRACT,
            );
            let mut staker_info = self.internal_staker_info(:staker_address);
            assert!(staker_info.unstake_time.is_none(), "{}", Error::UNSTAKE_IN_PROGRESS);

            // Calculate and update rewards.
            let total_rewards = self.calculate_staker_total_rewards(:staker_address);
            self.update_reward_supplier(rewards: total_rewards);
            let staker_rewards = self
                .calculate_staker_own_rewards_including_commission(
                    :staker_info, :total_rewards, :staker_address,
                );
            staker_info.unclaimed_rewards_own += staker_rewards;
            let pool_rewards = total_rewards - staker_rewards;
            self
                .emit(
                    Events::StakerRewardsUpdated { staker_address, staker_rewards, pool_rewards },
                );
            self.update_pool_rewards(:staker_address, :staker_info, :pool_rewards);
            self.write_staker_info(:staker_address, :staker_info);
        }

        fn get_attestation_info_by_operational_address(
            self: @ContractState, operational_address: ContractAddress,
        ) -> AttestationInfo {
            let staker_address = self.get_staker_address_by_operational(:operational_address);

            // Return the attestation info.
            let epoch_info = self.get_epoch_info();
            let epoch_len = epoch_info.epoch_len_in_blocks();
            let epoch_id = epoch_info.current_epoch();
            let current_epoch_starting_block = epoch_info.current_epoch_starting_block();
            AttestationInfoTrait::new(
                staker_address: staker_address,
                stake: self.get_staker_balance_curr_epoch(:staker_address).total_amount(),
                epoch_len: epoch_len,
                epoch_id: epoch_id,
                current_epoch_starting_block: current_epoch_starting_block,
            )
        }
    }

    #[generate_trait]
    pub(crate) impl InternalStakingMigration of IStakingMigrationInternal {
        /// Returns the class hash of the previous contract version.
        ///
        /// **Note**: This function must be reimplemented in the next version of the contract.
        fn get_prev_class_hash(self: @ContractState) -> ClassHash {
            self.prev_class_hash.read(PREV_CONTRACT_VERSION)
        }
    }

    #[generate_trait]
    pub(crate) impl InternalStakingFunctions of InternalStakingFunctionsTrait {
        /// Reads the internal staker information for the given `staker_address` from storage
        /// and converts it to V1. Writes the updated version to storage and initializes the
        /// staker's balance trace.
        ///
        /// Precondition: The staker exists and its version is V0.
        ///
        /// This function is used only during migration.
        fn convert_internal_staker_info(
            ref self: ContractState, staker_address: ContractAddress,
        ) -> (InternalStakerInfoLatest, Index, Amount) {
            let versioned_internal_staker_info = self.staker_info.read(staker_address);
            match versioned_internal_staker_info {
                VersionedInternalStakerInfo::None => panic_with_byte_array(
                    err: @GenericError::STAKER_NOT_EXISTS.describe(),
                ),
                VersionedInternalStakerInfo::V0(internal_staker_info_v0) => {
                    let (
                        internal_staker_info_v1,
                        amount_own,
                        index,
                        pool_unclaimed_rewards,
                        pool_amount,
                    ) =
                        internal_staker_info_v0
                        .convert(self.get_prev_class_hash(), staker_address);
                    self
                        .staker_info
                        .write(
                            staker_address,
                            VersionedInternalStakerInfo::V1(internal_staker_info_v1),
                        );
                    self
                        .initialize_staker_balance_trace(
                            :staker_address, :amount_own, :pool_amount,
                        );
                    (internal_staker_info_v1, index, pool_unclaimed_rewards)
                },
                VersionedInternalStakerInfo::V1(_) => panic_with_byte_array(
                    err: @Error::INTERNAL_STAKER_INFO_ALREADY_UPDATED.describe(),
                ),
            }
        }

        fn send_rewards(
            self: @ContractState,
            reward_address: ContractAddress,
            amount: Amount,
            token_dispatcher: IERC20Dispatcher,
        ) {
            let reward_supplier_dispatcher = self.reward_supplier_dispatcher.read();
            let staking_contract = get_contract_address();
            let balance_before = token_dispatcher.balance_of(account: staking_contract);
            reward_supplier_dispatcher.claim_rewards(:amount);
            let balance_after = token_dispatcher.balance_of(account: staking_contract);
            assert!(
                balance_after - balance_before == amount.into(), "{}", Error::UNEXPECTED_BALANCE,
            );
            token_dispatcher.checked_transfer(recipient: reward_address, amount: amount.into());
        }

        /// Sends the rewards to `staker_address`'s reward address.
        /// Important note:
        /// After calling this function, one must write the updated staker_info to the storage.
        fn send_rewards_to_staker(
            ref self: ContractState,
            staker_address: ContractAddress,
            ref staker_info: InternalStakerInfoLatest,
            token_dispatcher: IERC20Dispatcher,
        ) {
            let reward_address = staker_info.reward_address;
            let amount = staker_info.unclaimed_rewards_own;

            self.send_rewards(:reward_address, :amount, :token_dispatcher);
            staker_info.unclaimed_rewards_own = Zero::zero();

            self.emit(Events::StakerRewardClaimed { staker_address, reward_address, amount });
        }
        /// Sends the rewards to `staker_address`'s pool contract.
        /// Important note:
        /// After calling this function, one must write the updated staker_info to the storage.
        /// This function is deprecated and should not be used (only use in migration), use
        /// `send_rewards_to_delegation_pool` instead.
        fn _deprecated_send_rewards_to_delegation_pool_V0(
            ref self: ContractState,
            staker_address: ContractAddress,
            staker_info: InternalStakerInfoLatest,
            pool_unclaimed_rewards: Amount,
            token_dispatcher: IERC20Dispatcher,
        ) {
            let pool_info = staker_info.get_pool_info();
            let pool_address = pool_info.pool_contract;
            let amount = pool_unclaimed_rewards;

            self.send_rewards(reward_address: pool_address, :amount, :token_dispatcher);

            self
                .emit(
                    Events::RewardsSuppliedToDelegationPool {
                        staker_address, pool_address, amount,
                    },
                );
        }

        /// Sends the rewards to `staker_address`'s pool contract.
        fn send_rewards_to_delegation_pool(
            ref self: ContractState,
            staker_address: ContractAddress,
            pool_address: ContractAddress,
            amount: Amount,
            token_dispatcher: IERC20Dispatcher,
        ) {
            self.send_rewards(reward_address: pool_address, :amount, :token_dispatcher);
            self
                .emit(
                    Events::RewardsSuppliedToDelegationPool {
                        staker_address, pool_address, amount,
                    },
                );
        }

        fn clear_undelegate_intent(
            ref self: ContractState, undelegate_intent_key: UndelegateIntentKey,
        ) {
            self.pool_exit_intents.write(undelegate_intent_key, Zero::zero());
        }

        fn assert_is_unpaused(self: @ContractState) {
            assert!(!self.is_paused(), "{}", Error::CONTRACT_IS_PAUSED);
        }

        fn transfer_to_pool_when_unstake(
            ref self: ContractState,
            staker_address: ContractAddress,
            staker_info: @InternalStakerInfoLatest,
            staker_balance: StakerBalance,
        ) {
            if let Option::Some(pool_info) = staker_info.pool_info {
                let token_dispatcher = self.token_dispatcher.read();
                token_dispatcher
                    .checked_transfer(
                        recipient: *pool_info.pool_contract,
                        amount: staker_balance.pool_amount().into(),
                    );
                let pool_dispatcher = IPoolDispatcher {
                    contract_address: *pool_info.pool_contract,
                };
                pool_dispatcher.set_staker_removed();
            }
        }

        fn remove_staker(
            ref self: ContractState,
            staker_address: ContractAddress,
            staker_info: InternalStakerInfoLatest,
        ) {
            self.insert_staker_balance(:staker_address, staker_balance: Zero::zero());
            self.staker_info.write(staker_address, VersionedInternalStakerInfo::None);
            let operational_address = staker_info.operational_address;
            self.operational_address_to_staker_address.write(operational_address, Zero::zero());
            self
                .emit(
                    Events::DeleteStaker {
                        staker_address,
                        reward_address: staker_info.reward_address,
                        operational_address,
                        pool_contract: match staker_info.pool_info {
                            Option::Some(pool_info) => Option::Some(pool_info.pool_contract),
                            Option::None => Option::None,
                        },
                    },
                );
        }

        fn deploy_delegation_pool_from_staking_contract(
            ref self: ContractState,
            staker_address: ContractAddress,
            staking_contract: ContractAddress,
            token_address: ContractAddress,
            commission: Commission,
        ) -> ContractAddress {
            let class_hash = self.pool_contract_class_hash.read();
            let contract_address_salt: felt252 = Time::now().seconds.into();
            let governance_admin = self.pool_contract_admin.read();
            let pool_contract = deploy_delegation_pool_contract(
                :class_hash,
                :contract_address_salt,
                :staker_address,
                :staking_contract,
                :token_address,
                :governance_admin,
            );
            self.emit(Events::NewDelegationPool { staker_address, pool_contract, commission });
            pool_contract
        }

        // Adjusts the total stake based on changes in the delegated amount.
        fn update_total_stake_according_to_delegated_stake_changes(
            ref self: ContractState, old_delegated_stake: Amount, new_delegated_stake: Amount,
        ) {
            if new_delegated_stake < old_delegated_stake {
                self.remove_from_total_stake(amount: old_delegated_stake - new_delegated_stake);
            } else {
                self.add_to_total_stake(amount: new_delegated_stake - old_delegated_stake);
            }
        }

        fn add_to_total_stake(ref self: ContractState, amount: Amount) {
            self.update_total_stake(new_total_stake: self.get_total_stake() + amount);
        }

        fn remove_from_total_stake(ref self: ContractState, amount: Amount) {
            self.update_total_stake(new_total_stake: self.get_total_stake() - amount);
        }

        fn update_total_stake(ref self: ContractState, new_total_stake: Amount) {
            self.total_stake_trace.insert(key: self.get_next_epoch(), value: new_total_stake);
        }

        /// Wrap initial operations required in any public staking function.
        fn general_prerequisites(ref self: ContractState) {
            self.assert_is_unpaused();
            self.assert_caller_is_not_zero();
        }

        fn assert_caller_is_pool_contract(
            self: @ContractState, staker_info: @InternalStakerInfoLatest,
        ) {
            let pool_info = staker_info.get_pool_info();
            assert!(
                get_caller_address() == pool_info.pool_contract,
                "{}",
                Error::CALLER_IS_NOT_POOL_CONTRACT,
            );
        }

        fn assert_caller_is_not_zero(self: @ContractState) {
            assert!(get_caller_address().is_non_zero(), "{}", Error::CALLER_IS_ZERO_ADDRESS);
        }

        /// Updates the delegated stake amount in the given `staker_balance` according to changes
        /// in the intent amount. Also updates the total stake accordingly.
        fn update_delegated_stake(
            ref self: ContractState,
            staker_address: ContractAddress,
            staker_info: InternalStakerInfoLatest,
            old_intent_amount: Amount,
            new_intent_amount: Amount,
            ref staker_balance: StakerBalance,
        ) {
            let old_delegated_stake = staker_balance.pool_amount();
            let new_delegated_stake = compute_new_delegated_stake(
                :old_delegated_stake, :old_intent_amount, :new_intent_amount,
            );

            // Do not update the total stake when the staker is in the process of unstaking,
            // since its delegated stake is already excluded from the total stake.
            if staker_info.unstake_time.is_none() {
                self
                    .update_total_stake_according_to_delegated_stake_changes(
                        :old_delegated_stake, :new_delegated_stake,
                    )
            }
            self
                .update_staker_pool_amount(
                    :staker_address, ref :staker_balance, amount: new_delegated_stake,
                );
        }

        /// Updates undelegate intent value with the given `new_intent_amount` and an updated unpool
        /// time.
        fn update_undelegate_intent_value(
            ref self: ContractState,
            staker_info: InternalStakerInfoLatest,
            undelegate_intent_key: UndelegateIntentKey,
            new_intent_amount: Amount,
        ) {
            let undelegate_intent_value = if new_intent_amount.is_zero() {
                Zero::zero()
            } else {
                let unpool_time = staker_info
                    .compute_unpool_time(exit_wait_window: self.exit_wait_window.read());
                UndelegateIntentValue { amount: new_intent_amount, unpool_time }
            };
            self.pool_exit_intents.write(undelegate_intent_key, undelegate_intent_value);
        }

        fn calculate_staker_total_rewards(
            ref self: ContractState, staker_address: ContractAddress,
        ) -> Amount {
            let epoch_rewards = self
                .reward_supplier_dispatcher
                .read()
                .calculate_current_epoch_rewards();
            mul_wide_and_div(
                lhs: epoch_rewards,
                rhs: self.get_staker_balance_curr_epoch(:staker_address).total_amount(),
                div: self.get_current_total_staking_power(),
            )
                .expect_with_err(err: GenericError::REWARDS_ISNT_AMOUNT_TYPE)
        }

        fn calculate_staker_own_rewards_including_commission(
            ref self: ContractState,
            staker_info: InternalStakerInfoLatest,
            total_rewards: Amount,
            staker_address: ContractAddress,
        ) -> Amount {
            let own_rewards = self.staker_own_rewards(:staker_address, :total_rewards);
            let commission_rewards = self
                .get_staker_commission_rewards(
                    :staker_info, pool_rewards: total_rewards - own_rewards,
                );
            own_rewards + commission_rewards
        }

        fn update_pool_rewards(
            ref self: ContractState,
            staker_address: ContractAddress,
            staker_info: InternalStakerInfoLatest,
            pool_rewards: Amount,
        ) {
            if let Option::Some(pool_info) = staker_info.pool_info {
                let pool_contract = pool_info.pool_contract;
                let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract };
                let pool_balance = self.get_pool_balance_curr_epoch(:staker_address);
                pool_dispatcher
                    .update_rewards_from_staking_contract(rewards: pool_rewards, :pool_balance);
                self
                    .send_rewards_to_delegation_pool(
                        :staker_address,
                        pool_address: pool_contract,
                        amount: pool_rewards,
                        token_dispatcher: self.token_dispatcher.read(),
                    );
            }
        }

        fn update_reward_supplier(ref self: ContractState, rewards: Amount) {
            let reward_supplier_dispatcher = self.reward_supplier_dispatcher.read();
            reward_supplier_dispatcher.update_unclaimed_rewards_from_staking_contract(:rewards);
        }

        fn staker_own_rewards(
            ref self: ContractState, staker_address: ContractAddress, total_rewards: Amount,
        ) -> Amount {
            let staker_balance_curr_epoch = self.get_staker_balance_curr_epoch(:staker_address);
            let own_rewards = mul_wide_and_div(
                lhs: total_rewards,
                rhs: staker_balance_curr_epoch.amount_own(),
                div: staker_balance_curr_epoch.total_amount(),
            )
                .expect_with_err(err: GenericError::REWARDS_ISNT_AMOUNT_TYPE);
            own_rewards
        }

        fn get_staker_commission_rewards(
            self: @ContractState, staker_info: InternalStakerInfoLatest, pool_rewards: Amount,
        ) -> Amount {
            if let Option::Some(pool_info) = staker_info.pool_info {
                return compute_commission_amount_rounded_down(
                    rewards_including_commission: pool_rewards, commission: pool_info.commission,
                );
            }
            Zero::zero()
        }

        fn get_next_epoch(self: @ContractState) -> Epoch {
            self.get_current_epoch() + 1
        }

        fn insert_staker_balance(
            ref self: ContractState, staker_address: ContractAddress, staker_balance: StakerBalance,
        ) {
            self
                .staker_balance_trace
                .entry(staker_address)
                .insert(key: self.get_next_epoch(), value: staker_balance);
        }

        /// Return the latest `staker_balance` recorded in the `staker_balance_trace`.
        fn get_balance(self: @ContractState, staker_address: ContractAddress) -> StakerBalance {
            let trace = self.staker_balance_trace.entry(key: staker_address);
            assert!(trace.is_non_empty(), "{}", Error::STAKER_BALANCE_NOT_INITIALIZED);
            let (_, staker_balance) = trace.latest();
            staker_balance
        }

        /// **Note**: This function should be called only once during migration.
        fn initialize_staker_balance_trace(
            ref self: ContractState,
            staker_address: ContractAddress,
            amount_own: Amount,
            pool_amount: Amount,
        ) -> StakerBalance {
            let staker_info = self.internal_staker_info(:staker_address);
            let mut staker_balance = StakerBalanceTrait::new(:amount_own);
            if staker_info.pool_info.is_some() {
                staker_balance.update_pool_amount(new_amount: pool_amount);
            }
            self
                .staker_balance_trace
                .entry(key: staker_address)
                .insert(key: STARTING_EPOCH, value: staker_balance);
            staker_balance
        }

        fn get_pool_balance_curr_epoch(
            self: @ContractState, staker_address: ContractAddress,
        ) -> Amount {
            self.get_staker_balance_curr_epoch(:staker_address).pool_amount()
        }

        fn get_staker_balance_curr_epoch(
            self: @ContractState, staker_address: ContractAddress,
        ) -> StakerBalance {
            let trace = self.staker_balance_trace.entry(key: staker_address);
            let (epoch, staker_balance) = trace.latest();
            if epoch <= self.get_current_epoch() {
                staker_balance
            } else {
                let (epoch, staker_balance) = trace.penultimate();
                // TODO: Catch this assert in tests.
                assert!(epoch <= self.get_current_epoch(), "{}", GenericError::INVALID_PENULTIMATE);
                staker_balance
            }
        }


        fn increase_staker_own_amount(
            ref self: ContractState,
            staker_address: ContractAddress,
            amount: Amount,
            ref staker_balance: StakerBalance,
        ) {
            staker_balance.increase_own_amount(:amount);
            self.insert_staker_balance(:staker_address, :staker_balance);
            self.add_to_total_stake(:amount);
        }

        fn update_staker_pool_amount(
            ref self: ContractState,
            staker_address: ContractAddress,
            ref staker_balance: StakerBalance,
            amount: Amount,
        ) {
            staker_balance.update_pool_amount(new_amount: amount);
            self.insert_staker_balance(:staker_address, :staker_balance);
        }

        fn is_commission_commitment_active(
            self: @ContractState, commission_commitment: CommissionCommitment,
        ) -> bool {
            self.get_current_epoch() < commission_commitment.expiration_epoch
        }

        fn get_staker_address_by_operational(
            self: @ContractState, operational_address: ContractAddress,
        ) -> ContractAddress {
            let staker_address = self
                .operational_address_to_staker_address
                .read(operational_address);
            assert!(staker_address.is_non_zero(), "{}", GenericError::STAKER_NOT_EXISTS);
            staker_address
        }

        fn write_staker_info(
            ref self: ContractState,
            staker_address: ContractAddress,
            staker_info: InternalStakerInfoLatest,
        ) {
            self
                .staker_info
                .write(staker_address, VersionedInternalStakerInfoTrait::wrap_latest(staker_info));
        }

        fn assert_staker_address_not_reused(self: @ContractState, staker_address: ContractAddress) {
            assert!(
                self.staker_balance_trace.entry(key: staker_address).is_empty(),
                "{}",
                Error::STAKER_ADDRESS_ALREADY_USED,
            );
        }
    }
}
