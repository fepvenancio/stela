// Tests for fill_signed_order, cancel_order, and cancel_orders_by_nonce.
// Validates the signed order matching engine: fills, cancellations, and edge cases.

use core::num::traits::Zero;
use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};
use openzeppelin_utils::cryptography::snip12::StructHash;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global, start_cheat_caller_address,
    stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::istela::{IStelaProtocolDispatcher, IStelaProtocolDispatcherTrait};
use stela::types::asset::{Asset, AssetType};
use stela::types::signed_order::SignedOrder;
use stela::utils::share_math::MAX_BPS;
use super::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use super::mocks::mock_erc721::IMockERC721Dispatcher;
use super::mocks::mock_registry::{IMockRegistryDispatcher, IMockRegistryDispatcherTrait};

// ============================================================
//                    TEST ADDRESSES
// ============================================================

#[feature("deprecated-starknet-consts")]
fn OWNER() -> ContractAddress {
    starknet::contract_address_const::<'OWNER'>()
}

#[feature("deprecated-starknet-consts")]
fn MAKER() -> ContractAddress {
    starknet::contract_address_const::<'MAKER'>()
}

#[feature("deprecated-starknet-consts")]
fn TAKER() -> ContractAddress {
    starknet::contract_address_const::<'TAKER'>()
}

#[feature("deprecated-starknet-consts")]
fn TAKER_2() -> ContractAddress {
    starknet::contract_address_const::<'TAKER_2'>()
}

// ============================================================
//                    TEST SETUP
// ============================================================

#[derive(Drop)]
struct FillSetup {
    stela_address: ContractAddress,
    stela: IStelaProtocolDispatcher,
    debt_token_address: ContractAddress,
    debt_token: IMockERC20Dispatcher,
    collateral_token_address: ContractAddress,
    collateral_token: IMockERC20Dispatcher,
    interest_token_address: ContractAddress,
    interest_token: IMockERC20Dispatcher,
    nft_address: ContractAddress,
    registry_address: ContractAddress,
    maker_account: ContractAddress,
    taker_account: ContractAddress,
    taker2_account: ContractAddress,
}

fn deploy_erc20(name: ByteArray, symbol: ByteArray) -> (ContractAddress, IMockERC20Dispatcher) {
    let contract = declare("MockERC20").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    calldata.append(18);
    let (address, _) = contract.deploy(@calldata).unwrap();
    (address, IMockERC20Dispatcher { contract_address: address })
}

fn deploy_erc721(name: ByteArray, symbol: ByteArray) -> (ContractAddress, IMockERC721Dispatcher) {
    let contract = declare("MockERC721").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    let (address, _) = contract.deploy(@calldata).unwrap();
    (address, IMockERC721Dispatcher { contract_address: address })
}

fn deploy_registry(stela_contract: ContractAddress) -> (ContractAddress, IMockRegistryDispatcher) {
    let contract = declare("MockRegistry").unwrap().contract_class();
    let calldata: Array<felt252> = array![];
    let (address, _) = contract.deploy(@calldata).unwrap();
    let dispatcher = IMockRegistryDispatcher { contract_address: address };
    dispatcher.set_stela_contract(stela_contract);
    (address, dispatcher)
}

fn create_erc20_asset(token: ContractAddress, value: u256) -> Asset {
    Asset { asset: token, asset_type: AssetType::ERC20, value, token_id: 0 }
}

