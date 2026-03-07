// Tests for batch_settle() functionality.
// Validates batch settlement of multiple orders with a single lender signature.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use openzeppelin_utils::cryptography::snip12::StructHash;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::istela::{IStelaProtocolDispatcher, IStelaProtocolDispatcherTrait};
use stela::snip12::{InscriptionOrder, BatchLendOffer, BatchEntry, hash_assets, hash_batch_entries};
use stela::types::asset::{Asset, AssetType};
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
fn RELAYER() -> ContractAddress {
    starknet::contract_address_const::<'RELAYER'>()
}

#[feature("deprecated-starknet-consts")]
fn TREASURY() -> ContractAddress {
    starknet::contract_address_const::<'TREASURY'>()
}

// ============================================================
//                    TEST SETUP
// ============================================================

#[derive(Drop)]
struct BatchSetup {
    stela_address: ContractAddress,
    stela: IStelaProtocolDispatcher,
    debt_token_address: ContractAddress,
    debt_token: IMockERC20Dispatcher,
    collateral_token_address: ContractAddress,
    collateral_token: IMockERC20Dispatcher,
    interest_token_address: ContractAddress,
    interest_token: IMockERC20Dispatcher,
    borrower1: ContractAddress,
    borrower2: ContractAddress,
    borrower3: ContractAddress,
    lender_account: ContractAddress,
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

/// Compute SNIP-12 message hash for an InscriptionOrder.
fn compute_order_msg_hash(
    stela_address: ContractAddress, order: @InscriptionOrder,
) -> felt252 {
    let struct_hash = order.hash_struct();
    let domain_type_hash = selector!(
        "\"StarknetDomain\"(\"name\":\"shortstring\",\"version\":\"shortstring\",\"chainId\":\"shortstring\",\"revision\":\"shortstring\")"
    );
    let chain_id: felt252 = 0x534e5f5345504f4c4941;

    let domain_hash = PoseidonTrait::new()
        .update_with(domain_type_hash)
        .update_with('Stela')
        .update_with('v1')
        .update_with(chain_id)
        .update_with(1)
        .finalize();

    PoseidonTrait::new()
        .update_with('StarkNet Message')
        .update_with(domain_hash)
        .update_with(*order.borrower)
        .update_with(struct_hash)
        .finalize()
}

#[feature("deprecated-starknet-consts")]
fn deploy_batch_setup() -> BatchSetup {
    let (debt_token_address, debt_token) = deploy_erc20("Debt Token", "DEBT");
    let (collateral_token_address, collateral_token) = deploy_erc20("Collateral Token", "COL");
    let (interest_token_address, interest_token) = deploy_erc20("Interest Token", "INT");
    let (nft_address, _nft) = deploy_erc721("Inscriptions NFT", "AGREE");

    let locker_class = declare("LockerAccount").unwrap().contract_class();
    let locker_class_hash: felt252 = (*locker_class.class_hash).into();

    // Deploy Stela
    let stela_contract = declare("StelaProtocol").unwrap().contract_class();
    let mut stela_calldata: Array<felt252> = array![];
    OWNER().serialize(ref stela_calldata);
    nft_address.serialize(ref stela_calldata);
    TREASURY().serialize(ref stela_calldata); // placeholder registry
    stela_calldata.append(locker_class_hash);
    OWNER().serialize(ref stela_calldata); // pauser
    let (stela_address, _) = stela_contract.deploy(@stela_calldata).unwrap();
    let stela = IStelaProtocolDispatcher { contract_address: stela_address };

    // Registry
    let (registry_address, _registry) = deploy_registry(stela_address);
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_registry(registry_address);
    stop_cheat_caller_address(stela_address);

    // Deploy MockAccounts for borrowers and lender
    let account_class = declare("MockAccount").unwrap().contract_class();
    let (borrower1, _) = account_class.deploy(@array![]).unwrap();
    let (borrower2, _) = account_class.deploy(@array![]).unwrap();
    let (borrower3, _) = account_class.deploy(@array![]).unwrap();
    let (lender_account, _) = account_class.deploy(@array![]).unwrap();

    BatchSetup {
        stela_address,
        stela,
        debt_token_address,
        debt_token,
        collateral_token_address,
        collateral_token,
        interest_token_address,
        interest_token,
        borrower1,
        borrower2,
        borrower3,
        lender_account,
    }
}

/// Fund a borrower with collateral and approve Stela.
fn fund_borrower(setup: @BatchSetup, borrower: ContractAddress, amount: u256) {
    (*setup.collateral_token).mint(borrower, amount);
    start_cheat_caller_address(*setup.collateral_token_address, borrower);
    (*setup.collateral_token).approve(*setup.stela_address, amount);
    stop_cheat_caller_address(*setup.collateral_token_address);
}

/// Fund lender with debt tokens and approve Stela.
fn fund_lender(setup: @BatchSetup, amount: u256) {
    (*setup.debt_token).mint(*setup.lender_account, amount);
    start_cheat_caller_address(*setup.debt_token_address, *setup.lender_account);
    (*setup.debt_token).approve(*setup.stela_address, amount);
    stop_cheat_caller_address(*setup.debt_token_address);
}

/// Build a swap order (duration=0) for a borrower.
fn make_swap_order(
    setup: @BatchSetup, borrower: ContractAddress, debt_amount: u256, collateral_amount: u256, nonce: felt252,
) -> (InscriptionOrder, Array<Asset>, Array<Asset>, Array<Asset>) {
    let debt_assets = array![create_erc20_asset(*setup.debt_token_address, debt_amount)];
    let interest_assets: Array<Asset> = array![];
    let collateral_assets = array![create_erc20_asset(*setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 0,
        collateral_count: 1,
        duration: 0, // swap
        deadline: 2000,
        multi_lender: false,
        nonce,
    };

    (order, debt_assets, interest_assets, collateral_assets)
}

/// Build a lending order (duration > 0) for a borrower.
fn make_lend_order(
    setup: @BatchSetup,
    borrower: ContractAddress,
    debt_amount: u256,
    collateral_amount: u256,
    interest_amount: u256,
    nonce: felt252,
    multi_lender: bool,
) -> (InscriptionOrder, Array<Asset>, Array<Asset>, Array<Asset>) {
    let debt_assets = array![create_erc20_asset(*setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(*setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(*setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400, // 1 day
        deadline: 2000,
        multi_lender,
        nonce,
    };

    (order, debt_assets, interest_assets, collateral_assets)
}

/// Build a BatchLendOffer from orders and bps list.
fn build_batch_offer(
    stela_address: ContractAddress,
    orders: Span<InscriptionOrder>,
    bps_list: Span<u256>,
    lender: ContractAddress,
    start_nonce: felt252,
) -> BatchLendOffer {
    let mut entries: Array<BatchEntry> = array![];
    let mut i: u32 = 0;
    while i < orders.len() {
        let order = *orders.at(i);
        let order_msg_hash = compute_order_msg_hash(stela_address, @order);
        entries.append(BatchEntry { order_hash: order_msg_hash, bps: *bps_list.at(i) });
        i += 1;
    };

    BatchLendOffer {
        batch_hash: hash_batch_entries(entries.span()),
        count: orders.len(),
        lender,
        start_nonce,
    }
}

// ============================================================
//                 HAPPY PATH: 2 SWAP ORDERS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_batch_settle_two_swaps() {
    let setup = deploy_batch_setup();

    // Fund borrowers with collateral
    fund_borrower(@setup, setup.borrower1, 500);
    fund_borrower(@setup, setup.borrower2, 600);

    // Fund lender with total debt (1000 + 2000)
    fund_lender(@setup, 3000);

    // Build two swap orders
    let (order1, debt1, interest1, collateral1) = make_swap_order(@setup, setup.borrower1, 1000, 500, 0);
    let (order2, debt2, interest2, collateral2) = make_swap_order(@setup, setup.borrower2, 2000, 600, 0);

    // Build batch offer
    let orders_arr = array![order1, order2];
    let bps_arr = array![MAX_BPS, MAX_BPS];
    let batch_offer = build_batch_offer(
        setup.stela_address, orders_arr.span(), bps_arr.span(), setup.lender_account, 0,
    );

    // Flat asset arrays: concat order1 + order2 assets
    let debt_flat = array![*debt1.span().at(0), *debt2.span().at(0)];
    let interest_flat: Array<Asset> = array![];
    let collateral_flat = array![*collateral1.span().at(0), *collateral2.span().at(0)];

    let borrower_sigs = array![array![0x1], array![0x1]];

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders_arr,
        debt_flat,
        interest_flat,
        collateral_flat,
        borrower_sigs,
        batch_offer,
        array![0x1],
        bps_arr,
    );

    stop_cheat_caller_address(setup.stela_address);
    stop_cheat_block_timestamp_global();

    // Verify borrowers received debt tokens (minus relayer fee: 5 BPS)
    // borrower1: 1000 - (1000*5/10000=0) = 1000 (truncated to 0 fee)
    // borrower2: 2000 - (2000*5/10000=1) = 1999
    let b1_balance = setup.debt_token.balance_of(setup.borrower1);
    assert(b1_balance == 1000, 'borrower1 got debt');
    let b2_balance = setup.debt_token.balance_of(setup.borrower2);
    assert(b2_balance == 1999, 'borrower2 got debt');

    // Verify lender nonces consumed (0 and 1)
    let lender_nonce = setup.stela.nonces(setup.lender_account);
    assert(lender_nonce == 2, 'lender nonce is 2');
}

// ============================================================
//          HAPPY PATH: 3 ORDERS WITH MIXED BPS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_batch_settle_three_orders_mixed_bps() {
    let setup = deploy_batch_setup();

    // Fund borrowers
    fund_borrower(@setup, setup.borrower1, 500);
    fund_borrower(@setup, setup.borrower2, 600);
    fund_borrower(@setup, setup.borrower3, 700);

    // Fund lender with enough debt
    fund_lender(@setup, 10000);

    // Order 1: swap at MAX_BPS
    let (order1, debt1, _interest1, collateral1) = make_swap_order(@setup, setup.borrower1, 1000, 500, 0);
    // Order 2: swap at MAX_BPS
    let (order2, debt2, _interest2, collateral2) = make_swap_order(@setup, setup.borrower2, 2000, 600, 0);
    // Order 3: multi-lender lending at 5000 BPS (50%)
    let (order3, debt3, interest3, collateral3) = make_lend_order(@setup, setup.borrower3, 4000, 700, 100, 0, true);

    let orders_arr = array![order1, order2, order3];
    let bps_arr: Array<u256> = array![MAX_BPS, MAX_BPS, 5000];
    let batch_offer = build_batch_offer(
        setup.stela_address, orders_arr.span(), bps_arr.span(), setup.lender_account, 0,
    );

    // Flat asset arrays
    let debt_flat = array![*debt1.span().at(0), *debt2.span().at(0), *debt3.span().at(0)];
    let interest_flat = array![*interest3.span().at(0)];
    let collateral_flat = array![*collateral1.span().at(0), *collateral2.span().at(0), *collateral3.span().at(0)];

    let borrower_sigs = array![array![0x1], array![0x1], array![0x1]];

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders_arr,
        debt_flat,
        interest_flat,
        collateral_flat,
        borrower_sigs,
        batch_offer,
        array![0x1],
        bps_arr,
    );

    stop_cheat_caller_address(setup.stela_address);
    stop_cheat_block_timestamp_global();

    // Verify borrowers received correct debt amounts (minus relayer fee: 5 BPS)
    // b1: 1000 - 0 = 1000 (fee truncated)
    // b2: 2000 - 1 = 1999
    // b3: 50% of 4000 = 2000, fee = 2000*5/10000 = 1, net = 1999
    assert(setup.debt_token.balance_of(setup.borrower1) == 1000, 'b1 got 1000');
    assert(setup.debt_token.balance_of(setup.borrower2) == 1999, 'b2 got 1999');
    assert(setup.debt_token.balance_of(setup.borrower3) == 1999, 'b3 got 1999');

    // Lender nonces: 0, 1, 2 consumed
    assert(setup.stela.nonces(setup.lender_account) == 3, 'lender nonce is 3');
}

// ============================================================
//          REVERT: BATCH HASH MISMATCH
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: batch hash mismatch')]
fn test_batch_settle_hash_mismatch() {
    let setup = deploy_batch_setup();

    fund_borrower(@setup, setup.borrower1, 500);
    fund_lender(@setup, 1000);

    let (order1, debt1, interest1, collateral1) = make_swap_order(@setup, setup.borrower1, 1000, 500, 0);

    let orders_arr = array![order1];
    let bps_arr = array![MAX_BPS];

    // Build batch offer with WRONG hash
    let batch_offer = BatchLendOffer {
        batch_hash: 0x1234, // wrong hash
        count: 1,
        lender: setup.lender_account,
        start_nonce: 0,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders_arr,
        debt1,
        interest1,
        collateral1,
        array![array![0x1]],
        batch_offer,
        array![0x1],
        bps_arr,
    );
}

// ============================================================
//          REVERT: INVALID BORROWER SIGNATURE
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: invalid signature')]
fn test_batch_settle_invalid_borrower_sig() {
    let setup = deploy_batch_setup();

    // Deploy a reject account as borrower
    let reject_class = declare("MockRejectAccount").unwrap().contract_class();
    let (bad_borrower, _) = reject_class.deploy(@array![]).unwrap();

    fund_lender(@setup, 1000);

    // Fund bad borrower with collateral
    setup.collateral_token.mint(bad_borrower, 500);
    start_cheat_caller_address(setup.collateral_token_address, bad_borrower);
    setup.collateral_token.approve(setup.stela_address, 500);
    stop_cheat_caller_address(setup.collateral_token_address);

    let (order1, debt1, interest1, collateral1) = make_swap_order(@setup, bad_borrower, 1000, 500, 0);

    let orders_arr = array![order1];
    let bps_arr = array![MAX_BPS];
    let batch_offer = build_batch_offer(
        setup.stela_address, orders_arr.span(), bps_arr.span(), setup.lender_account, 0,
    );

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders_arr,
        debt1,
        interest1,
        collateral1,
        array![array![0x1]],
        batch_offer,
        array![0x1],
        bps_arr,
    );
}

