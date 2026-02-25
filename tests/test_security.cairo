// Security tests for Stela protocol.
// Validates critical invariants, access control, and edge cases.

use core::num::traits::Zero;
use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global, start_cheat_caller_address,
    stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use stela::interfaces::istela::IStelaProtocolDispatcherTrait;
use stela::types::asset::{Asset, AssetType};
use stela::types::inscription::InscriptionParams;
use stela::utils::share_math::MAX_BPS;
use super::mocks::mock_erc20::IMockERC20DispatcherTrait;
use super::test_utils::{
    BORROWER, LENDER, LENDER_2, MOCK_NFT, MOCK_TOKEN, NFT_CONTRACT, OWNER, REGISTRY, TREASURY, create_erc20_asset,
    deploy_full_setup, deploy_stela, setup_borrower_for_repayment, setup_borrower_with_collateral,
    setup_lender_with_debt,
};

/// Helper: get ERC1155 share balance.
fn get_shares(stela_address: starknet::ContractAddress, account: starknet::ContractAddress, token_id: u256) -> u256 {
    let erc1155 = IERC1155Dispatcher { contract_address: stela_address };
    erc1155.balance_of(account, token_id)
}

// ============================================================
//       C1: SINGLE-LENDER DOUBLE-SIGN PREVENTION
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: already signed')]
fn test_single_lender_double_sign_fails() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token_address = setup.interest_token_address;

    // Setup borrower collateral
    collateral_token.mint(BORROWER(), 500);
    start_cheat_caller_address(collateral_token_address, BORROWER());
    collateral_token.approve(stela_address, 500);
    stop_cheat_caller_address(collateral_token_address);

    // Setup two lenders with debt
    debt_token.mint(LENDER(), 1000);
    start_cheat_caller_address(debt_token_address, LENDER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);

    debt_token.mint(LENDER_2(), 1000);
    start_cheat_caller_address(debt_token_address, LENDER_2());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);

    start_cheat_block_timestamp_global(1000);

    // Create single-lender inscription
    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token_address, 1000)],
        interest_assets: array![create_erc20_asset(interest_token_address, 100)],
        collateral_assets: array![create_erc20_asset(collateral_token_address, 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // First sign — succeeds
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    // Second sign — must panic
    start_cheat_caller_address(stela_address, LENDER_2());
    stela.sign_inscription(inscription_id, MAX_BPS);
}

// ============================================================
//       MULTI-LENDER: EXCEEDS MAX BPS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: exceeds max bps')]
fn test_multi_lender_exceeds_max_bps_fails() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token_address = setup.interest_token_address;

    // Setup borrower
    collateral_token.mint(BORROWER(), 5000);
    start_cheat_caller_address(collateral_token_address, BORROWER());
    collateral_token.approve(stela_address, 5000);
    stop_cheat_caller_address(collateral_token_address);

    // Setup two lenders
    debt_token.mint(LENDER(), 10000);
    start_cheat_caller_address(debt_token_address, LENDER());
    debt_token.approve(stela_address, 10000);
    stop_cheat_caller_address(debt_token_address);

    debt_token.mint(LENDER_2(), 10000);
    start_cheat_caller_address(debt_token_address, LENDER_2());
    debt_token.approve(stela_address, 10000);
    stop_cheat_caller_address(debt_token_address);

    start_cheat_block_timestamp_global(1000);

    // Create multi-lender inscription
    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token_address, 10000)],
        interest_assets: array![create_erc20_asset(interest_token_address, 1000)],
        collateral_assets: array![create_erc20_asset(collateral_token_address, 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: true,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // Lender 1 fills 60%
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, 6000);
    stop_cheat_caller_address(stela_address);

    // Lender 2 tries 50% — total would be 110%, must panic
    start_cheat_caller_address(stela_address, LENDER_2());
    stela.sign_inscription(inscription_id, 5000);
}

