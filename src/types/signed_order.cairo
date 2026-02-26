// Signed order type for Stela protocol matching engine.
// The SignedOrder struct is the shared interface contract between the Cairo contract,
// the off-chain Rust matching engine, and the TypeScript SDK.
// MUST NOT change after any signature is issued -- any field addition or reordering
// invalidates all outstanding signed orders.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use openzeppelin_utils::cryptography::snip12::StructHash;
use starknet::ContractAddress;

// Compute the real type hash using selector!() macro with the proper SNIP-12 encode_type string.
// u256 fields are encoded as nested struct types per SNIP-12 specification.
pub const SIGNED_ORDER_TYPE_HASH: felt252 = selector!(
    "\"SignedOrder\"(\"maker\":\"ContractAddress\",\"allowed_taker\":\"ContractAddress\",\"inscription_id\":\"u256\",\"bps\":\"u256\",\"deadline\":\"u128\",\"nonce\":\"felt\",\"min_fill_bps\":\"u256\")\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
);

const U256_TYPE_HASH: felt252 = selector!(
    "\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
);

/// Canonical signed order struct -- MUST NOT change after any signature is issued.
/// Field order determines hash; any reordering invalidates all outstanding signatures.
#[derive(Drop, Copy, Serde)]
pub struct SignedOrder {
    /// Order creator (could be borrower or lender).
    pub maker: ContractAddress,
    /// Zero = open to anyone; nonzero = private OTC (only this address can fill).
    pub allowed_taker: ContractAddress,
    /// The inscription being offered for filling.
    pub inscription_id: u256,
    /// Fill percentage being offered (in MAX_BPS units, max 10,000).
    pub bps: u256,
    /// Unix timestamp deadline for order expiration; enforced on-chain.
    pub deadline: u64,
    /// Maker nonce; bump via cancel_orders_by_nonce to invalidate batch.
    pub nonce: felt252,
    /// Minimum acceptable partial fill (0 = any amount accepted).
    pub min_fill_bps: u256,
}

/// Helper to hash a u256 as a nested struct per SNIP-12 spec.
fn hash_u256(value: u256) -> felt252 {
    PoseidonTrait::new()
        .update_with(U256_TYPE_HASH)
        .update_with(value.low)
        .update_with(value.high)
        .finalize()
}

pub impl StructHashSignedOrderImpl of StructHash<SignedOrder> {
    fn hash_struct(self: @SignedOrder) -> felt252 {
        let hash_state = PoseidonTrait::new();
        hash_state
            .update_with(SIGNED_ORDER_TYPE_HASH)
            .update_with(*self.maker)
            .update_with(*self.allowed_taker)
            .update_with(hash_u256(*self.inscription_id))
            .update_with(hash_u256(*self.bps))
            .update_with(Into::<u64, felt252>::into(*self.deadline))
            .update_with(*self.nonce)
            .update_with(hash_u256(*self.min_fill_bps))
            .finalize()
    }
}
