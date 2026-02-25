// Unit tests for SignedOrder struct and hash (SIGN-01..05)
// Also includes entry-point tests that exercise fill/cancel through the contract.
//
// Hash tests (test_signed_order_hash_*) are pure struct tests and should PASS.
// Entry-point tests (test_fill_*, test_cancel_*) call stub implementations
// and should FAIL (RED phase) until Plan 01-03 provides the real implementation.

use openzeppelin_utils::snip12::StructHash;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global, start_cheat_caller_address,
    stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::istela::IStelaProtocolDispatcherTrait;
use stela::types::signed_order::SignedOrder;
use super::test_utils::{BORROWER, LENDER, deploy_stela};

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

/// Create a default SignedOrder for testing.
#[feature("deprecated-starknet-consts")]
fn create_default_order(maker: ContractAddress) -> SignedOrder {
    SignedOrder {
        maker,
        allowed_taker: starknet::contract_address_const::<0>(),
        inscription_id: 1_u256,
        bps: 5000_u256,
        deadline: 2000_u64,
        nonce: 0,
        min_fill_bps: 0_u256,
    }
}

// ============================================================
//                    HASH UNIT TESTS (should PASS)
// ============================================================

#[test]
fn test_signed_order_hash_deterministic() {
    let maker = deploy_mock_account();
    let order = create_default_order(maker);
    let hash1 = order.hash_struct();
    let hash2 = order.hash_struct();
    assert(hash1 == hash2, 'hash must be deterministic');
}

#[test]
fn test_signed_order_hash_nonzero() {
    let maker = deploy_mock_account();
    let order = create_default_order(maker);
    let hash = order.hash_struct();
    assert(hash != 0, 'hash must be nonzero');
}

#[test]
fn test_signed_order_hash_field_sensitive() {
    let maker = deploy_mock_account();
    let order1 = create_default_order(maker);
    let hash1 = order1.hash_struct();

    // Change bps
    let order2 = SignedOrder { bps: 6000_u256, ..order1 };
    let hash2 = order2.hash_struct();
    assert(hash1 != hash2, 'bps change changes hash');

    // Change deadline
    let order3 = SignedOrder { deadline: 3000_u64, ..order1 };
    let hash3 = order3.hash_struct();
    assert(hash1 != hash3, 'deadline change changes hash');

    // Change nonce
    let order4 = SignedOrder { nonce: 1, ..order1 };
    let hash4 = order4.hash_struct();
    assert(hash1 != hash4, 'nonce change changes hash');

    // Change inscription_id
    let order5 = SignedOrder { inscription_id: 2_u256, ..order1 };
    let hash5 = order5.hash_struct();
    assert(hash1 != hash5, 'id change changes hash');

    // Change min_fill_bps
    let order6 = SignedOrder { min_fill_bps: 100_u256, ..order1 };
    let hash6 = order6.hash_struct();
    assert(hash1 != hash6, 'min_fill change changes hash');
}

// ============================================================
//                    ENTRY POINT TESTS (should FAIL -- RED phase)
// ============================================================

#[test]
#[should_panic(expected: 'STELA: order expired')]
#[feature("deprecated-starknet-consts")]
fn test_fill_expired_order_fails() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    // Order deadline is 1000, but block timestamp is 2000 (past deadline)
    start_cheat_block_timestamp_global(2000);

    let order = SignedOrder {
        maker,
        allowed_taker: starknet::contract_address_const::<0>(),
        inscription_id: 1_u256,
        bps: 5000_u256,
        deadline: 1000_u64,
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
#[feature("deprecated-starknet-consts")]
fn test_fill_cancelled_order_fails() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    let order = SignedOrder {
        maker,
        allowed_taker: starknet::contract_address_const::<0>(),
        inscription_id: 1_u256,
        bps: 5000_u256,
        deadline: 2000_u64,
        nonce: 0,
        min_fill_bps: 0_u256,
    };

    // Cancel the order as maker first
    start_cheat_caller_address(contract_address, maker);
    stela.cancel_order(order);
    stop_cheat_caller_address(contract_address);

    // Now try to fill -- should fail with ORDER_CANCELLED
    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 5000_u256);
    stop_cheat_caller_address(contract_address);
    stop_cheat_block_timestamp_global();
}

#[test]
#[should_panic(expected: 'STELA: unauthorized taker')]
fn test_fill_private_taker_wrong_caller_fails() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    // Order restricted to BORROWER, but we call as LENDER
    let order = SignedOrder {
        maker,
        allowed_taker: BORROWER(),
        inscription_id: 1_u256,
        bps: 5000_u256,
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
#[should_panic(expected: 'STELA: invalid nonce')]
#[feature("deprecated-starknet-consts")]
fn test_cancel_by_nonce_invalidates_order() {
    let (contract_address, stela) = deploy_stela();
    let maker = deploy_mock_account();

    start_cheat_block_timestamp_global(1000);

    // Cancel all orders with nonce < 1 (invalidates nonce=0)
    start_cheat_caller_address(contract_address, maker);
    stela.cancel_orders_by_nonce(1);
    stop_cheat_caller_address(contract_address);

    // Try to fill order with nonce=0 -- should fail with INVALID_NONCE
    let order = SignedOrder {
        maker,
        allowed_taker: starknet::contract_address_const::<0>(),
        inscription_id: 1_u256,
        bps: 5000_u256,
        deadline: 2000_u64,
        nonce: 0,
        min_fill_bps: 0_u256,
    };

    start_cheat_caller_address(contract_address, LENDER());
    stela.fill_signed_order(order, array![], 5000_u256);
    stop_cheat_caller_address(contract_address);
    stop_cheat_block_timestamp_global();
}
