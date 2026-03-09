// Locker Account — Token-Bound Account for Collateral
// SNIP-14 compliant account with an allowlist-based lockdown.
// When locked, only explicitly allowed selectors (e.g. vote, delegate) can be called.
// All other outgoing calls are blocked. The Stela contract manages the allowlist
// and interacts via pull_assets/unlock (external calls INTO the locker).

#[starknet::contract(account)]
pub mod LockerAccount {
    use openzeppelin_interfaces::accounts::ISRC6_ID;
    use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_token::erc1155::ERC1155ReceiverComponent;

    // Token dispatchers
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use starknet::account::Call;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    // Local imports
    use crate::errors::Errors;
    use crate::types::asset::{Asset, AssetType};

    // Components for ERC1155 receiver support + SRC5 introspection
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: ERC1155ReceiverComponent, storage: erc1155_receiver, event: ERC1155ReceiverEvent);

    // Expose SRC5 supports_interface externally
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    // Expose ERC1155 receiver hooks externally (on_erc1155_received, on_erc1155_batch_received)
    #[abi(embed_v0)]
    impl ERC1155ReceiverImpl = ERC1155ReceiverComponent::ERC1155ReceiverImpl<ContractState>;
    #[abi(embed_v0)]
    impl ERC1155ReceiverCamelImpl = ERC1155ReceiverComponent::ERC1155ReceiverCamelImpl<ContractState>;

    impl ERC1155ReceiverInternalImpl = ERC1155ReceiverComponent::InternalImpl<ContractState>;
    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    // ============================================================
    //                          STORAGE
    // ============================================================

    #[storage]
    struct Storage {
        // The Stela protocol contract address (only address that can pull assets)
        stela_contract: ContractAddress,
        // Whether the locker is unlocked (restrictions removed)
        unlocked: bool,
        // Allowlist: (target, selector) -> bool. Only these pairs can be called while locked.
        allowed_selectors: Map<(ContractAddress, felt252), bool>,
        // SRC5 introspection storage
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        // ERC1155 receiver storage
        #[substorage(v0)]
        erc1155_receiver: ERC1155ReceiverComponent::Storage,
    }

    // ============================================================
    //                          EVENTS
    // ============================================================

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        LockerUnlocked: LockerUnlocked,
        AssetsPulled: AssetsPulled,
        AllowedSelectorUpdated: AllowedSelectorUpdated,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ERC1155ReceiverEvent: ERC1155ReceiverComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LockerUnlocked {
        #[key]
        pub locker: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssetsPulled {
        #[key]
        pub locker: ContractAddress,
        pub asset_count: u32,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AllowedSelectorUpdated {
        #[key]
        pub locker: ContractAddress,
        pub target: ContractAddress,
        pub selector: felt252,
        pub allowed: bool,
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    #[constructor]
    fn constructor(ref self: ContractState, stela_contract: ContractAddress) {
        self.stela_contract.write(stela_contract);
        self.unlocked.write(false);

        // Register ERC1155 receiver interface (required for safe_transfer_from)
        self.erc1155_receiver.initializer();
        // Register ISRC6 (account interface) for ERC721 safe transfer fallback
        self.src5.register_interface(ISRC6_ID);
    }

    // ============================================================
    //                    ACCOUNT INTERFACE
    // ============================================================

    #[abi(per_item)]
    #[generate_trait]
    impl AccountImpl of AccountTrait {
        /// Validate a transaction.
        /// When locked: only allowlisted selectors can be called (e.g. vote, delegate).
        /// When unlocked: allow all calls (collateral returned to borrower after repayment).
        #[external(v0)]
        fn __validate__(self: @ContractState, calls: Span<Call>) -> felt252 {
            // If unlocked, allow all calls
            if self.unlocked.read() {
                return starknet::VALIDATED;
            }

            // When locked, only allow calls whose (target, selector) pairs are in the allowlist.
            // This lets the borrower vote/delegate on specific contracts while
            // preventing asset transfers out of the locker.
            let mut i: u32 = 0;
            while i < calls.len() {
                let call = *calls.at(i);
                assert(
                    self.allowed_selectors.read((call.to, call.selector)),
                    Errors::FORBIDDEN_SELECTOR,
                );
                i += 1;
            };
            starknet::VALIDATED
        }

        /// Execute calls.
        /// When locked, only allowlisted selectors pass (defense-in-depth check).
        #[external(v0)]
        fn __execute__(ref self: ContractState, calls: Span<Call>) -> Array<Span<felt252>> {
            // Defense in depth: re-check allowlist even if __validate__ passed
            if !self.unlocked.read() {
                let mut i: u32 = 0;
                while i < calls.len() {
                    let call = *calls.at(i);
                    assert(
                        self.allowed_selectors.read((call.to, call.selector)),
                        Errors::FORBIDDEN_SELECTOR,
                    );
                    i += 1;
                };
            }

            // Execute all calls
            _execute_calls(calls)
        }

        /// Validate a declare transaction.
        /// Reject declares when locked to prevent deploying arbitrary classes.
        #[external(v0)]
        fn __validate_declare__(self: @ContractState, class_hash: felt252) -> felt252 {
            if !self.unlocked.read() {
                assert(false, Errors::FORBIDDEN_SELECTOR);
            }
            starknet::VALIDATED
        }
    }

    // ============================================================
    //                    LOCKER INTERFACE
    // ============================================================

    #[abi(embed_v0)]
    impl LockerAccountImpl of crate::interfaces::ilocker::ILockerAccount<ContractState> {
        /// Pull assets from the locker to the Stela contract.
        /// Only callable by the Stela contract.
        fn pull_assets(ref self: ContractState, assets: Array<Asset>) {
            let caller = get_caller_address();
            let stela = self.stela_contract.read();
            assert(caller == stela, Errors::UNAUTHORIZED);

            let this_contract = get_contract_address();
            let mut i: u32 = 0;
            let len = assets.len();

            while i < len {
                let asset = *assets.at(i);
                _transfer_asset(asset, this_contract, stela);
                i += 1;
            }

            self.emit(AssetsPulled { locker: this_contract, asset_count: len });
        }

        /// Unlock the locker, removing execution restrictions.
        /// Only callable by the Stela contract.
        fn unlock(ref self: ContractState) {
            let caller = get_caller_address();
            let stela = self.stela_contract.read();
            assert(caller == stela, Errors::UNAUTHORIZED);

            self.unlocked.write(true);
            self.emit(LockerUnlocked { locker: get_contract_address() });
        }

        /// Add or remove a (target, selector) pair from the allowlist.
        /// Only callable by the Stela contract.
        fn set_allowed_selector(
            ref self: ContractState, target: ContractAddress, selector: felt252, allowed: bool,
        ) {
            let caller = get_caller_address();
            let stela = self.stela_contract.read();
            assert(caller == stela, Errors::UNAUTHORIZED);

            self.allowed_selectors.write((target, selector), allowed);
            self.emit(AllowedSelectorUpdated { locker: get_contract_address(), target, selector, allowed });
        }

        /// Check if the locker is currently unlocked.
        fn is_unlocked(self: @ContractState) -> bool {
            self.unlocked.read()
        }

        /// Check if a (target, selector) pair is in the allowlist.
        fn is_selector_allowed(
            self: @ContractState, target: ContractAddress, selector: felt252,
        ) -> bool {
            self.allowed_selectors.read((target, selector))
        }
    }

    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================

    /// Execute a list of calls.
    fn _execute_calls(mut calls: Span<Call>) -> Array<Span<felt252>> {
        let mut results: Array<Span<felt252>> = array![];

        while let Option::Some(call) = calls.pop_front() {
            let result = starknet::syscalls::call_contract_syscall(*call.to, *call.selector, *call.calldata).unwrap();
            results.append(result);
        }

        results
    }

    /// Transfer a single asset to a destination.
    fn _transfer_asset(asset: Asset, from: ContractAddress, to: ContractAddress) {
        match asset.asset_type {
            AssetType::ERC20 => {
                let erc20 = IERC20Dispatcher { contract_address: asset.asset };
                erc20.transfer(to, asset.value);
            },
            AssetType::ERC721 => {
                let erc721 = IERC721Dispatcher { contract_address: asset.asset };
                erc721.transfer_from(from, to, asset.token_id);
            },
            AssetType::ERC1155 => {
                let erc1155 = IERC1155Dispatcher { contract_address: asset.asset };
                erc1155.safe_transfer_from(from, to, asset.token_id, asset.value, array![].span());
            },
            AssetType::ERC4626 => {
                // ERC4626 is ERC20-compatible
                let erc20 = IERC20Dispatcher { contract_address: asset.asset };
                erc20.transfer(to, asset.value);
            },
        }
    }
}
