// Signed order type for Stela protocol
// The SignedOrder struct is the shared interface contract between the Cairo contract,
// the off-chain Rust matching engine, and the TypeScript SDK.
// MUST NOT change after any signature is issued — any field addition or reordering
// invalidates all outstanding signed orders.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use openzeppelin_utils::snip12::StructHash;
use starknet::ContractAddress;

// PLACEHOLDER: replace with starknet.js typedData.getTypeHash output before testnet deployment
// encode_type:
// "SignedOrder(maker:ContractAddress,allowed_taker:ContractAddress,inscription_id:u256,bps:u256,deadline:u64,nonce:felt252,min_fill_bps:u256)"
pub const SIGNED_ORDER_TYPE_HASH: felt252 = 0x1;

/// Canonical signed order struct — MUST NOT change after any signature is issued.
/// Field order determines hash; any reordering invalidates all outstanding signatures.
#[derive(Drop, Copy, Serde)]
pub struct SignedOrder {
    pub maker: ContractAddress, // order creator
    pub allowed_taker: ContractAddress, // zero = open; nonzero = private/OTC
    pub inscription_id: u256, // inscription being offered
    pub bps: u256, // fill percentage being offered (in MAX_BPS units)
    pub deadline: u64, // unix timestamp; enforced on-chain
    pub nonce: felt252, // maker nonce; bump to invalidate batch
    pub min_fill_bps: u256 // minimum acceptable partial fill (0 = any)
}

pub impl StructHashSignedOrderImpl of StructHash<SignedOrder> {
    fn hash_struct(self: @SignedOrder) -> felt252 {
        let hash_state = PoseidonTrait::new();
        hash_state
            .update_with(SIGNED_ORDER_TYPE_HASH)
            .update_with(*self.maker)
            .update_with(*self.allowed_taker)
            .update_with(*self.inscription_id)
            .update_with(*self.bps)
            .update_with(Into::<u64, felt252>::into(*self.deadline))
            .update_with(*self.nonce)
            .update_with(*self.min_fill_bps)
            .finalize()
    }
}