// ============================================================
//       FEE VALIDATION
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: fee too high')]
fn test_fee_exceeds_max_bps_fails() {
    let (stela_address, stela) = deploy_stela();

    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(MAX_BPS + 1); // 10001 BPS — must panic
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_fee_at_max_bps_succeeds() {
    let (stela_address, stela) = deploy_stela();

    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(MAX_BPS); // 10000 BPS — edge case, should succeed
    stop_cheat_caller_address(stela_address);

    assert(stela.get_inscription_fee() == MAX_BPS, 'fee set to max');
}

// ============================================================
//       ZERO-ADDRESS VALIDATION IN ADMIN SETTERS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid address')]
fn test_set_treasury_zero_fails() {
    let (stela_address, stela) = deploy_stela();
    let zero: starknet::ContractAddress = Zero::zero();

    start_cheat_caller_address(stela_address, OWNER());
    stela.set_treasury(zero);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid address')]
fn test_set_registry_zero_fails() {
    let (stela_address, stela) = deploy_stela();
    let zero: starknet::ContractAddress = Zero::zero();

    start_cheat_caller_address(stela_address, OWNER());
    stela.set_registry(zero);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid address')]
fn test_set_inscriptions_nft_zero_fails() {
    let (stela_address, stela) = deploy_stela();
    let zero: starknet::ContractAddress = Zero::zero();

    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscriptions_nft(zero);
}

// ============================================================
//       ASSET VALIDATION
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: zero asset value')]
fn test_zero_value_debt_asset_fails() {
    let (stela_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(stela_address, BORROWER());

    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(LENDER(), 0)], // Zero value
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(LENDER(), 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid address')]
fn test_zero_address_debt_asset_fails() {
    let (stela_address, stela) = deploy_stela();
    let zero: starknet::ContractAddress = Zero::zero();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(stela_address, BORROWER());

    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(zero, 1000)], // Zero address
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(LENDER(), 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: zero asset value')]
fn test_zero_value_collateral_asset_fails() {
    let (stela_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(stela_address, BORROWER());

    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(LENDER(), 1000)],
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(LENDER(), 0)], // Zero value
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

// ============================================================
//       CANCEL SIGNED INSCRIPTION FAILS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: not cancellable')]
fn test_cancel_signed_inscription_fails() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token_address = setup.interest_token_address;

    // Setup
    collateral_token.mint(BORROWER(), 500);
    start_cheat_caller_address(collateral_token_address, BORROWER());
    collateral_token.approve(stela_address, 500);
    stop_cheat_caller_address(collateral_token_address);

    debt_token.mint(LENDER(), 1000);
    start_cheat_caller_address(debt_token_address, LENDER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);

    start_cheat_block_timestamp_global(1000);

    // Create
    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token_address, 1000)],
        interest_assets: array![create_erc20_asset(interest_token_address, 100)],
        collateral_assets: array![create_erc20_asset(collateral_token_address, 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // Sign
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    // Try to cancel signed inscription — must panic
    start_cheat_caller_address(stela_address, BORROWER());
    stela.cancel_inscription(inscription_id);
}

// ============================================================
//       DOUBLE LIQUIDATION FAILS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: already liquidated')]
fn test_double_liquidation_fails() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token_address = setup.interest_token_address;

    // Setup
    collateral_token.mint(BORROWER(), 500);
    start_cheat_caller_address(collateral_token_address, BORROWER());
    collateral_token.approve(stela_address, 500);
    stop_cheat_caller_address(collateral_token_address);

    debt_token.mint(LENDER(), 1000);
    start_cheat_caller_address(debt_token_address, LENDER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token_address, 1000)],
        interest_assets: array![create_erc20_asset(interest_token_address, 100)],
        collateral_assets: array![create_erc20_asset(collateral_token_address, 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    // Advance past duration
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(1000 + 86400 + 1);

    // First liquidation — succeeds
    start_cheat_caller_address(stela_address, LENDER());
    stela.liquidate(inscription_id);
    stop_cheat_caller_address(stela_address);

    // Second liquidation — must panic
    start_cheat_caller_address(stela_address, LENDER());
    stela.liquidate(inscription_id);
}

// ============================================================
//       DOUBLE REPAYMENT FAILS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: already repaid')]
fn test_double_repayment_fails() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token = setup.interest_token;
    let interest_token_address = setup.interest_token_address;

    // Setup
    collateral_token.mint(BORROWER(), 500);
    start_cheat_caller_address(collateral_token_address, BORROWER());
    collateral_token.approve(stela_address, 500);
    stop_cheat_caller_address(collateral_token_address);

    debt_token.mint(LENDER(), 1000);
    start_cheat_caller_address(debt_token_address, LENDER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token_address, 1000)],
        interest_assets: array![create_erc20_asset(interest_token_address, 100)],
        collateral_assets: array![create_erc20_asset(collateral_token_address, 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    // Advance to repay window
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50000);

    // First repayment — setup tokens and repay
    debt_token.mint(BORROWER(), 1000);
    interest_token.mint(BORROWER(), 100);
    start_cheat_caller_address(debt_token_address, BORROWER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);
    start_cheat_caller_address(interest_token_address, BORROWER());
    interest_token.approve(stela_address, 100);
    stop_cheat_caller_address(interest_token_address);

    start_cheat_caller_address(stela_address, BORROWER());
    stela.repay(inscription_id);
    stop_cheat_caller_address(stela_address);

    // Second repayment — must panic
    start_cheat_caller_address(stela_address, BORROWER());
    stela.repay(inscription_id);
}

// ============================================================
//       LENDER-CREATION (is_borrow=false) FULL LIFECYCLE
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_lender_creation_full_lifecycle() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;
    let interest_amount: u256 = 100;

    // Set fee to 0 for exact amount verification
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(0);
    stop_cheat_caller_address(stela_address);

    // Lender needs debt tokens (they provide them on sign)
    setup_lender_with_debt(@setup, LENDER(), debt_amount);
    // Borrower needs collateral tokens
    setup_borrower_with_collateral(@setup, BORROWER(), collateral_amount);

    start_cheat_block_timestamp_global(1000);

    // === 1. Lender creates inscription (is_borrow=false) ===
    start_cheat_caller_address(stela_address, LENDER());
    let params = InscriptionParams {
        is_borrow: false,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, debt_amount)],
        interest_assets: array![create_erc20_asset(setup.interest_token_address, interest_amount)],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, collateral_amount)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // Verify: lender is creator, borrower is zero
    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.lender == LENDER(), 'lender is creator');
    assert(inscription.borrower.is_zero(), 'borrower is zero');

    // === 2. Borrower signs (fills the other side) ===
    start_cheat_caller_address(stela_address, BORROWER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.borrower == BORROWER(), 'borrower set on sign');
    assert(inscription.lender == LENDER(), 'lender preserved');
    assert(inscription.issued_debt_percentage == MAX_BPS, '100% filled');

    // Verify token movements: borrower got debt, collateral locked
    assert(setup.debt_token.balance_of(BORROWER()) == debt_amount, 'borrower got debt');
    assert(setup.collateral_token.balance_of(BORROWER()) == 0, 'collateral locked');
    assert(setup.debt_token.balance_of(LENDER()) == 0, 'lender gave debt');

    // Lender has shares
    let lender_shares = get_shares(stela_address, LENDER(), inscription_id);
    assert(lender_shares > 0, 'lender has shares');

    // === 3. Borrower repays ===
    setup_borrower_for_repayment(@setup, BORROWER(), debt_amount, interest_amount);

    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50000);

    start_cheat_caller_address(stela_address, BORROWER());
    stela.repay(inscription_id);
    stop_cheat_caller_address(stela_address);

    assert(stela.get_inscription(inscription_id).is_repaid, 'is repaid');

    // === 4. Lender redeems ===
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(stela_address);

    // Verify: lender got back debt + interest (fee=0, so exact amounts)
    assert(setup.debt_token.balance_of(LENDER()) == debt_amount, 'lender got debt back');
    assert(setup.interest_token.balance_of(LENDER()) == interest_amount, 'lender got interest');
    assert(get_shares(stela_address, LENDER(), inscription_id) == 0, 'shares burned');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       OTC SWAP (duration=0) FULL LIFECYCLE
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_otc_swap_full_lifecycle() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;

    // Set fee to 0 for exact amounts
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(0);
    stop_cheat_caller_address(stela_address);

    setup_borrower_with_collateral(@setup, BORROWER(), collateral_amount);
    setup_lender_with_debt(@setup, LENDER(), debt_amount);

    start_cheat_block_timestamp_global(1000);

    // === 1. Create OTC swap (duration=0, no interest) ===
    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, debt_amount)],
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, collateral_amount)],
        duration: 0,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.duration == 0, 'OTC has no duration');

    // === 2. Sign — atomic swap happens ===
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    // Borrower has debt tokens, collateral is locked
    assert(setup.debt_token.balance_of(BORROWER()) == debt_amount, 'borrower got debt');
    assert(setup.collateral_token.balance_of(BORROWER()) == 0, 'collateral locked');

    let lender_shares = get_shares(stela_address, LENDER(), inscription_id);
    assert(lender_shares > 0, 'lender has shares');

    // === 3. Liquidate immediately (timestamp > signed_at for OTC) ===
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(1001);

    start_cheat_caller_address(stela_address, LENDER());
    stela.liquidate(inscription_id);
    stop_cheat_caller_address(stela_address);

    assert(stela.get_inscription(inscription_id).liquidated, 'OTC liquidated');

    // === 4. Redeem — lender gets collateral ===
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(stela_address);

    // Verify: lender got the collateral (the swap is complete)
    assert(setup.collateral_token.balance_of(LENDER()) == collateral_amount, 'lender got collateral');
    assert(get_shares(stela_address, LENDER(), inscription_id) == 0, 'shares burned');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       TREASURY FEE SHARES VERIFICATION
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_treasury_receives_fee_shares() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    // Default fee is 10 BPS (0.1%)
    assert(stela.get_inscription_fee() == 10, 'default fee is 10 BPS');

    setup_borrower_with_collateral(@setup, BORROWER(), 500);
    setup_lender_with_debt(@setup, LENDER(), 1000);

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, 1000)],
        interest_assets: array![create_erc20_asset(setup.interest_token_address, 100)],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // Sign — lender + treasury get shares
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    let lender_shares = get_shares(stela_address, LENDER(), inscription_id);
    let treasury_shares = get_shares(stela_address, TREASURY(), inscription_id);

    // Treasury must have received fee shares
    assert(treasury_shares > 0, 'treasury got fee shares');
    assert(lender_shares > 0, 'lender got shares');

    // Fee shares should be 0.1% of lender shares (10 BPS)
    // fee_shares = lender_shares * 10 / 10000 = lender_shares / 1000
    let expected_fee = lender_shares / 1000;
    assert(treasury_shares == expected_fee, 'fee is exactly 0.1% of lender');

    // Lender shares should be much larger than treasury shares
    assert(lender_shares > treasury_shares * 100, 'lender >> treasury');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       PARTIAL REDEEM (REDEEM IN STAGES)
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_partial_redeem() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    let debt_amount: u256 = 10000;
    let collateral_amount: u256 = 5000;
    let interest_amount: u256 = 1000;

    // Fee=0 for exact verification
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(0);
    stop_cheat_caller_address(stela_address);

    setup_borrower_with_collateral(@setup, BORROWER(), collateral_amount);
    setup_lender_with_debt(@setup, LENDER(), debt_amount);

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, debt_amount)],
        interest_assets: array![create_erc20_asset(setup.interest_token_address, interest_amount)],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, collateral_amount)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    let total_shares = get_shares(stela_address, LENDER(), inscription_id);

    // Repay
    setup_borrower_for_repayment(@setup, BORROWER(), debt_amount, interest_amount);
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50000);

    start_cheat_caller_address(stela_address, BORROWER());
    stela.repay(inscription_id);
    stop_cheat_caller_address(stela_address);

    // === Partial redeem: first half ===
    let half_shares = total_shares / 2;
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, half_shares);
    stop_cheat_caller_address(stela_address);

    let remaining_shares = get_shares(stela_address, LENDER(), inscription_id);
    assert(remaining_shares == total_shares - half_shares, 'half shares remaining');

    let debt_after_first = setup.debt_token.balance_of(LENDER());
    let interest_after_first = setup.interest_token.balance_of(LENDER());
    assert(debt_after_first > 0, 'got some debt after first');
    assert(interest_after_first > 0, 'got some interest after first');

    // === Partial redeem: second half ===
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, remaining_shares);
    stop_cheat_caller_address(stela_address);

    assert(get_shares(stela_address, LENDER(), inscription_id) == 0, 'all shares burned');

    let debt_after_second = setup.debt_token.balance_of(LENDER());
    let interest_after_second = setup.interest_token.balance_of(LENDER());

    // Total received should equal original amounts (fee=0)
    assert(debt_after_second == debt_amount, 'got all debt back');
    assert(interest_after_second == interest_amount, 'got all interest back');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       PARTIAL FILL + LIQUIDATION (C3 VERIFICATION)
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_partial_fill_liquidation() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    let debt_amount: u256 = 10000;
    let collateral_amount: u256 = 5000;
    let interest_amount: u256 = 1000;

    // Fee=0 for exact amounts
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(0);
    stop_cheat_caller_address(stela_address);

    setup_borrower_with_collateral(@setup, BORROWER(), collateral_amount);
    setup_lender_with_debt(@setup, LENDER(), debt_amount);

    start_cheat_block_timestamp_global(1000);

    // Create multi-lender inscription
    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, debt_amount)],
        interest_assets: array![create_erc20_asset(setup.interest_token_address, interest_amount)],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, collateral_amount)],
        duration: 86400,
        deadline: 2000,
        multi_lender: true,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // Only fill 60% (6000 BPS)
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, 6000);
    stop_cheat_caller_address(stela_address);

    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.issued_debt_percentage == 6000, '60% issued');

    // Verify: borrower got 60% of debt, 60% of collateral locked
    assert(setup.debt_token.balance_of(BORROWER()) == 6000, 'borrower got 60% debt');
    assert(setup.collateral_token.balance_of(BORROWER()) == 2000, 'borrower has 40% col left');

    let lender_shares = get_shares(stela_address, LENDER(), inscription_id);

    // Advance past duration — liquidation possible
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(1000 + 86400 + 1);

    // Liquidate — should NOT revert (C3 fix: pulls 60% of collateral, not 100%)
    start_cheat_caller_address(stela_address, LENDER());
    stela.liquidate(inscription_id);
    stop_cheat_caller_address(stela_address);

    assert(stela.get_inscription(inscription_id).liquidated, 'liquidated');

    // Redeem — lender gets proportional collateral
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(stela_address);

    // Lender should get 60% of collateral = 3000
    let lender_collateral = setup.collateral_token.balance_of(LENDER());
    assert(lender_collateral == 3000, 'lender got 60% collateral');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       EXACT TOKEN AMOUNTS THROUGH FULL LIFECYCLE
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_exact_token_amounts_lifecycle() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    let debt_amount: u256 = 10000;
    let collateral_amount: u256 = 5000;
    let interest_amount: u256 = 2000;

    // Fee=0 for exact verification
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(0);
    stop_cheat_caller_address(stela_address);

    setup_borrower_with_collateral(@setup, BORROWER(), collateral_amount);
    setup_lender_with_debt(@setup, LENDER(), debt_amount);

    // === PRE-SIGN BALANCES ===
    assert(setup.debt_token.balance_of(LENDER()) == debt_amount, 'lender has debt pre-sign');
    assert(setup.collateral_token.balance_of(BORROWER()) == collateral_amount, 'borrower has col pre-sign');

    start_cheat_block_timestamp_global(1000);

    // Create
    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, debt_amount)],
        interest_assets: array![create_erc20_asset(setup.interest_token_address, interest_amount)],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, collateral_amount)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // Sign — tokens move
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    // === POST-SIGN BALANCES ===
    assert(setup.debt_token.balance_of(BORROWER()) == debt_amount, 'borrower has debt post-sign');
    assert(setup.debt_token.balance_of(LENDER()) == 0, 'lender has 0 debt post-sign');
    assert(setup.collateral_token.balance_of(BORROWER()) == 0, 'borrower has 0 col post-sign');
    // Collateral is in the locker
    let locker = stela.get_locker(inscription_id);
    assert(setup.collateral_token.balance_of(locker) == collateral_amount, 'locker holds collateral');

    // Repay
    setup_borrower_for_repayment(@setup, BORROWER(), debt_amount, interest_amount);
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50000);

    start_cheat_caller_address(stela_address, BORROWER());
    stela.repay(inscription_id);
    stop_cheat_caller_address(stela_address);

    // === POST-REPAY BALANCES ===
    // Borrower keeps the debt received during sign (10000) — they repaid with separately minted tokens
    assert(setup.debt_token.balance_of(BORROWER()) == debt_amount, 'borrower keeps signed debt');
    assert(setup.interest_token.balance_of(BORROWER()) == 0, 'borrower spent interest');
    // Stela contract holds the repaid tokens
    assert(setup.debt_token.balance_of(stela_address) == debt_amount, 'stela holds debt');
    assert(setup.interest_token.balance_of(stela_address) == interest_amount, 'stela holds interest');
    // Locker is unlocked — borrower can reclaim collateral
    assert(setup.collateral_token.balance_of(locker) == collateral_amount, 'locker still has col');

    // Redeem
    let lender_shares = get_shares(stela_address, LENDER(), inscription_id);
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(stela_address);

    // === POST-REDEEM BALANCES (fee=0, so exact) ===
    assert(setup.debt_token.balance_of(LENDER()) == debt_amount, 'lender got exact debt');
    assert(setup.interest_token.balance_of(LENDER()) == interest_amount, 'lender got exact interest');
    assert(setup.debt_token.balance_of(stela_address) == 0, 'stela drained of debt');
    assert(setup.interest_token.balance_of(stela_address) == 0, 'stela drained of interest');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       REDEEM BEFORE REPAY/LIQUIDATE FAILS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: not redeemable')]