/// Deploy full setup with MockAccounts for fill_signed_order tests.
#[feature("deprecated-starknet-consts")]
fn deploy_fill_setup() -> FillSetup {
    let (debt_token_address, debt_token) = deploy_erc20("Debt Token", "DEBT");
    let (collateral_token_address, collateral_token) = deploy_erc20("Collateral Token", "COL");
    let (interest_token_address, interest_token) = deploy_erc20("Interest Token", "INT");
    let (nft_address, _nft) = deploy_erc721("Inscriptions NFT", "AGREE");

    let locker_class = declare("LockerAccount").unwrap().contract_class();
    let locker_class_hash: felt252 = (*locker_class.class_hash).into();

    let stela_contract = declare("StelaProtocol").unwrap().contract_class();
    let mut stela_calldata: Array<felt252> = array![];
    OWNER().serialize(ref stela_calldata);
    nft_address.serialize(ref stela_calldata);
    OWNER().serialize(ref stela_calldata); // placeholder registry
    stela_calldata.append(locker_class_hash);
    let (stela_address, _) = stela_contract.deploy(@stela_calldata).unwrap();
    let stela = IStelaProtocolDispatcher { contract_address: stela_address };

    let (registry_address, _registry) = deploy_registry(stela_address);
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_registry(registry_address);
    stop_cheat_caller_address(stela_address);

    // Deploy MockAccounts for maker and takers (ISRC6 always validates)
    let account_class = declare("MockAccount").unwrap().contract_class();
    let (maker_account, _) = account_class.deploy(@array![]).unwrap();
    let (taker_account, _) = account_class.deploy(@array![]).unwrap();
    let (taker2_account, _) = account_class.deploy(@array![]).unwrap();

    FillSetup {
        stela_address,
        stela,
        debt_token_address,
        debt_token,
        collateral_token_address,
        collateral_token,
        interest_token_address,
        interest_token,
        nft_address,
        registry_address,
        maker_account,
        taker_account,
        taker2_account,
    }
}

/// Create an inscription using the maker_account as borrower. Returns the inscription_id.
/// The maker creates a borrowing inscription, then the taker fills via fill_signed_order.
#[feature("deprecated-starknet-consts")]
fn create_inscription_for_fill(
    setup: @FillSetup, debt_amount: u256, collateral_amount: u256, interest_amount: u256,
    duration: u64, deadline: u64, multi_lender: bool,
) -> u256 {
    use stela::types::inscription::InscriptionParams;

    // Fund borrower (maker) with collateral
    (*setup.collateral_token).mint(*setup.maker_account, collateral_amount);
    start_cheat_caller_address(*setup.collateral_token_address, *setup.maker_account);
    (*setup.collateral_token).approve(*setup.stela_address, collateral_amount);
    stop_cheat_caller_address(*setup.collateral_token_address);

    // Create inscription as maker
    start_cheat_caller_address(*setup.stela_address, *setup.maker_account);
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(*setup.debt_token_address, debt_amount)],
        interest_assets: array![create_erc20_asset(*setup.interest_token_address, interest_amount)],
        collateral_assets: array![create_erc20_asset(*setup.collateral_token_address, collateral_amount)],
        duration,
        deadline,
        multi_lender,
    };
    let inscription_id = (*setup.stela).create_inscription(params);
    stop_cheat_caller_address(*setup.stela_address);

    inscription_id
}

/// Fund taker with debt tokens and approve stela.
fn setup_taker_with_debt(setup: @FillSetup, taker: ContractAddress, amount: u256) {
    (*setup.debt_token).mint(taker, amount);
    start_cheat_caller_address(*setup.debt_token_address, taker);
    (*setup.debt_token).approve(*setup.stela_address, amount);
    stop_cheat_caller_address(*setup.debt_token_address);
}

/// Create a basic SignedOrder struct for testing.
fn create_signed_order(
    maker: ContractAddress, inscription_id: u256, bps: u256, deadline: u64, nonce: felt252, min_fill_bps: u256,
) -> SignedOrder {
    let zero_address: ContractAddress = Zero::zero();
    SignedOrder {
        maker,
        allowed_taker: zero_address,
        inscription_id,
        bps,
        deadline,
        nonce,
        min_fill_bps,
    }
}

fn get_shares(stela_address: ContractAddress, account: ContractAddress, token_id: u256) -> u256 {
    let erc1155 = IERC1155Dispatcher { contract_address: stela_address };
    erc1155.balance_of(account, token_id)
}

