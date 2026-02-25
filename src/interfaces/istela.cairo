// IStelaProtocol — Main protocol interface

use starknet::ContractAddress;
use crate::types::inscription::{InscriptionParams, StoredInscription};
use crate::types::signed_order::SignedOrder;

#[starknet::interface]
pub trait IStelaProtocol<TContractState> {
    /// Create a new inscription. Returns the inscription ID.
    fn create_inscription(ref self: TContractState, params: InscriptionParams) -> u256;

    /// Fill/sign an existing inscription. `issued_debt_percentage` is in BPS (max 10,000).
    fn sign_inscription(ref self: TContractState, inscription_id: u256, issued_debt_percentage: u256);

    /// Cancel an unfilled inscription. Only callable by the creator.
    fn cancel_inscription(ref self: TContractState, inscription_id: u256);

    /// Repay an active inscription (principal + interest).
    fn repay(ref self: TContractState, inscription_id: u256);

    /// Liquidate an expired, unrepaid inscription.
    fn liquidate(ref self: TContractState, inscription_id: u256);

    /// Redeem ERC-1155 shares for underlying assets after repayment or liquidation.
    fn redeem(ref self: TContractState, inscription_id: u256, shares: u256);

    // --- Signed order entry points ---

    /// Fill a signed order. On first fill, verifies the maker's SNIP-12 signature and
    /// registers the order on-chain. Subsequent fills skip signature verification.
    /// `fill_bps` is the fill percentage requested in BPS (max 10,000).
    fn fill_signed_order(ref self: TContractState, order: SignedOrder, signature: Array<felt252>, fill_bps: u256);

    /// Cancel a specific signed order by its hash. Only callable by the maker.
    fn cancel_order(ref self: TContractState, order: SignedOrder);

    /// Cancel all orders with nonce strictly less than `min_nonce`. Callable by any maker
    /// to invalidate all outstanding orders with an old nonce in a single transaction.
    fn cancel_orders_by_nonce(ref self: TContractState, min_nonce: felt252);

    // --- View functions ---

    /// Get inscription details by ID.
    fn get_inscription(self: @TContractState, inscription_id: u256) -> StoredInscription;

    /// Get the locker (TBA) address for an inscription.
    fn get_locker(self: @TContractState, inscription_id: u256) -> ContractAddress;

    /// Convert a debt percentage to shares for a given inscription.
    fn convert_to_shares(self: @TContractState, inscription_id: u256, issued_debt_percentage: u256) -> u256;

    /// Get the protocol fee in BPS.
    fn get_inscription_fee(self: @TContractState) -> u256;

    /// Returns true if the order has been registered on-chain (first fill completed).
    fn is_order_registered(self: @TContractState, order_hash: felt252) -> bool;

    /// Returns true if the order has been cancelled.
    fn is_order_cancelled(self: @TContractState, order_hash: felt252) -> bool;

    /// Returns the current filled BPS for a signed order.
    fn get_filled_bps(self: @TContractState, order_hash: felt252) -> u256;

    /// Returns the minimum valid nonce for a maker (orders with nonce < this are invalid).
    fn get_maker_min_nonce(self: @TContractState, maker: ContractAddress) -> felt252;

    // --- Admin functions ---

    /// Set the protocol fee (in BPS). Only owner.
    fn set_inscription_fee(ref self: TContractState, fee: u256);

    /// Set the treasury address. Only owner.
    fn set_treasury(ref self: TContractState, treasury: ContractAddress);

    /// Set the SNIP-14 registry address. Only owner.
    /// Needed for deploy_full_setup (chicken-and-egg: Stela needs registry, registry needs Stela).
    fn set_registry(ref self: TContractState, registry: ContractAddress);

    /// Set the inscriptions NFT contract address. Only owner.
    fn set_inscriptions_nft(ref self: TContractState, inscriptions_nft: ContractAddress);
}
