// Mock Privacy Pool for testing private settlement
// Tracks deposits, commitments, and token transfers for verification in tests.

use crate::types::private_redeem::PrivateRedeemRequest;

#[starknet::interface]
pub trait IMockPrivacyPool<TContractState> {
    // IPrivacyPool methods
    fn insert_commitment(ref self: TContractState, commitment: felt252);
    fn private_redeem(ref self: TContractState, request: PrivateRedeemRequest, proof: Span<felt252>);
    fn consume_deposit(ref self: TContractState, commitment: felt252);
    fn pull_deposit_tokens(
        ref self: TContractState,
        token: starknet::ContractAddress,
        recipient: starknet::ContractAddress,
        amount: u256,
    );

    // Test helpers
    fn add_deposit(ref self: TContractState, commitment: felt252);
    fn is_deposit_consumed(self: @TContractState, commitment: felt252) -> bool;
    fn get_commitment_count(self: @TContractState) -> u32;
    fn fund_pool(ref self: TContractState, token: starknet::ContractAddress, amount: u256);
}

#[starknet::contract]
pub mod MockPrivacyPool {
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::ContractAddress;
    use crate::types::private_redeem::PrivateRedeemRequest;

    #[storage]
    struct Storage {
        // Tracks which deposits exist (commitment -> true)
        deposits: Map<felt252, bool>,
        // Tracks which deposits have been consumed
        consumed: Map<felt252, bool>,
        // Tracks inserted commitments (index -> commitment)
        commitments: Map<u32, felt252>,
        commitment_count: u32,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[abi(embed_v0)]
    impl MockPrivacyPoolImpl of super::IMockPrivacyPool<ContractState> {
        fn insert_commitment(ref self: ContractState, commitment: felt252) {
            let idx = self.commitment_count.read();
            self.commitments.write(idx, commitment);
            self.commitment_count.write(idx + 1);
        }

        fn private_redeem(ref self: ContractState, request: PrivateRedeemRequest, proof: Span<felt252>) {
            // Mock: always succeeds — suppress unused warnings
            let _ = request;
            let _ = proof;
        }

        fn consume_deposit(ref self: ContractState, commitment: felt252) {
            // Verify deposit exists
            assert(self.deposits.read(commitment), 'POOL: deposit not found');
            // Verify not already consumed
            assert(!self.consumed.read(commitment), 'POOL: already consumed');
            // Mark as consumed
            self.consumed.write(commitment, true);
        }

        fn pull_deposit_tokens(
            ref self: ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) {
            // Transfer tokens from pool to recipient
            let erc20 = IERC20Dispatcher { contract_address: token };
            erc20.transfer(recipient, amount);
        }

        // --- Test helpers ---

        fn add_deposit(ref self: ContractState, commitment: felt252) {
            self.deposits.write(commitment, true);
        }

        fn is_deposit_consumed(self: @ContractState, commitment: felt252) -> bool {
            self.consumed.read(commitment)
        }

        fn get_commitment_count(self: @ContractState) -> u32 {
            self.commitment_count.read()
        }

        fn fund_pool(ref self: ContractState, token: ContractAddress, amount: u256) {
            // Tokens should be transferred to this contract externally (via mint + approve)
            // This is a no-op helper — pool gets funded via direct token minting in tests
            let _ = token;
            let _ = amount;
        }
    }
}
