// Tests for pause/unpause functionality.
// Validates that pauser access control works and that paused state blocks all write operations.

use openzeppelin_interfaces::erc1155::IERC1155DispatcherTrait;
use snforge_std::{
    start_cheat_block_timestamp_global, start_cheat_caller_address, stop_cheat_block_timestamp_global,
    stop_cheat_caller_address,
};
use stela::interfaces::istela::IStelaProtocolDispatcherTrait;
use stela::types::inscription::InscriptionParams;
use stela::utils::share_math::MAX_BPS;
use super::mocks::mock_erc20::IMockERC20DispatcherTrait;
use super::test_utils::{BORROWER, LENDER, OWNER, create_erc20_asset, deploy_full_setup, deploy_stela};

// ============================================================
//                    PAUSE / UNPAUSE ACCESS CONTROL
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_pause_by_pauser() {
    let (contract_address, stela) = deploy_stela();

    // OWNER is pauser in deploy_stela
    start_cheat_caller_address(contract_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(contract_address);

    assert(stela.is_paused(), 'should be paused');
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: unauthorized')]
fn test_pause_by_non_pauser() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_caller_address(contract_address, BORROWER());
    stela.pause(); // Should panic
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_unpause_by_pauser() {
    let (contract_address, stela) = deploy_stela();

    // Pause first
    start_cheat_caller_address(contract_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(contract_address);

    assert(stela.is_paused(), 'should be paused');

    // Unpause
    start_cheat_caller_address(contract_address, OWNER());
    stela.unpause();
    stop_cheat_caller_address(contract_address);

    assert(!stela.is_paused(), 'should not be paused');
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: unauthorized')]
fn test_unpause_by_non_pauser() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_caller_address(contract_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(contract_address);

    start_cheat_caller_address(contract_address, LENDER());
    stela.unpause(); // Should panic
}

// ============================================================
//           PAUSED STATE BLOCKS WRITE OPERATIONS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Pausable: paused')]
fn test_create_inscription_when_paused() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);

    // Pause
    start_cheat_caller_address(contract_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(contract_address);

    // Try create inscription
    let debt_token = starknet::contract_address_const::<'DEBT'>();
    let collateral_token = starknet::contract_address_const::<'COL'>();
    let interest_token = starknet::contract_address_const::<'INT'>();

    start_cheat_caller_address(contract_address, BORROWER());
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token, 1000)],
        interest_assets: array![create_erc20_asset(interest_token, 100)],
        collateral_assets: array![create_erc20_asset(collateral_token, 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };
    stela.create_inscription(params); // Should panic
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Pausable: paused')]
fn test_sign_inscription_when_paused() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token_address = setup.debt_token_address;
    let collateral_token_address = setup.collateral_token_address;
    let collateral_token = setup.collateral_token;
    let debt_token = setup.debt_token;
    let interest_token_address = setup.interest_token_address;

    // Setup balances
    collateral_token.mint(BORROWER(), 500);
    start_cheat_caller_address(collateral_token_address, BORROWER());
    collateral_token.approve(stela_address, 500);
    stop_cheat_caller_address(collateral_token_address);

    debt_token.mint(LENDER(), 1000);
    start_cheat_caller_address(debt_token_address, LENDER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);

    start_cheat_block_timestamp_global(1000);

    // Create inscription
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

    // Pause
    start_cheat_caller_address(stela_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(stela_address);

    // Try sign when paused
    start_cheat_caller_address(stela_address, LENDER());
    stela.sign_inscription(inscription_id, MAX_BPS); // Should panic
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Pausable: paused')]
fn test_repay_when_paused() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token = setup.interest_token;
    let interest_token_address = setup.interest_token_address;

    // Setup balances
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

    // Setup repayment
    debt_token.mint(BORROWER(), 1000);
    interest_token.mint(BORROWER(), 100);
    start_cheat_caller_address(debt_token_address, BORROWER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);
    start_cheat_caller_address(interest_token_address, BORROWER());
    interest_token.approve(stela_address, 100);
    stop_cheat_caller_address(interest_token_address);

    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50000);

    // Pause
    start_cheat_caller_address(stela_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(stela_address);

    // Try repay
    start_cheat_caller_address(stela_address, BORROWER());
    stela.repay(inscription_id); // Should panic
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Pausable: paused')]
fn test_liquidate_when_paused() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
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

    // Advance past duration
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(1000 + 86400 + 1);

    // Pause
    start_cheat_caller_address(stela_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(stela_address);

    // Try liquidate
    start_cheat_caller_address(stela_address, LENDER());
    stela.liquidate(inscription_id); // Should panic
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Pausable: paused')]
fn test_redeem_when_paused() {
    let setup = deploy_full_setup();
    let stela = setup.stela;
    let stela_address = setup.stela_address;
    let debt_token = setup.debt_token;
    let debt_token_address = setup.debt_token_address;
    let collateral_token = setup.collateral_token;
    let collateral_token_address = setup.collateral_token_address;
    let interest_token = setup.interest_token;
    let interest_token_address = setup.interest_token_address;

    let erc1155 = openzeppelin_interfaces::erc1155::IERC1155Dispatcher { contract_address: stela_address };

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

    // Repay
    debt_token.mint(BORROWER(), 1000);
    interest_token.mint(BORROWER(), 100);
    start_cheat_caller_address(debt_token_address, BORROWER());
    debt_token.approve(stela_address, 1000);
    stop_cheat_caller_address(debt_token_address);
    start_cheat_caller_address(interest_token_address, BORROWER());
    interest_token.approve(stela_address, 100);
    stop_cheat_caller_address(interest_token_address);

    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50000);

    start_cheat_caller_address(stela_address, BORROWER());
    stela.repay(inscription_id);
    stop_cheat_caller_address(stela_address);

    let lender_shares = erc1155.balance_of(LENDER(), inscription_id);

    // Pause
    start_cheat_caller_address(stela_address, OWNER());
    stela.pause();
    stop_cheat_caller_address(stela_address);

    // Try redeem
    start_cheat_caller_address(stela_address, LENDER());
    stela.redeem(inscription_id, lender_shares); // Should panic
}
