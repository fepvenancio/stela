// SNIP-12 typed data structures for off-chain signature settlement.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use openzeppelin_utils::cryptography::snip12::StructHash;
use starknet::ContractAddress;
use crate::types::asset::{Asset, AssetType};

/// Off-chain inscription order signed by the borrower.
#[derive(Copy, Drop, Hash, Serde)]
pub struct InscriptionOrder {
    pub borrower: ContractAddress,
    pub debt_hash: felt252,
    pub interest_hash: felt252,
    pub collateral_hash: felt252,
    pub debt_count: u32,
    pub interest_count: u32,
    pub collateral_count: u32,
    pub duration: u64,
    pub deadline: u64,
    pub multi_lender: bool,
    pub nonce: felt252,
}

const INSCRIPTION_ORDER_TYPE_HASH: felt252 = selector!(
    "\"InscriptionOrder\"(\"borrower\":\"ContractAddress\",\"debt_hash\":\"felt\",\"interest_hash\":\"felt\",\"collateral_hash\":\"felt\",\"debt_count\":\"u128\",\"interest_count\":\"u128\",\"collateral_count\":\"u128\",\"duration\":\"u128\",\"deadline\":\"u128\",\"multi_lender\":\"bool\",\"nonce\":\"felt\")",
);

impl InscriptionOrderStructHash of StructHash<InscriptionOrder> {
    fn hash_struct(self: @InscriptionOrder) -> felt252 {
        let hash_state = PoseidonTrait::new();
        hash_state
            .update_with(INSCRIPTION_ORDER_TYPE_HASH)
            .update_with(*self)
            .finalize()
    }
}

/// Off-chain lend offer signed by the lender.
#[derive(Copy, Drop, Hash, Serde)]
pub struct LendOffer {
    pub order_hash: felt252,
    pub lender: ContractAddress,
    pub issued_debt_percentage: u256,
    pub nonce: felt252,
}

// SNIP-12 type hash includes dependent type definitions (u256 sub-type).
const LEND_OFFER_TYPE_HASH: felt252 = selector!(
    "\"LendOffer\"(\"order_hash\":\"felt\",\"lender\":\"ContractAddress\",\"issued_debt_percentage\":\"u256\",\"nonce\":\"felt\")\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
);

const U256_TYPE_HASH: felt252 = selector!(
    "\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
);

impl LendOfferStructHash of StructHash<LendOffer> {
    fn hash_struct(self: @LendOffer) -> felt252 {
        // u256 must be encoded as a nested struct hash per SNIP-12:
        //   u256_hash = Poseidon(U256_TYPE_HASH, low, high)
        let u256_hash = PoseidonTrait::new()
            .update_with(U256_TYPE_HASH)
            .update_with((*self.issued_debt_percentage).low)
            .update_with((*self.issued_debt_percentage).high)
            .finalize();

        PoseidonTrait::new()
            .update_with(LEND_OFFER_TYPE_HASH)
            .update_with(*self.order_hash)
            .update_with(*self.lender)
            .update_with(u256_hash)
            .update_with(*self.nonce)
            .finalize()
    }
}

/// Convert AssetType enum to felt252 for hashing.
fn asset_type_to_felt(asset_type: AssetType) -> felt252 {
    match asset_type {
        AssetType::ERC20 => 0,
        AssetType::ERC721 => 1,
        AssetType::ERC1155 => 2,
        AssetType::ERC4626 => 3,
    }
}

/// Hash an array of Assets into a single felt252 using Poseidon.
pub fn hash_assets(assets: Span<Asset>) -> felt252 {
    let mut hash_state = PoseidonTrait::new();
    hash_state = hash_state.update_with(assets.len());
    let mut i: u32 = 0;
    while i < assets.len() {
        let asset = *assets.at(i);
        hash_state = hash_state
            .update_with(asset.asset)
            .update_with(asset_type_to_felt(asset.asset_type))
            .update_with(asset.value)
            .update_with(asset.token_id);
        i += 1;
    };
    hash_state.finalize()
}