// ============================================================
//              FILL SIGNED ORDER: HAPPY PATHS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_fill_signed_order_single_fill() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    // Fund taker
    setup_taker_with_debt(@setup, setup.taker_account, 1000);

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Taker fills 100%
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], MAX_BPS);
    stop_cheat_caller_address(setup.stela_address);

    // Verify inscription filled
    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.issued_debt_percentage == MAX_BPS, '100% filled');

    // Verify taker got shares
    let taker_shares = get_shares(setup.stela_address, setup.taker_account, inscription_id);
    assert(taker_shares > 0, 'taker has shares');

    // Verify order registered on-chain
    let order_hash = order.hash_struct();
    assert(setup.stela.is_order_registered(order_hash), 'order registered');

    // Verify filled bps tracked
    assert(setup.stela.get_filled_bps(order_hash) == MAX_BPS, 'filled bps tracked');

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_fill_signed_order_partial_fill() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 10000, 5000, 1000, 86400, 2000, true,
    );

    // Fund taker with partial amount
    setup_taker_with_debt(@setup, setup.taker_account, 6000);

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Taker fills 60%
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], 6000);
    stop_cheat_caller_address(setup.stela_address);

    // Verify partial fill
    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.issued_debt_percentage == 6000, '60% filled');

    let order_hash = order.hash_struct();
    assert(setup.stela.get_filled_bps(order_hash) == 6000, 'filled 6000 bps');

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_fill_signed_order_two_fills_exact() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 10000, 5000, 1000, 86400, 2000, true,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Taker 1 fills 60%
    setup_taker_with_debt(@setup, setup.taker_account, 6000);
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], 6000);
    stop_cheat_caller_address(setup.stela_address);

    // Taker 2 fills remaining 40%
    setup_taker_with_debt(@setup, setup.taker2_account, 4000);
    start_cheat_caller_address(setup.stela_address, setup.taker2_account);
    setup.stela.fill_signed_order(order, array![], 4000); // No sig needed, already registered
    stop_cheat_caller_address(setup.stela_address);

    // Verify 100% filled
    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.issued_debt_percentage == MAX_BPS, '100% filled');

    let order_hash = order.hash_struct();
    assert(setup.stela.get_filled_bps(order_hash) == MAX_BPS, 'filled 10000 bps');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//              FILL SIGNED ORDER: NEGATIVE PATHS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: self trade')]
fn test_fill_signed_order_self_trade() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Maker tries to fill own order
    setup_taker_with_debt(@setup, setup.maker_account, 1000);
    start_cheat_caller_address(setup.stela_address, setup.maker_account);
    setup.stela.fill_signed_order(order, array![0x1], MAX_BPS);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: unauthorized taker')]
fn test_fill_signed_order_private_taker_restriction() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    // Order restricted to taker_account
    let order = SignedOrder {
        maker: setup.maker_account,
        allowed_taker: setup.taker_account,
        inscription_id,
        bps: MAX_BPS,
        deadline: 2000,
        nonce: 0,
        min_fill_bps: 0,
    };

    // taker2 tries to fill — should fail
    setup_taker_with_debt(@setup, setup.taker2_account, 1000);
    start_cheat_caller_address(setup.stela_address, setup.taker2_account);
    setup.stela.fill_signed_order(order, array![0x1], MAX_BPS);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: order expired')]
fn test_fill_signed_order_expired() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 1500, 0, 0);

    // Advance past order deadline
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(1501);

    setup_taker_with_debt(@setup, setup.taker_account, 1000);
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], MAX_BPS);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid nonce')]
fn test_fill_signed_order_nonce_invalidated() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    // Maker cancels all orders by setting min_nonce to 5
    start_cheat_caller_address(setup.stela_address, setup.maker_account);
    setup.stela.cancel_orders_by_nonce(5);
    stop_cheat_caller_address(setup.stela_address);

    // Try fill with nonce 0 (below min nonce 5)
    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    setup_taker_with_debt(@setup, setup.taker_account, 1000);
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], MAX_BPS);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: order cancelled')]
fn test_fill_signed_order_cancelled() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Maker cancels this specific order
    start_cheat_caller_address(setup.stela_address, setup.maker_account);
    setup.stela.cancel_order(order);
    stop_cheat_caller_address(setup.stela_address);

    // Try fill — should fail
    setup_taker_with_debt(@setup, setup.taker_account, 1000);
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], MAX_BPS);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: min fill not met')]
fn test_fill_signed_order_min_fill_not_met() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 10000, 5000, 1000, 86400, 2000, true,
    );

    // Order with min_fill_bps = 5000 (50%)
    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 5000);

    // Try fill with only 3000 bps (below min)
    setup_taker_with_debt(@setup, setup.taker_account, 3000);
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], 3000);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: overfill')]
fn test_fill_signed_order_overfill() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 10000, 5000, 1000, 86400, 2000, true,
    );

    // Order allows max 6000 bps
    let order = create_signed_order(setup.maker_account, inscription_id, 6000, 2000, 0, 0);

    // First fill: 4000 bps
    setup_taker_with_debt(@setup, setup.taker_account, 4000);
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], 4000);
    stop_cheat_caller_address(setup.stela_address);

    // Second fill: 3000 bps (would exceed 6000 total)
    setup_taker_with_debt(@setup, setup.taker2_account, 3000);
    start_cheat_caller_address(setup.stela_address, setup.taker2_account);
    setup.stela.fill_signed_order(order, array![], 3000); // 4000 + 3000 > 6000
}

