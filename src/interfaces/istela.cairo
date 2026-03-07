// IStelaProtocol — Main protocol interface

use starknet::ContractAddress;
use crate::types::asset::Asset;
use crate::types::inscription::{InscriptionParams, StoredInscription};
use crate::types::signed_order::SignedOrder;

#[starknet::interface]
pub trait IStelaProtocol<TContractState> {
    /// Create a new inscription (loan request or loan offer). Returns the inscription ID.
    fn create_inscription(ref self: TContractState, params: InscriptionParams) -> u256;

    /// Fill/sign an existing inscription by providing debt capital.
    fn sign_inscription(ref self: TContractState, inscription_id: u256, issued_debt_percentage: u256);

    /// Cancel an unfilled inscription. Only callable by the creator.
    fn cancel_inscription(ref self: TContractState, inscription_id: u256);

    /// Repay an active inscription. Only callable by the borrower.
    fn repay(ref self: TContractState, inscription_id: u256);

    /// Liquidate an expired, unrepaid inscription. Callable by anyone.
    fn liquidate(ref self: TContractState, inscription_id: u256);

    /// Redeem ERC-1155 shares for underlying assets after repayment or liquidation.
    fn redeem(ref self: TContractState, inscription_id: u256, shares: u256);

    /// Settle an off-chain signed order atomically.
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

    /// Batch-settle multiple off-chain signed orders atomically.
    fn batch_settle(
        ref self: TContractState,
        orders: Array<crate::snip12::InscriptionOrder>,
        debt_assets_flat: Array<Asset>,
        interest_assets_flat: Array<Asset>,
        collateral_assets_flat: Array<Asset>,
        borrower_sigs: Array<Array<felt252>>,
        batch_offer: crate::snip12::BatchLendOffer,
        lender_sig: Array<felt252>,
        bps_list: Array<u256>,
    );

    // --- Signed order matching engine ---

    fn fill_signed_order(
        ref self: TContractState, order: SignedOrder, signature: Array<felt252>, fill_bps: u256,
    );

    fn cancel_order(ref self: TContractState, order: SignedOrder);

    fn cancel_orders_by_nonce(ref self: TContractState, min_nonce: felt252);

    // --- View functions ---

    fn get_inscription(self: @TContractState, inscription_id: u256) -> StoredInscription;
    fn get_locker(self: @TContractState, inscription_id: u256) -> ContractAddress;
    fn convert_to_shares(self: @TContractState, inscription_id: u256, issued_debt_percentage: u256) -> u256;
    fn nonces(self: @TContractState, owner: ContractAddress) -> felt252;
    fn get_treasury(self: @TContractState) -> ContractAddress;
    fn is_paused(self: @TContractState) -> bool;
    fn is_order_registered(self: @TContractState, order_hash: felt252) -> bool;
    fn is_order_cancelled(self: @TContractState, order_hash: felt252) -> bool;
    fn get_filled_bps(self: @TContractState, order_hash: felt252) -> u256;
    fn get_maker_min_nonce(self: @TContractState, maker: ContractAddress) -> felt252;
    fn get_genesis_contract(self: @TContractState) -> ContractAddress;
    fn get_volume_settled(self: @TContractState, user: ContractAddress) -> u256;
    fn is_volume_token_whitelisted(self: @TContractState, token: ContractAddress) -> bool;

    // --- Admin functions ---

    fn set_treasury(ref self: TContractState, treasury: ContractAddress);
    fn set_registry(ref self: TContractState, registry: ContractAddress);
    fn set_inscriptions_nft(ref self: TContractState, inscriptions_nft: ContractAddress);
    fn set_implementation_hash(ref self: TContractState, implementation_hash: felt252);
    fn set_volume_token_whitelisted(ref self: TContractState, token: ContractAddress, whitelisted: bool);
    fn set_genesis_contract(ref self: TContractState, genesis_contract: ContractAddress);

    /// Pause the protocol. Only pauser.
    fn pause(ref self: TContractState);
    /// Unpause the protocol. Only pauser.
    fn unpause(ref self: TContractState);
    /// Get the emergency pauser address.
    fn get_pauser(self: @TContractState) -> ContractAddress;
    /// Set a new emergency pauser address. Only owner.
    fn set_pauser(ref self: TContractState, new_pauser: ContractAddress);

    /// Set an allowed (target, selector) pair on a locker. Only owner.
    fn set_locker_allowed_selector(
        ref self: TContractState,
        locker: ContractAddress,
        target: ContractAddress,
        selector: felt252,
        allowed: bool,
    );
}
