// Integration tests for fill_signed_order entry point (SETL-01..06)
//
// Uses MockAccount as maker so is_valid_signature always returns VALIDATED.
// All tests should FAIL (RED phase) until Plan 01-03 provides the real implementation.
// The stubs currently panic!("not implemented") or return hardcoded values.

use openzeppelin_utils::snip12::StructHash;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global, start_cheat_caller_address,
    stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::istela::IStelaProtocolDispatcherTrait;
use stela::types::signed_order::SignedOrder;
use super::test_utils::{LENDER, deploy_stela};

// ============================================================
//                    HELPERS
// ============================================================

/// Deploy a MockAccount contract and return its address.
fn deploy_mock_account() -> ContractAddress {
    let contract = declare("MockAccount").unwrap().contract_class();
    let constructor_calldata: Array<felt252> = array![];
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    contract_address
}

/// Create a standard open order for integration tests.
#[feature("deprecated-starknet-consts")]
fn create_standard_order(maker: ContractAddress) -> SignedOrder {
    SignedOrder {
        maker,
        allowed_taker: starknet::contract_address_const::<0>(),
        inscription_id: 1_u256,
        bps: 10000_u256,
        deadline: 2000_u64,
        nonce: 0,
        min_fill_bps: 0_u256,
    }
}

// ============================================================
//            INTEGRATION TESTS (should FAIL -- RED phase)
// ============================================================

#[test]
fn test_fill_signed_order_first_registers_order() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    let order = create_standard_order(maker);
    let order_hash = order.hash_struct();

    // Fill as LENDER
    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 5000_u256);
    stop_cheat_caller_address(contract_address);

    // Verify the order is registered after first fill
    let registered = stela.is_order_registered(order_hash);
    assert(registered, 'order must be registered');

    stop_cheat_block_timestamp_global();
}

#[test]
fn test_fill_subsequent_no_signature_succeeds() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    let order = create_standard_order(maker);

    // First fill with signature (empty array -- MockAccount validates anything)
    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 3000_u256);

    // Second fill with empty signature -- should succeed because order is already registered
    stela.fill_signed_order(order, array![], 2000_u256);
    stop_cheat_caller_address(contract_address);

    stop_cheat_block_timestamp_global();
}

#[test]
fn test_fill_partial_accounting() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    let order = create_standard_order(maker);
    let order_hash = order.hash_struct();

    // Fill 5000 bps
    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 5000_u256);
    stop_cheat_caller_address(contract_address);

    // Verify accumulated fill
    let filled = stela.get_filled_bps(order_hash);
    assert(filled == 5000_u256, 'filled bps must be 5000');

    stop_cheat_block_timestamp_global();
}

#[test]
#[should_panic(expected: 'STELA: overfill')]
fn test_overfill_fails() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    let order = create_standard_order(maker);

    start_cheat_caller_address(contract_address, LENDER());
    // Fill 5000 bps first
    stela.fill_signed_order(order, array![], 5000_u256);
    // Try to fill 5001 more -- total 10001 > 10000 (MAX_BPS) -> overfill
    stela.fill_signed_order(order, array![], 5001_u256);
    stop_cheat_caller_address(contract_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[should_panic(expected: 'STELA: order expired')]
#[feature("deprecated-starknet-consts")]
fn test_fill_expired_fails() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    // Set timestamp past the deadline
    start_cheat_block_timestamp_global(3000);

    let order = SignedOrder {
        maker,
        allowed_taker: starknet::contract_address_const::<0>(),
        inscription_id: 1_u256,
        bps: 10000_u256,
        deadline: 2000_u64,
        nonce: 0,
        min_fill_bps: 0_u256,
    };

    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 5000_u256);
    stop_cheat_caller_address(contract_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[should_panic(expected: 'STELA: order cancelled')]
fn test_fill_cancelled_fails() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    let order = create_standard_order(maker);

    // Cancel as maker
    start_cheat_caller_address(contract_address, maker);
    stela.cancel_order(order);
    stop_cheat_caller_address(contract_address);

    // Try to fill -- should fail
    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 5000_u256);
    stop_cheat_caller_address(contract_address);

    stop_cheat_block_timestamp_global();
}

#[test]
#[should_panic(expected: 'STELA: self trade')]
fn test_fill_self_trade_fails() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    let order = create_standard_order(maker);

    // Try to fill as the maker itself -- self trade
    start_cheat_caller_address(contract_address, maker);
    stela.fill_signed_order(order, array![], 5000_u256);
    stop_cheat_caller_address(contract_address);

    stop_cheat_block_timestamp_global();
}

#[test]
fn test_u256_boundary_no_overflow() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    // Order with bps = MAX_BPS (10000)
    let order = create_standard_order(maker);

    // Fill exactly MAX_BPS -- should not overflow
    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 10000_u256);
    stop_cheat_caller_address(contract_address);

    let order_hash = order.hash_struct();
    let filled = stela.get_filled_bps(order_hash);
    assert(filled == 10000_u256, 'filled must equal MAX_BPS');

    stop_cheat_block_timestamp_global();
}