/// Verify that subsequent fills after registration skip signature verification.
#[test]
#[feature("deprecated-starknet-consts")]
fn test_fill_signed_order_subsequent_fill_no_sig() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 10000, 5000, 1000, 86400, 2000, true,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // First fill: registers order (needs valid sig)
    setup_taker_with_debt(@setup, setup.taker_account, 6000);
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.fill_signed_order(order, array![0x1], 6000);
    stop_cheat_caller_address(setup.stela_address);

    assert(setup.stela.is_order_registered(order.hash_struct()), 'order registered');

    // Second fill: empty signature works (already registered)
    setup_taker_with_debt(@setup, setup.taker2_account, 4000);
    start_cheat_caller_address(setup.stela_address, setup.taker2_account);
    setup.stela.fill_signed_order(order, array![], 4000);
    stop_cheat_caller_address(setup.stela_address);

    // Verify 100%
    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.issued_debt_percentage == MAX_BPS, '100% filled');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//              CANCEL ORDER TESTS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_cancel_order_happy_path() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Maker cancels
    start_cheat_caller_address(setup.stela_address, setup.maker_account);
    setup.stela.cancel_order(order);
    stop_cheat_caller_address(setup.stela_address);

    let order_hash = order.hash_struct();
    assert(setup.stela.is_order_cancelled(order_hash), 'order cancelled');

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: unauthorized')]
fn test_cancel_order_not_maker() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Non-maker tries to cancel
    start_cheat_caller_address(setup.stela_address, setup.taker_account);
    setup.stela.cancel_order(order);
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_cancel_order_already_cancelled() {
    let setup = deploy_fill_setup();

    start_cheat_block_timestamp_global(1000);

    let inscription_id = create_inscription_for_fill(
        @setup, 1000, 500, 100, 86400, 2000, false,
    );

    let order = create_signed_order(setup.maker_account, inscription_id, MAX_BPS, 2000, 0, 0);

    // Cancel twice — second cancel should succeed (idempotent write)
    start_cheat_caller_address(setup.stela_address, setup.maker_account);
    setup.stela.cancel_order(order);
    setup.stela.cancel_order(order); // No panic — just writes true again
    stop_cheat_caller_address(setup.stela_address);

    let order_hash = order.hash_struct();
    assert(setup.stela.is_order_cancelled(order_hash), 'still cancelled');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//              CANCEL ORDERS BY NONCE TESTS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_cancel_orders_by_nonce_happy_path() {
    let setup = deploy_fill_setup();

    start_cheat_caller_address(setup.stela_address, setup.maker_account);

    // Increase min nonce to 5
    setup.stela.cancel_orders_by_nonce(5);

    let min_nonce = setup.stela.get_maker_min_nonce(setup.maker_account);
    assert(min_nonce == 5, 'min nonce is 5');

    // Can increase again
    setup.stela.cancel_orders_by_nonce(10);
    let min_nonce2 = setup.stela.get_maker_min_nonce(setup.maker_account);
    assert(min_nonce2 == 10, 'min nonce is 10');

    stop_cheat_caller_address(setup.stela_address);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid nonce')]
fn test_cancel_orders_by_nonce_not_increasing() {
    let setup = deploy_fill_setup();

    start_cheat_caller_address(setup.stela_address, setup.maker_account);

    setup.stela.cancel_orders_by_nonce(5);

    // Try to set same nonce — should fail (must be strictly greater)
    setup.stela.cancel_orders_by_nonce(5);
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid nonce')]
fn test_cancel_orders_by_nonce_decreasing() {
    let setup = deploy_fill_setup();

    start_cheat_caller_address(setup.stela_address, setup.maker_account);

    setup.stela.cancel_orders_by_nonce(10);

    // Try to decrease — should fail
    setup.stela.cancel_orders_by_nonce(3);
}
