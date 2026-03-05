// IFeeVault — Interface for the Genesis fee distribution vault.
// Multi-token fee accumulator with per-NFT claim tracking.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IFeeVault<TContractState> {
    /// Deposit fees into the vault for distribution to NFT holders.
    /// Only callable by the authorized Stela contract (set via `set_stela_contract`).
    /// The caller must have approved `token` for `amount` before calling.
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);

    /// Claim accumulated fees for a specific NFT across all registered tokens.
    /// Caller must be the current owner of the NFT (checked via genesis_nft.owner_of).
    fn claim(ref self: TContractState, token_id: u256);

    /// Claim accumulated fees for a specific NFT for a specific token only.
    fn claim_token(ref self: TContractState, token_id: u256, token: ContractAddress);

    /// Claim fees for multiple NFTs at once (for holders with multiple NFTs).
    fn claim_batch(ref self: TContractState, token_ids: Array<u256>);

    // --- Views ---

    /// Get the claimable amount for a specific NFT and token.
    fn claimable(self: @TContractState, token_id: u256, token: ContractAddress) -> u256;

    /// Get claimable amounts for a specific NFT across all registered tokens.
    /// Returns parallel arrays of (token_addresses, amounts).
    fn claimable_all(self: @TContractState, token_id: u256) -> (Array<ContractAddress>, Array<u256>);

    /// Get the total cumulative fees deposited per NFT for a token.
    fn cumulative_per_nft(self: @TContractState, token: ContractAddress) -> u256;

    /// Get all registered fee tokens.
    fn get_fee_tokens(self: @TContractState) -> Array<ContractAddress>;

    /// Get the Genesis NFT contract address.
    fn get_genesis_nft(self: @TContractState) -> ContractAddress;

    // --- Admin ---

    /// Register a new fee token. Only owner.
    /// Tokens must be pre-registered before they can be deposited.
    fn register_token(ref self: TContractState, token: ContractAddress);

    /// Update the Genesis NFT contract address. Only owner.
    fn set_genesis_nft(ref self: TContractState, genesis_nft: ContractAddress);

    /// Set the authorized Stela contract for deposits. Only owner.
    fn set_stela_contract(ref self: TContractState, stela_contract: ContractAddress);

    /// Get the authorized Stela contract address.
    fn get_stela_contract(self: @TContractState) -> ContractAddress;

    /// Snapshot current cumulative values for a newly minted NFT.
    /// Sets claimed_per_nft to current cumulative for all registered tokens,
    /// so the new holder only earns fees deposited after their mint.
    /// Callable only by the Genesis NFT contract.
    fn snapshot_new_nft(ref self: TContractState, token_id: u256);
}
