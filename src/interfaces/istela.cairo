// IStelaProtocol — Main protocol interface

use starknet::ContractAddress;
use crate::types::asset::Asset;
use crate::types::inscription::{InscriptionParams, StoredInscription};

#[starknet::interface]
pub trait IStelaProtocol<TContractState> {
    /// Create a new inscription. Returns the inscription ID.
    fn create_inscription(ref self: TContractState, params: InscriptionParams) -> u256;

    /// Fill/sign an existing inscription. `issued_debt_percentage` is in BPS (max 10,000).
    fn sign_inscription(ref self: TContractState, inscription_id: u256, issued_debt_percentage: u256);

    /// Cancel an unfilled inscription. Only callable by the creator.
    fn cancel_inscription(ref self: TContractState, inscription_id: u256);

    /// Repay an active inscription (principal + interest). Only callable by borrower.
    fn repay(ref self: TContractState, inscription_id: u256);

    /// Liquidate an expired, unrepaid inscription.
    fn liquidate(ref self: TContractState, inscription_id: u256);

    /// Redeem ERC-1155 shares for underlying assets after repayment or liquidation.
    fn redeem(ref self: TContractState, inscription_id: u256, shares: u256);

    /// Settle an off-chain order with borrower + lender signatures.
    fn settle(
        ref self: TContractState,
        order: crate::snip12::InscriptionOrder,
        debt_assets: Array<Asset>,
        interest_assets: Array<Asset>,
        collateral_assets: Array<Asset>,
        borrower_sig: Array<felt252>,
        offer: crate::snip12::LendOffer,
        lender_sig: Array<felt252>,
    );

    // --- View functions ---

    /// Get inscription details by ID.
    fn get_inscription(self: @TContractState, inscription_id: u256) -> StoredInscription;

    /// Get the locker (TBA) address for an inscription.
    fn get_locker(self: @TContractState, inscription_id: u256) -> ContractAddress;

    /// Convert a debt percentage to shares for a given inscription.
    fn convert_to_shares(self: @TContractState, inscription_id: u256, issued_debt_percentage: u256) -> u256;

    /// Get the protocol fee in BPS.
    fn get_inscription_fee(self: @TContractState) -> u256;

    /// Get the nonce for an address (for off-chain signing).
    fn nonces(self: @TContractState, owner: ContractAddress) -> felt252;

    /// Get the relayer fee in BPS.
    fn get_relayer_fee(self: @TContractState) -> u256;

    /// Get the treasury address.
    fn get_treasury(self: @TContractState) -> ContractAddress;

    /// Check if the protocol is paused.
    fn is_paused(self: @TContractState) -> bool;

    // --- Admin functions ---

    /// Set the protocol fee (in BPS). Only owner.
    fn set_inscription_fee(ref self: TContractState, fee: u256);

    /// Set the treasury address. Only owner.
    fn set_treasury(ref self: TContractState, treasury: ContractAddress);

    /// Set the SNIP-14 registry address. Only owner.
    fn set_registry(ref self: TContractState, registry: ContractAddress);

    /// Set the inscriptions NFT contract address. Only owner.
    fn set_inscriptions_nft(ref self: TContractState, inscriptions_nft: ContractAddress);

    /// Set the relayer fee (in BPS). Only owner.
    fn set_relayer_fee(ref self: TContractState, fee: u256);

    /// Set the locker implementation class hash. Only owner.
    fn set_implementation_hash(ref self: TContractState, implementation_hash: felt252);

    /// Pause the protocol. Only owner.
    fn pause(ref self: TContractState);

    /// Unpause the protocol. Only owner.
    fn unpause(ref self: TContractState);
}