fn test_redeem_before_resolution_fails() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token_address = setup.interest_token_address;

    collateral_token.mint(BORROWER(), 500);
    start_cheat_caller_address(collateral_token_address, BORROWER());
    collateral_token.approve(stela_address, 500);
    stop_cheat_caller_address(collateral_token_address);

    debt_token.mint(LENDER(), 1000);
    start_cheat_caller_address(debt_token_address, LENDER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token_address, 1000)],
        interest_assets: array![create_erc20_asset(interest_token_address, 100)],
        collateral_assets: array![create_erc20_asset(collateral_token_address, 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(stela_address);

    // Try to redeem without repay or liquidate — must panic
    let lender_shares = get_shares(stela_address, LENDER(), inscription_id);
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, lender_shares);
}

// ============================================================
//    M1: ZERO-PERCENTAGE MULTI-LENDER SIGN PREVENTION
// ============================================================

/// Verify that a multi-lender sign with 0% is rejected.
/// Without this check, a griefer could DOS any multi-lender inscription
/// by triggering first-fill (NFT mint, TBA creation) with 0% funding.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: zero shares')]
fn test_multi_lender_zero_percentage_sign_fails() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    start_cheat_block_timestamp_global(1000);

    // Create multi-lender inscription
    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, 10000)],
        interest_assets: array![create_erc20_asset(setup.interest_token_address, 1000)],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: true,
    };
    let inscription_id = stela.create_inscription(params);
    stop_cheat_caller_address(stela_address);

    // Griefer tries to sign with 0% — must panic
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, 0);
}