// ============================================================
//          REVERT: BORROWER NONCE STALE
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Nonces: invalid nonce')]
fn test_batch_settle_stale_borrower_nonce() {
    let setup = deploy_batch_setup();

    fund_borrower(@setup, setup.borrower1, 1000);
    fund_lender(@setup, 2000);

    // First, do a single settle to consume borrower1's nonce 0
    let (order_pre, debt_pre, interest_pre, collateral_pre) = make_swap_order(@setup, setup.borrower1, 500, 500, 0);

    // Build single settle to consume nonce 0
    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order_pre);
    let offer_pre = stela::snip12::LendOffer {
        order_hash: order_msg_hash,
        lender: setup.lender_account,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup.stela.settle(order_pre, debt_pre, interest_pre, collateral_pre, array![0x1], offer_pre, array![0x1]);
    stop_cheat_caller_address(setup.stela_address);

    // Now try batch_settle with borrower1 nonce=0 again (stale)
    let (order1, debt1, interest1, collateral1) = make_swap_order(@setup, setup.borrower1, 500, 500, 0);

    let orders_arr = array![order1];
    let bps_arr = array![MAX_BPS];
    let batch_offer = build_batch_offer(
        setup.stela_address, orders_arr.span(), bps_arr.span(), setup.lender_account, 1, // lender nonce starts at 1
    );

    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup.stela.batch_settle(
        orders_arr,
        debt1,
        interest1,
        collateral1,
        array![array![0x1]],
        batch_offer,
        array![0x1],
        bps_arr,
    );
}

