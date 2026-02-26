// Inscription types for Stela protocol.

use starknet::ContractAddress;

/// Parameters for creating a new inscription.
/// Passed by the caller — either a borrower or a lender.
#[derive(Drop, Serde)]
pub struct InscriptionParams {
    /// True if the creator is the borrower; false if the creator is the lender.
    pub is_borrow: bool,
    /// Assets the borrower wants to receive (the loan principal). Only ERC20/ERC4626 allowed.
    pub debt_assets: Array<super::asset::Asset>,
    /// Assets the borrower pays as interest on repayment. Only ERC20/ERC4626 allowed.
    pub interest_assets: Array<super::asset::Asset>,
    /// Assets locked as collateral in the TBA locker. All asset types allowed
    /// (ERC721 only for single-lender inscriptions).
    pub collateral_assets: Array<super::asset::Asset>,
    /// Loan duration in seconds. 0 = instant swap (no locker, immediate liquidation).
    pub duration: u64,
    /// Unix timestamp deadline for the inscription to be filled. Must be in the future.
    pub deadline: u64,
    /// If true, multiple lenders can partially fill the inscription.
    pub multi_lender: bool,
}

/// On-chain stored inscription state.
///
/// NOTE: Cairo storage doesn't natively support dynamic arrays in structs.
/// Assets are stored in separate indexed maps (inscription_debt_assets, etc.).
/// This struct stores the scalar fields only.
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq)]
pub struct StoredInscription {
    /// The borrower's address. Zero if the inscription was created by a lender and not yet filled.
    pub borrower: ContractAddress,
    /// The lender's address (last lender for multi-lender). Zero if created by borrower and not yet filled.
    pub lender: ContractAddress,
    /// Loan duration in seconds. 0 = instant swap.
    pub duration: u64,
    /// Unix timestamp deadline for the inscription to be filled.
    pub deadline: u64,
    /// Timestamp when the inscription was first signed/filled. 0 if unfilled.
    pub signed_at: u64,
    /// Cumulative debt percentage filled so far (in BPS, max 10,000).
    pub issued_debt_percentage: u256,
    /// True if the borrower has repaid the loan.
    pub is_repaid: bool,
    /// True if the loan has been liquidated (or is an instant swap).
    pub liquidated: bool,
    /// True if multiple lenders can partially fill this inscription.
    pub multi_lender: bool,
    /// Number of debt assets stored in the indexed debt asset map.
    pub debt_asset_count: u32,
    /// Number of interest assets stored in the indexed interest asset map.
    pub interest_asset_count: u32,
    /// Number of collateral assets stored in the indexed collateral asset map.
    pub collateral_asset_count: u32,
}