// ============================================================
//    ERC721 AS DEBT/INTEREST RESTRICTION
// ============================================================

/// ERC721 in debt assets must be rejected.
/// NFTs are non-fungible — they can't be scaled by percentage for partial fills
/// or split pro-rata on redemption.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: nft not fungible')]
fn test_erc721_debt_asset_rejected() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let nft_asset = super::test_utils::create_erc721_asset(setup.nft_address, 1);
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![nft_asset],
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

/// ERC721 in interest assets must be rejected.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: nft not fungible')]
fn test_erc721_interest_asset_rejected() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let nft_asset = super::test_utils::create_erc721_asset(setup.nft_address, 1);
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(setup.debt_token_address, 10000)],
        interest_assets: array![nft_asset],
        collateral_assets: array![create_erc20_asset(setup.collateral_token_address, 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

/// ERC721 in collateral is allowed (this must NOT panic).
#[test]
#[feature("deprecated-starknet-consts")]
fn test_erc721_collateral_allowed() {
    let (_, stela) = deploy_stela();
    let stela_address = stela.contract_address;

    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(stela_address, BORROWER());
    let nft_asset = super::test_utils::create_erc721_asset(MOCK_NFT(), 1);
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(MOCK_TOKEN(), 10000)],
        interest_assets: array![],
        collateral_assets: array![nft_asset],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.collateral_asset_count == 1, 'nft collateral stored');
}

