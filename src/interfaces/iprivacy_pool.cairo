// Minimal IPrivacyPool interface for cross-contract calls from Stela core.
// This mirrors the IPrivacyPool trait defined in the stela_privacy crate,
// but only includes methods that Stela core needs to call.

use crate::types::private_redeem::PrivateRedeemRequest;

#[starknet::interface]
pub trait IPrivacyPool<TContractState> {
    /// Insert a share commitment into the privacy pool's Merkle tree.
    /// Only callable by the authorized Stela core contract.
    fn insert_commitment(ref self: TContractState, commitment: felt252);

    /// Verify a ZK proof and spend the nullifier for private redemption.
    /// The privacy pool validates the proof, checks the nullifier hasn't been spent,
    /// and inserts any change commitment. Asset distribution is handled by Stela core.
    fn private_redeem(
        ref self: TContractState, request: PrivateRedeemRequest, proof: Span<felt252>,
    );

    /// Consume a deposit commitment for private settlement.
    /// Verifies the deposit exists and marks it as consumed (one-time use).
    /// Called by Stela core during settle() when the lender is anonymous.
    fn consume_deposit(ref self: TContractState, commitment: felt252);

    /// Pull deposited tokens from the privacy pool to a recipient.
    /// Called by Stela core during private settlement to transfer the lender's
    /// pre-deposited debt tokens to the borrower (and relayer fee to relayer).
    /// The pool must have sufficient token balance from the lender's prior deposit.
    fn pull_deposit_tokens(
        ref self: TContractState,
        token: starknet::ContractAddress,
        recipient: starknet::ContractAddress,
        amount: u256,
    );
}