// ============================================================
//          REVERT: SELF-TRADE IN ONE ORDER
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
// When borrower == lender, the lender's nonce is consumed first in batch_settle,
// so the borrower's nonce (same address) fails with OZ's nonce error before
// reaching the self-trade check.
#[should_panic(expected: 'Nonces: invalid nonce')]
fn test_batch_settle_self_trade() {
    let setup = deploy_batch_setup();

    fund_lender(@setup, 1000);
    // Fund the lender also as borrower (self-trade)
    setup.collateral_token.mint(setup.lender_account, 500);
    start_cheat_caller_address(setup.collateral_token_address, setup.lender_account);
    setup.collateral_token.approve(setup.stela_address, 500);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Order where borrower == lender
    let (order1, debt1, interest1, collateral1) = make_swap_order(@setup, setup.lender_account, 1000, 500, 0);

    let orders_arr = array![order1];
    let bps_arr = array![MAX_BPS];
    let batch_offer = build_batch_offer(
        setup.stela_address, orders_arr.span(), bps_arr.span(), setup.lender_account, 0,
    );

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders_arr,
        debt1,
        interest1,
        collateral1,
        array![array![0x1]],
        batch_offer,
        array![0x1],
        bps_arr,
    );
}

// ============================================================
//          REVERT: EXCEEDS MAX_BATCH_SIZE
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: batch too large')]
fn test_batch_settle_exceeds_max_size() {
    let setup = deploy_batch_setup();

    // Create 11 orders (exceeds MAX_BATCH_SIZE = 10)
    let mut orders: Array<InscriptionOrder> = array![];
    let mut bps: Array<u256> = array![];
    let mut sigs: Array<Array<felt252>> = array![];

    let account_class = declare("MockAccount").unwrap().contract_class();
    let mut i: u32 = 0;
    while i < 11 {
        let (borrower_i, _) = account_class.deploy(@array![]).unwrap();
        let debt_assets = array![create_erc20_asset(setup.debt_token_address, 100)];
        let interest_assets: Array<Asset> = array![];
        let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, 50)];
        let order = InscriptionOrder {
            borrower: borrower_i,
            debt_hash: hash_assets(debt_assets.span()),
            interest_hash: hash_assets(interest_assets.span()),
            collateral_hash: hash_assets(collateral_assets.span()),
            debt_count: 1,
            interest_count: 0,
            collateral_count: 1,
            duration: 0,
            deadline: 2000,
            multi_lender: false,
            nonce: 0,
        };
        orders.append(order);
        bps.append(MAX_BPS);
        sigs.append(array![0x1]);
        i += 1;
    };

    // batch_offer with count=11
    let batch_offer = BatchLendOffer {
        batch_hash: 0x0, // doesn't matter, will fail before hash check
        count: 11,
        lender: setup.lender_account,
        start_nonce: 0,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders,
        array![],
        array![],
        array![],
        sigs,
        batch_offer,
        array![0x1],
        bps,
    );
}

