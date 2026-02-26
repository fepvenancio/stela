// IStelaProtocol — Main protocol interface

use starknet::ContractAddress;
use crate::types::asset::Asset;
use crate::types::inscription::{InscriptionParams, StoredInscription};

#[starknet::interface]
pub trait IStelaProtocol<TContractState> {
    /// Create a new inscription (loan request or loan offer). Returns the inscription ID.
    /// If `params.is_borrow` is true, caller is the borrower seeking a lender.
    /// If false, caller is the lender seeking a borrower.
    /// No assets are transferred at creation time. Callable by anyone.
    fn create_inscription(ref self: TContractState, params: InscriptionParams) -> u256;

    /// Fill/sign an existing inscription by providing debt capital.
    /// For single-lender inscriptions, `issued_debt_percentage` is ignored (always 100%).
    /// For multi-lender inscriptions, `issued_debt_percentage` is the portion to fill (in BPS, max 10,000).
    /// Callable by anyone except the inscription creator. Reverts if expired or already fully filled.
    /// Side effects: transfers debt from lender to borrower, locks collateral in TBA locker,
    /// mints ERC1155 shares to lender, mints fee shares to treasury.
    fn sign_inscription(ref self: TContractState, inscription_id: u256, issued_debt_percentage: u256);

    /// Cancel an unfilled inscription. Only callable by the creator.
    fn cancel_inscription(ref self: TContractState, inscription_id: u256);

    /// Repay an active inscription (principal + interest proportional to issued_debt_percentage).
    /// Only callable by the borrower, and only within the repayment window
    /// (between signed_at and signed_at + duration).
    /// Side effects: transfers debt + interest from borrower to contract, unlocks collateral locker.
    fn repay(ref self: TContractState, inscription_id: u256);

    /// Liquidate an expired, unrepaid inscription. Callable by anyone after
    /// signed_at + duration has passed without repayment.
    /// Side effects: pulls collateral from locker to contract, marks inscription as liquidated.
    /// Lenders can then redeem their shares for the seized collateral.
    fn liquidate(ref self: TContractState, inscription_id: u256);

    /// Redeem ERC-1155 shares for underlying assets after repayment or liquidation.
    /// If repaid: redeemer receives pro-rata debt + interest assets.
    /// If liquidated: redeemer receives pro-rata collateral assets.
    /// Burns the redeemed shares. Callable by any share holder.
    fn redeem(ref self: TContractState, inscription_id: u256, shares: u256);

    /// Settle an off-chain signed order, creating and filling an inscription in one transaction.
    /// A relayer (any caller) submits pre-signed borrower order and lender offer.
    /// The relayer receives a fee (relayer_fee BPS) deducted from the lender's debt transfer.
    ///
    /// # Arguments
    /// * `order` - The borrower's signed inscription order (SNIP-12 typed data)
    /// * `debt_assets` - Debt asset array (must match order hashes and counts)
    /// * `interest_assets` - Interest asset array (must match order hashes and counts)
    /// * `collateral_assets` - Collateral asset array (must match order hashes and counts)
    /// * `borrower_sig` - Borrower's SNIP-12 signature over the order
    /// * `offer` - The lender's signed offer referencing the order hash
    /// * `lender_sig` - Lender's SNIP-12 signature over the offer
    ///
    /// Consumes nonces for both borrower and lender. Callable by anyone (relayer pattern).
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

    /// Preview the number of ERC1155 shares that would be minted for a given debt percentage.
    /// Useful for UI display before calling sign_inscription.
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

    /// Set an allowed selector on a locker (for voting, delegation, etc while locked).
    /// Only owner.
    fn set_locker_allowed_selector(
        ref self: TContractState, locker: ContractAddress, selector: felt252, allowed: bool,
    );
}