// ============================================================
//    IMPLEMENTATION HASH ZERO CHECK
// ============================================================

/// Constructor must reject zero implementation_hash.
#[test]
#[feature("deprecated-starknet-consts")]
fn test_zero_implementation_hash_rejected() {
    let contract = declare("StelaProtocol").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    OWNER().serialize(ref calldata);
    TREASURY().serialize(ref calldata);
    NFT_CONTRACT().serialize(ref calldata);
    REGISTRY().serialize(ref calldata);
    calldata.append(0); // zero implementation_hash

    // Deploy must fail — constructor rejects zero impl hash
    let result = contract.deploy(@calldata);
    assert(result.is_err(), 'should reject zero impl hash');
}

// ============================================================
//    ASSET ARRAY LENGTH CAP
// ============================================================

/// create_inscription must reject debt arrays exceeding MAX_ASSETS (10).
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: too many assets')]
fn test_too_many_debt_assets_rejected() {
    let (_, stela) = deploy_stela();
    let stela_address = stela.contract_address;

    start_cheat_block_timestamp_global(1000);

    // Build 11 debt assets (exceeds cap of 10)
    let mut debt_assets: Array<Asset> = array![];
    let mut i: u32 = 0;
    while i < 11 {
        debt_assets.append(create_erc20_asset(MOCK_TOKEN(), 100));
        i += 1;
    }

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets,
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(MOCK_TOKEN(), 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

/// create_inscription must reject collateral arrays exceeding MAX_ASSETS (10).
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: too many assets')]
fn test_too_many_collateral_assets_rejected() {
    let (_, stela) = deploy_stela();
    let stela_address = stela.contract_address;

    start_cheat_block_timestamp_global(1000);

    // Build 11 collateral assets
    let mut collateral_assets: Array<Asset> = array![];
    let mut i: u32 = 0;
    while i < 11 {
        collateral_assets.append(create_erc20_asset(MOCK_TOKEN(), 100));
        i += 1;
    }

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(MOCK_TOKEN(), 10000)],
        interest_assets: array![],
        collateral_assets,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

/// 10 assets (at the cap) must succeed.
#[test]
#[feature("deprecated-starknet-consts")]
fn test_max_assets_at_cap_succeeds() {
    let (_, stela) = deploy_stela();
    let stela_address = stela.contract_address;

    start_cheat_block_timestamp_global(1000);

    // Build exactly 10 debt assets (at the cap)
    let mut debt_assets: Array<Asset> = array![];
    let mut i: u32 = 0;
    while i < 10 {
        debt_assets.append(create_erc20_asset(MOCK_TOKEN(), 100));
        i += 1;
    }

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets,
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(MOCK_TOKEN(), 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.debt_asset_count == 10, '10 debt assets stored');
}

// ============================================================
//       ERC1155 AS DEBT/INTEREST MUST BE REJECTED
// ============================================================

/// ERC1155 in debt assets must be rejected — redeem uses IERC20Dispatcher
/// which would permanently lock lender funds.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: nft not fungible')]
fn test_erc1155_debt_asset_rejected() {
    let (_, stela) = deploy_stela();
    let stela_address = stela.contract_address;

    start_cheat_block_timestamp_global(1000);

    let erc1155_asset = Asset { asset: MOCK_TOKEN(), asset_type: AssetType::ERC1155, value: 100, token_id: 1 };

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![erc1155_asset],
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(MOCK_TOKEN(), 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

/// ERC1155 in interest assets must be rejected.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: nft not fungible')]
fn test_erc1155_interest_asset_rejected() {
    let (_, stela) = deploy_stela();
    let stela_address = stela.contract_address;

    start_cheat_block_timestamp_global(1000);

    let erc1155_asset = Asset { asset: MOCK_TOKEN(), asset_type: AssetType::ERC1155, value: 100, token_id: 1 };

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(MOCK_TOKEN(), 10000)],
        interest_assets: array![erc1155_asset],
        collateral_assets: array![create_erc20_asset(MOCK_TOKEN(), 5000)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params);
}

/// ERC1155 as collateral must still be allowed.
#[test]
#[feature("deprecated-starknet-consts")]
fn test_erc1155_collateral_allowed() {
    let (_, stela) = deploy_stela();
    let stela_address = stela.contract_address;

    start_cheat_block_timestamp_global(1000);

    let erc1155_collateral = Asset { asset: MOCK_TOKEN(), asset_type: AssetType::ERC1155, value: 100, token_id: 1 };

    start_cheat_caller_address(stela_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(MOCK_TOKEN(), 10000)],
        interest_assets: array![],
        collateral_assets: array![erc1155_collateral],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    let inscription_id = stela.create_inscription(params);
    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.collateral_asset_count == 1, 'erc1155 collateral ok');
}