// ============================================================
//          REVERT: LENDER NONCE MISMATCH
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Nonces: invalid nonce')]
fn test_batch_settle_lender_nonce_mismatch() {
    let setup = deploy_batch_setup();

    fund_borrower(@setup, setup.borrower1, 500);
    fund_lender(@setup, 1000);

    let (order1, debt1, interest1, collateral1) = make_swap_order(@setup, setup.borrower1, 1000, 500, 0);

    let orders_arr = array![order1];
    let bps_arr = array![MAX_BPS];

    // Build batch offer with start_nonce=5 (lender's current nonce is 0)
    let batch_offer = build_batch_offer(
        setup.stela_address, orders_arr.span(), bps_arr.span(), setup.lender_account, 5,
    );

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders_arr,
        debt1,
        interest1,
        collateral1,
        array![array![0x1]],
        batch_offer,
        array![0x1],
        bps_arr,
    );
}

// ============================================================
//          REVERT: LENGTH MISMATCH
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: batch len mismatch')]
fn test_batch_settle_length_mismatch() {
    let setup = deploy_batch_setup();

    let (order1, debt1, interest1, collateral1) = make_swap_order(@setup, setup.borrower1, 1000, 500, 0);

    // 1 order but 2 bps entries
    let orders_arr = array![order1];
    let bps_arr = array![MAX_BPS, MAX_BPS];

    let batch_offer = BatchLendOffer {
        batch_hash: 0x0,
        count: 1,
        lender: setup.lender_account,
        start_nonce: 0,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());

    setup.stela.batch_settle(
        orders_arr,
        debt1,
        interest1,
        collateral1,
        array![array![0x1]],
        batch_offer,
        array![0x1],
        bps_arr,
    );
}
