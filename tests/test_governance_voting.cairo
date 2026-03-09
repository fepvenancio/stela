// Tests for borrower-callable governance voting (set_borrower_governance_selector)

use snforge_std::{
    start_cheat_block_timestamp_global, stop_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use stela::interfaces::istela::IStelaProtocolDispatcherTrait;
use stela::utils::share_math::MAX_BPS;
use crate::test_utils::{
    BORROWER, LENDER, OWNER, deploy_full_setup,
    setup_borrower_with_collateral, setup_lender_with_debt,
    create_borrow_params_from_setup,
};

#[feature("deprecated-starknet-consts")]
fn GOVERNANCE_TARGET() -> starknet::ContractAddress {
    starknet::contract_address_const::<'GOV_TARGET'>()
}

/// Helper: whitelist governance target as owner
fn whitelist_governance_target(setup: @crate::test_utils::TestSetup) {
    start_cheat_caller_address(*setup.stela_address, OWNER());
    (*setup.stela).set_governance_target(GOVERNANCE_TARGET(), true);
    stop_cheat_caller_address(*setup.stela_address);
}

/// Helper: create and sign an inscription, return inscription_id
#[feature("deprecated-starknet-consts")]
fn create_signed_inscription(
    setup: @crate::test_utils::TestSetup,
) -> u256 {
    setup_borrower_with_collateral(setup, BORROWER(), 5000);
    setup_lender_with_debt(setup, LENDER(), 10000);

    start_cheat_block_timestamp_global(1000);

    let params = create_borrow_params_from_setup(setup, 10000, 5000, 2000, 86400, 2000);
    start_cheat_caller_address(*setup.stela_address, BORROWER());
    let inscription_id = (*setup.stela).create_inscription(params);
    stop_cheat_caller_address(*setup.stela_address);

    start_cheat_caller_address(*setup.stela_address, LENDER());
    (*setup.stela).sign_inscription(inscription_id, MAX_BPS);
    stop_cheat_caller_address(*setup.stela_address);

    inscription_id
}

// ============================================================
//         BORROWER GOVERNANCE SELECTOR — HAPPY PATH
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_borrower_can_set_vote_selector() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    let inscription_id = create_signed_inscription(@setup);

    start_cheat_caller_address(setup.stela_address, BORROWER());
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("vote"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_borrower_can_set_delegate_selector() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    let inscription_id = create_signed_inscription(@setup);

    start_cheat_caller_address(setup.stela_address, BORROWER());
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("delegate"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_borrower_can_set_delegate_by_sig_selector() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    let inscription_id = create_signed_inscription(@setup);

    start_cheat_caller_address(setup.stela_address, BORROWER());
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("delegate_by_sig"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_borrower_can_disable_selector() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    let inscription_id = create_signed_inscription(@setup);

    start_cheat_caller_address(setup.stela_address, BORROWER());
    // Enable then disable
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("vote"), true,
    );
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("vote"), false,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

// ============================================================
//         BORROWER GOVERNANCE SELECTOR — FAILURE CASES
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: unsafe selector')]
fn test_unsafe_selector_rejected() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    let inscription_id = create_signed_inscription(@setup);

    // Try to set transfer selector — should fail (unsafe selector, before target check)
    start_cheat_caller_address(setup.stela_address, BORROWER());
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("transfer"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: unsafe selector')]
fn test_approve_selector_rejected() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    let inscription_id = create_signed_inscription(@setup);

    start_cheat_caller_address(setup.stela_address, BORROWER());
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("approve"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: gov target not allowed')]
fn test_non_whitelisted_target_rejected() {
    let setup = deploy_full_setup();
    // Do NOT whitelist target
    let inscription_id = create_signed_inscription(@setup);

    start_cheat_caller_address(setup.stela_address, BORROWER());
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("vote"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: unauthorized')]
fn test_non_borrower_cannot_set_selector() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    let inscription_id = create_signed_inscription(@setup);

    // Lender tries to set selector — should fail
    start_cheat_caller_address(setup.stela_address, LENDER());
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("vote"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid inscription')]
fn test_unsigned_inscription_rejected() {
    let setup = deploy_full_setup();
    whitelist_governance_target(@setup);
    setup_borrower_with_collateral(@setup, BORROWER(), 5000);

    start_cheat_block_timestamp_global(1000);

    let params = create_borrow_params_from_setup(@setup, 10000, 5000, 2000, 86400, 2000);
    start_cheat_caller_address(setup.stela_address, BORROWER());
    let inscription_id = setup.stela.create_inscription(params);

    // Try to set selector on unsigned inscription
    setup.stela.set_borrower_governance_selector(
        inscription_id, GOVERNANCE_TARGET(), selector!("vote"), true,
    );
    stop_cheat_caller_address(setup.stela_address);

    stop_cheat_block_timestamp_global();
}
