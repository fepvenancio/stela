// IStelaGenesis — ERC721 Genesis NFT mint interface

use starknet::ContractAddress;

#[starknet::interface]
pub trait IStelaGenesis<TContractState> {
    /// Mint one Genesis NFT. Caller must have approved `payment_token` for `mint_price`.
    /// Token IDs are sequential starting from 1.
    fn mint(ref self: TContractState);

    /// Batch mint multiple NFTs (max 5 per tx to limit gas).
    fn mint_batch(ref self: TContractState, quantity: u256);

    // --- Views ---
    fn total_minted(self: @TContractState) -> u256;
    fn max_supply(self: @TContractState) -> u256;
    fn mint_price(self: @TContractState) -> u256;
    fn mint_enabled(self: @TContractState) -> bool;
    fn payment_token(self: @TContractState) -> ContractAddress;
    fn mint_recipient(self: @TContractState) -> ContractAddress;

    // --- Admin (owner only) ---
    fn set_mint_price(ref self: TContractState, price: u256);
    fn set_mint_enabled(ref self: TContractState, enabled: bool);
    fn set_mint_recipient(ref self: TContractState, recipient: ContractAddress);
    fn set_base_uri(ref self: TContractState, base_uri: ByteArray);
    /// Owner can mint to specific address (for reserves/airdrops).
    fn admin_mint(ref self: TContractState, to: ContractAddress, quantity: u256);
}
