// Private redemption request — must match stela_privacy::types::note::RedeemRequest
// field-for-field so that cross-contract Serde encoding is compatible.

use starknet::ContractAddress;

#[derive(Copy, Drop, Serde)]
pub struct PrivateRedeemRequest {
    /// Merkle root the proof was generated against.
    pub root: felt252,
    /// The inscription ID whose shares are being redeemed.
    pub inscription_id: u256,
    /// Number of shares being redeemed.
    pub shares: u256,
    /// Nullifier (prevents double-spend).
    pub nullifier: felt252,
    /// Change commitment (for partial redemption). 0 if full redemption.
    pub change_commitment: felt252,
    /// Recipient address for the redeemed assets.
    pub recipient: ContractAddress,
}
