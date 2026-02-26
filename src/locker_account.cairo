// Locker Account — Token-Bound Account for Collateral
// SNIP-14 compliant account that restricts ALL outgoing calls while locked.
// Only the Stela contract can interact with a locked locker via pull_assets/unlock.

#[starknet::contract(account)]
pub mod LockerAccount {
    use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};

    // Token dispatchers
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use starknet::account::Call;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
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
    }

    // ============================================================
    //                          EVENTS
    // ============================================================

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        LockerUnlocked: LockerUnlocked,
        AssetsPulled: AssetsPulled,
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
        /// When locked: reject ALL outgoing calls (prevents any asset extraction).
        /// When unlocked: allow all calls (collateral returned to borrower after repayment).
        #[external(v0)]
        fn __validate__(self: @ContractState, calls: Span<Call>) -> felt252 {
            // If unlocked, allow all calls
            if self.unlocked.read() {
                return starknet::VALIDATED;
            }

            // When locked, reject ALL outgoing calls.
            // This is an allowlist approach: nothing is permitted while locked.
            // The Stela contract interacts via pull_assets/unlock (external calls INTO
            // the locker), which bypass __validate__ entirely.
            assert(false, Errors::FORBIDDEN_SELECTOR);
            starknet::VALIDATED
        }

        /// Execute calls.
        /// When locked, no calls should reach here (rejected by __validate__),
        /// but we double-check as a safety measure.
        #[external(v0)]
        fn __execute__(ref self: ContractState, calls: Span<Call>) -> Array<Span<felt252>> {
            // If locked, reject all calls (defense in depth)
            if !self.unlocked.read() {
                assert(false, Errors::FORBIDDEN_SELECTOR);
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

        /// Check if the locker is currently unlocked.
        fn is_unlocked(self: @ContractState) -> bool {
            self.unlocked.read()
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
