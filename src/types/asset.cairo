// Asset types for Stela protocol.

use starknet::ContractAddress;

/// Represents the type of token standard an asset conforms to.
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Default)]
pub enum AssetType {
    #[default]
    ERC20,
    ERC721,
    ERC1155,
    ERC4626,
}

/// Represents a single asset in an inscription.
/// For ERC20/ERC4626: `value` is the token amount, `token_id` is unused (0).
/// For ERC721: `token_id` is the NFT ID, `value` is unused (0).
/// For ERC1155: both `token_id` and `value` are used.
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq)]
pub struct Asset {
    pub asset: ContractAddress,
    pub asset_type: AssetType,
    pub value: u256,
    pub token_id: u256,
}
