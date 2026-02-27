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
}
