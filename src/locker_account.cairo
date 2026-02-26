// Locker Account — Token-Bound Account for Collateral
// SNIP-14 compliant account with an allowlist-based lockdown.
// When locked, only explicitly allowed selectors (e.g. vote, delegate) can be called.
// All other outgoing calls are blocked. The Stela contract manages the allowlist
// and interacts via pull_assets/unlock (external calls INTO the locker).

#[starknet::contract(account)]
pub mod LockerAccount {
    use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};

    // Token dispatchers
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use starknet::account::Call;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    // Local imports
    use crate::errors::Errors;
    use crate::types::asset::{Asset, AssetType};

    // ============================================================
    //                          STORAGE
    // ============================================================

    #[storage]
    struct Storage {
        // The Stela protocol contract address (only address that can pull assets)
        stela_contract: ContractAddress,
        // Whether the locker is unlocked (restrictions removed)
        unlocked: bool,
        // Allowlist: selector -> bool. Only these selectors can be called while locked.
        allowed_selectors: Map<felt252, bool>,
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

            // When locked, only allow calls whose selectors are in the allowlist.
            // This lets the borrower vote, delegate, or showcase NFTs while
            // preventing any asset transfers out of the locker.
            let mut i: u32 = 0;
            while i < calls.len() {
                let call = *calls.at(i);
                assert(self.allowed_selectors.read(call.selector), Errors::FORBIDDEN_SELECTOR);
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
                    assert(self.allowed_selectors.read(call.selector), Errors::FORBIDDEN_SELECTOR);
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

        /// Add or remove a selector from the allowlist.
        /// Only callable by the Stela contract.
        fn set_allowed_selector(ref self: ContractState, selector: felt252, allowed: bool) {
            let caller = get_caller_address();
            let stela = self.stela_contract.read();
            assert(caller == stela, Errors::UNAUTHORIZED);

            self.allowed_selectors.write(selector, allowed);
            self.emit(AllowedSelectorUpdated { locker: get_contract_address(), selector, allowed });
        }

        /// Check if the locker is currently unlocked.
        fn is_unlocked(self: @ContractState) -> bool {
            self.unlocked.read()
        }

        /// Check if a selector is in the allowlist.
        fn is_selector_allowed(self: @ContractState, selector: felt252) -> bool {
            self.allowed_selectors.read(selector)
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
