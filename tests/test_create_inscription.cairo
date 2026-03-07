// Tests for create_inscription function

use core::num::traits::Zero;
use snforge_std::{
    start_cheat_block_timestamp_global, start_cheat_caller_address, stop_cheat_block_timestamp_global,
    stop_cheat_caller_address,
};
use stela::interfaces::istela::IStelaProtocolDispatcherTrait;
use stela::types::inscription::InscriptionParams;
use super::test_utils::{
    BORROWER, LENDER, MOCK_NFT, MOCK_TOKEN, create_borrow_params, create_erc20_asset, create_lend_params, deploy_stela,
};

// ============================================================
//                    HAPPY PATH TESTS
// ============================================================

#[test]
fn test_create_borrow_inscription() {
    // Deploy contract
    let (contract_address, stela) = deploy_stela();

    // Set block timestamp
    start_cheat_block_timestamp_global(1000);

    // Create inscription as borrower
    start_cheat_caller_address(contract_address, BORROWER());

    let params = create_borrow_params(
        MOCK_TOKEN(), // debt token
        1000, // debt amount
        MOCK_NFT(), // collateral token
        500, // collateral amount
        MOCK_TOKEN(), // interest token
        100, // interest amount
        86400, // duration (1 day)
        2000 // deadline
    );

    let inscription_id = stela.create_inscription(params);

    // Verify inscription was created
    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.borrower == BORROWER(), 'borrower mismatch');
    assert(inscription.lender.is_zero(), 'lender should be zero');
    assert(inscription.duration == 86400, 'duration mismatch');
    assert(inscription.deadline == 2000, 'deadline mismatch');
    assert(inscription.issued_debt_percentage == 0, 'should have 0% issued');
    assert(!inscription.is_repaid, 'should not be repaid');
    assert(!inscription.liquidated, 'should not be liquidated');
    assert(!inscription.multi_lender, 'should not be multi-lender');

    stop_cheat_caller_address(contract_address);
    stop_cheat_block_timestamp_global();
}

#[test]
fn test_create_lend_inscription() {
    // Deploy contract
    let (contract_address, stela) = deploy_stela();

    // Set block timestamp
    start_cheat_block_timestamp_global(1000);

    // Create inscription as lender
    start_cheat_caller_address(contract_address, LENDER());

    let params = create_lend_params(
        MOCK_TOKEN(), // debt token
        1000, // debt amount
        MOCK_NFT(), // collateral token
        500, // collateral amount
        MOCK_TOKEN(), // interest token
        100, // interest amount
        86400, // duration (1 day)
        2000 // deadline
    );

    let inscription_id = stela.create_inscription(params);

    // Verify inscription was created
    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.borrower.is_zero(), 'borrower should be zero');
    assert(inscription.lender == LENDER(), 'lender mismatch');
    assert(inscription.duration == 86400, 'duration mismatch');
    assert(inscription.deadline == 2000, 'deadline mismatch');

    stop_cheat_caller_address(contract_address);
    stop_cheat_block_timestamp_global();
}

#[test]
fn test_inscription_id_is_deterministic() {
    // Deploy contract
    let (contract_address, stela) = deploy_stela();

    // Set block timestamp
    start_cheat_block_timestamp_global(1000);

    start_cheat_caller_address(contract_address, BORROWER());

    let params1 = create_borrow_params(MOCK_TOKEN(), 1000, MOCK_NFT(), 500, MOCK_TOKEN(), 100, 86400, 2000);

    let inscription_id_1 = stela.create_inscription(params1);

    // Creating with same params at same timestamp should fail (duplicate)
    // But if we change timestamp, we should get a different ID
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(1001);

    let params2 = create_borrow_params(MOCK_TOKEN(), 1000, MOCK_NFT(), 500, MOCK_TOKEN(), 100, 86400, 2000);

    let inscription_id_2 = stela.create_inscription(params2);

    assert(inscription_id_1 != inscription_id_2, 'IDs should differ with time');

    stop_cheat_caller_address(contract_address);
    stop_cheat_block_timestamp_global();
}

// ============================================================
//                    FAILURE TESTS
// ============================================================

#[test]
#[should_panic(expected: 'STELA: zero debt assets')]
fn test_create_inscription_no_debt_assets() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(contract_address, BORROWER());

    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![], // Empty!
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(MOCK_TOKEN(), 500)],
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };

    stela.create_inscription(params);
}

#[test]
#[should_panic(expected: 'STELA: zero collateral')]
fn test_create_inscription_no_collateral() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(contract_address, BORROWER());

    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(MOCK_TOKEN(), 1000)],
        interest_assets: array![],
        collateral_assets: array![], // Empty!
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
    };

    stela.create_inscription(params);
}

#[test]
#[should_panic(expected: 'STELA: inscription expired')]
fn test_create_inscription_expired_deadline() {
    let (contract_address, stela) = deploy_stela();

    // Set timestamp to 2000, but deadline will be 1500 (in the past)
    start_cheat_block_timestamp_global(2000);
    start_cheat_caller_address(contract_address, BORROWER());

    let params = create_borrow_params(
        MOCK_TOKEN(), 1000, MOCK_NFT(), 500, MOCK_TOKEN(), 100, 86400, 1500 // deadline in past
    );

    stela.create_inscription(params);
}

#[test]
fn test_view_functions() {
    let (_contract_address, stela) = deploy_stela();

    // Test convert_to_shares for non-existent inscription (should not panic)
    let shares = stela.convert_to_shares(0, 5000);
    // With no existing supply, shares should be proportional to VIRTUAL_SHARE_OFFSET
    assert(shares > 0, 'should calculate shares');
}
