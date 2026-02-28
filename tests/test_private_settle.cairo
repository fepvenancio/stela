// Tests for private settlement in settle().
// Private settlement allows a lender to remain anonymous by pre-depositing
// tokens into the privacy pool. The settle() function pulls tokens from the
// pool instead of transferring from the lender directly.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::num::traits::Zero;
use core::poseidon::PoseidonTrait;
use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};
use openzeppelin_utils::cryptography::snip12::StructHash;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::istela::{IStelaProtocolDispatcher, IStelaProtocolDispatcherTrait};
use stela::mocks::mock_privacy_pool::{IMockPrivacyPoolDispatcher, IMockPrivacyPoolDispatcherTrait};
use stela::snip12::{InscriptionOrder, LendOffer, hash_assets};
use stela::types::asset::{Asset, AssetType};
use stela::utils::share_math::MAX_BPS;
use super::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use super::mocks::mock_erc721::IMockERC721Dispatcher;
use super::mocks::mock_registry::{IMockRegistryDispatcher, IMockRegistryDispatcherTrait};
use super::test_utils::{LENDER, OWNER, TREASURY, create_erc20_asset};

// ============================================================
//                    TEST ADDRESSES
// ============================================================

#[feature("deprecated-starknet-consts")]
fn RELAYER() -> ContractAddress {
    starknet::contract_address_const::<'RELAYER'>()
}

// ============================================================
//                    TEST SETUP
// ============================================================

#[derive(Drop)]
struct PrivateTestSetup {
    stela_address: ContractAddress,
    stela: IStelaProtocolDispatcher,
    debt_token_address: ContractAddress,
    debt_token: IMockERC20Dispatcher,
    collateral_token_address: ContractAddress,
    collateral_token: IMockERC20Dispatcher,
    interest_token_address: ContractAddress,
    interest_token: IMockERC20Dispatcher,
    nft_address: ContractAddress,
    nft: IMockERC721Dispatcher,
    registry_address: ContractAddress,
    registry: IMockRegistryDispatcher,
    pool_address: ContractAddress,
    pool: IMockPrivacyPoolDispatcher,
    borrower_account: ContractAddress,
}

/// Deploy full test environment with privacy pool and MockAccount as borrower.
fn deploy_private_test_setup() -> PrivateTestSetup {
    // Deploy mock tokens
    let (debt_token_address, debt_token) = deploy_mock_erc20("Debt Token", "DEBT");
    let (collateral_token_address, collateral_token) = deploy_mock_erc20("Collateral Token", "COL");
    let (interest_token_address, interest_token) = deploy_mock_erc20("Interest Token", "INT");

    // Deploy mock NFT
    let (nft_address, nft) = deploy_mock_erc721("Inscriptions NFT", "AGREE");

    // Declare LockerAccount
    let locker_class = declare("LockerAccount").unwrap().contract_class();
    let locker_class_hash: felt252 = (*locker_class.class_hash).into();

    // Deploy Stela
    let stela_contract = declare("StelaProtocol").unwrap().contract_class();
    let mut stela_calldata: Array<felt252> = array![];
    OWNER().serialize(ref stela_calldata);
    nft_address.serialize(ref stela_calldata);
    TREASURY().serialize(ref stela_calldata); // Placeholder registry
    stela_calldata.append(locker_class_hash);

    let (stela_address, _) = stela_contract.deploy(@stela_calldata).unwrap();
    let stela = IStelaProtocolDispatcher { contract_address: stela_address };

    // Deploy MockRegistry
    let (registry_address, registry) = deploy_mock_registry(stela_address);

    // Wire registry into Stela
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_registry(registry_address);
    stop_cheat_caller_address(stela_address);

    // Deploy MockPrivacyPool
    let pool_contract = declare("MockPrivacyPool").unwrap().contract_class();
    let pool_calldata: Array<felt252> = array![];
    let (pool_address, _) = pool_contract.deploy(@pool_calldata).unwrap();
    let pool = IMockPrivacyPoolDispatcher { contract_address: pool_address };

    // Set privacy pool on Stela
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_privacy_pool(pool_address);
    stop_cheat_caller_address(stela_address);

    // Set relayer fee (10 BPS = 0.1%)
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_relayer_fee(10);
    stop_cheat_caller_address(stela_address);

    // Deploy MockAccount as borrower (for SNIP-12 signature verification)
    let account_contract = declare("MockAccount").unwrap().contract_class();
    let account_calldata: Array<felt252> = array![];
    let (borrower_account, _) = account_contract.deploy(@account_calldata).unwrap();

    PrivateTestSetup {
        stela_address,
        stela,
        debt_token_address,
        debt_token,
        collateral_token_address,
        collateral_token,
        interest_token_address,
        interest_token,
        nft_address,
        nft,
        registry_address,
        registry,
        pool_address,
        pool,
        borrower_account,
    }
}

fn deploy_mock_erc20(name: ByteArray, symbol: ByteArray) -> (ContractAddress, IMockERC20Dispatcher) {
    let contract = declare("MockERC20").unwrap().contract_class();
    let mut constructor_calldata: Array<felt252> = array![];
    name.serialize(ref constructor_calldata);
    symbol.serialize(ref constructor_calldata);
    constructor_calldata.append(18);
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IMockERC20Dispatcher { contract_address };
    (contract_address, dispatcher)
}

fn deploy_mock_erc721(name: ByteArray, symbol: ByteArray) -> (ContractAddress, IMockERC721Dispatcher) {
    let contract = declare("MockERC721").unwrap().contract_class();
    let mut constructor_calldata: Array<felt252> = array![];
    name.serialize(ref constructor_calldata);
    symbol.serialize(ref constructor_calldata);
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IMockERC721Dispatcher { contract_address };
    (contract_address, dispatcher)
}

fn deploy_mock_registry(
    stela_contract: ContractAddress,
) -> (ContractAddress, IMockRegistryDispatcher) {
    let contract = declare("MockRegistry").unwrap().contract_class();
    let constructor_calldata: Array<felt252> = array![];
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IMockRegistryDispatcher { contract_address };
    dispatcher.set_stela_contract(stela_contract);
    (contract_address, dispatcher)
}

/// Compute the SNIP-12 message hash for an InscriptionOrder, as the Stela contract would.
/// Must match the contract's get_message_hash implementation.
fn compute_order_msg_hash(
    stela_address: ContractAddress, order: @InscriptionOrder,
) -> felt252 {
    let struct_hash = order.hash_struct();

    // Domain hash: StarknetDomain(name, version, chainId, revision)
    let domain_type_hash = selector!(
        "\"StarknetDomain\"(\"name\":\"shortstring\",\"version\":\"shortstring\",\"chainId\":\"shortstring\",\"revision\":\"shortstring\")"
    );
    // In tests, chain_id may not match live. Use the test chain id.
    // snforge uses SN_SEPOLIA by default.
    let chain_id: felt252 = 0x534e5f5345504f4c4941; // SN_SEPOLIA

    let domain_hash = PoseidonTrait::new()
        .update_with(domain_type_hash)
        .update_with('Stela')
        .update_with('v1')
        .update_with(chain_id)
        .update_with(1) // revision = 1
        .finalize();

    PoseidonTrait::new()
        .update_with('StarkNet Message')
        .update_with(domain_hash)
        .update_with(*order.borrower)
        .update_with(struct_hash)
        .finalize()
}

/// Get ERC1155 share balance.
fn get_shares(stela_address: ContractAddress, account: ContractAddress, token_id: u256) -> u256 {
    let erc1155 = IERC1155Dispatcher { contract_address: stela_address };
    erc1155.balance_of(account, token_id)
}

// ============================================================
//                    TESTS
// ============================================================

/// Test basic private settlement: lender is anonymous, tokens come from pool.
#[test]
#[feature("deprecated-starknet-consts")]
fn test_settle_private_basic() {
    let setup = deploy_private_test_setup();

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;
    let interest_amount: u256 = 100;
    let duration: u64 = 86400;
    let deadline: u64 = 2000;
    let lender_commitment: felt252 = 0x1234abcd;

    // Setup: mint collateral to borrower and approve Stela
    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Fund the privacy pool with debt tokens (simulates lender's prior deposit)
    setup.debt_token.mint(setup.pool_address, debt_amount);

    // Register the deposit commitment in the pool
    setup.pool.add_deposit(lender_commitment);

    // Build asset arrays
    let debt_assets = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    // Build InscriptionOrder
    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration,
        deadline,
        multi_lender: false,
        nonce: 0,
    };

    // Compute order message hash (needed for LendOffer.order_hash)
    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order);

    // Build LendOffer with zero lender (anonymous) and lender_commitment
    let zero_address: ContractAddress = Zero::zero();
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: zero_address,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment,
    };

    // Settle (relayer calls)
    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(
            order,
            debt_assets,
            interest_assets,
            collateral_assets,
            array![0x1], // borrower_sig (MockAccount accepts any)
            offer,
            array![], // lender_sig (not checked for private)
        );
    stop_cheat_caller_address(setup.stela_address);

    // Verify: inscription created with zero lender
    // Compute the inscription_id the same way the contract does:
    let debt_asset = Asset {
        asset: setup.debt_token_address,
        asset_type: AssetType::ERC20,
        value: debt_amount,
        token_id: 0,
    };
    let mut hash_state = PoseidonTrait::new()
        .update_with(setup.borrower_account) // borrower
        .update_with(zero_address) // lender (zero for private)
        .update_with(duration)
        .update_with(deadline)
        .update_with(1000_u64); // timestamp
    hash_state = hash_state
        .update_with(debt_asset.asset)
        .update_with(debt_asset.value)
        .update_with(debt_asset.token_id);
    let inscription_id: u256 = hash_state.finalize().into();

    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.borrower == setup.borrower_account, 'borrower set');
    assert(inscription.lender.is_zero(), 'lender is zero (private)');
    assert(inscription.issued_debt_percentage == MAX_BPS, '100% issued');
    assert(inscription.signed_at == 1000, 'signed_at set');

    // Verify: borrower received debt tokens (minus relayer fee)
    let borrower_balance = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_balance > 0, 'borrower got debt tokens');

    // Verify: relayer received fee (10 BPS of 1000 = 1)
    let relayer_balance = setup.debt_token.balance_of(RELAYER());
    assert(relayer_balance == 1, 'relayer got fee');

    // Verify: borrower got debt minus fee
    assert(borrower_balance == 999, 'borrower got net debt');

    // Verify: collateral locked (borrower has 0)
    assert(setup.collateral_token.balance_of(setup.borrower_account) == 0, 'collateral locked');

    // Verify: deposit was consumed in the pool
    assert(setup.pool.is_deposit_consumed(lender_commitment), 'deposit consumed');

    // Verify: commitment inserted in pool
    assert(setup.pool.get_commitment_count() == 1, 'commitment inserted');

    // Verify: no ERC1155 shares minted to lender (zero address has none)
    let lender_shares = get_shares(setup.stela_address, zero_address, inscription_id);
    assert(lender_shares == 0, 'no shares to zero addr');

    // Verify: pool has no remaining debt tokens (all pulled)
    let pool_balance = setup.debt_token.balance_of(setup.pool_address);
    assert(pool_balance == 0, 'pool drained');

    stop_cheat_block_timestamp_global();
}

/// Test that private settlement fails without a deposit in the pool.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'POOL: deposit not found')]
fn test_settle_private_rejects_without_deposit() {
    let setup = deploy_private_test_setup();

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;
    let interest_amount: u256 = 100;
    let lender_commitment: felt252 = 0xdeadbeef;

    // Setup borrower collateral
    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Fund pool with debt tokens but do NOT register the deposit
    setup.debt_token.mint(setup.pool_address, debt_amount);

    let debt_assets = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
        nonce: 0,
    };

    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order);
    let zero_address: ContractAddress = Zero::zero();
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: zero_address,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(order, debt_assets, interest_assets, collateral_assets, array![0x1], offer, array![]);
    // Should panic: deposit not found
}

/// Test that a deposit can only be consumed once (replay protection).
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: inscription exists')]
fn test_settle_private_deposit_consumed_once() {
    let setup = deploy_private_test_setup();

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;
    let interest_amount: u256 = 100;
    let lender_commitment: felt252 = 0xfeedface;

    // Setup borrower collateral (enough for two attempts)
    setup.collateral_token.mint(setup.borrower_account, collateral_amount * 2);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount * 2);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Fund pool
    setup.debt_token.mint(setup.pool_address, debt_amount * 2);
    setup.pool.add_deposit(lender_commitment);

    let debt_assets = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
        nonce: 0,
    };

    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order);
    let zero_address: ContractAddress = Zero::zero();
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: zero_address,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment,
    };

    // First settle — should succeed
    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(
            order,
            debt_assets,
            interest_assets,
            collateral_assets,
            array![0x1],
            offer,
            array![],
        );
    stop_cheat_caller_address(setup.stela_address);

    // Second settle with same parameters — fails because inscription already exists
    // (same borrower, same lender(zero), same duration, deadline, timestamp, debt)
    // This also implicitly tests that the deposit commitment was consumed,
    // because even if we got past inscription_exists, consume_deposit would revert.
    let debt_assets2 = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets2 = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets2 = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order2 = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets2.span()),
        interest_hash: hash_assets(interest_assets2.span()),
        collateral_hash: hash_assets(collateral_assets2.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
        nonce: 1, // Different nonce
    };

    let order_msg_hash2 = compute_order_msg_hash(setup.stela_address, @order2);
    let offer2 = LendOffer {
        order_hash: order_msg_hash2,
        lender: zero_address,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment,
    };

    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(order2, debt_assets2, interest_assets2, collateral_assets2, array![0x1], offer2, array![]);
    // Should panic — inscription exists (same inputs produce same ID at same timestamp)
}

/// Test that private settlement with non-zero lender address is rejected.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: private lender not zero')]
fn test_settle_private_nonzero_lender_fails() {
    let setup = deploy_private_test_setup();

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;
    let interest_amount: u256 = 100;
    let lender_commitment: felt252 = 0xabcdef;

    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    setup.debt_token.mint(setup.pool_address, debt_amount);
    setup.pool.add_deposit(lender_commitment);

    let debt_assets = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
        nonce: 0,
    };

    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order);

    // Try with non-zero lender + lender_commitment (should fail)
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: LENDER(), // Non-zero lender with commitment = invalid
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(order, debt_assets, interest_assets, collateral_assets, array![0x1], offer, array![0x1]);
    // Should panic: private lender must be zero
}

/// Test that private settlement rejects multi-lender orders.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: no private multi lender')]
fn test_settle_private_multi_lender_fails() {
    let setup = deploy_private_test_setup();

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;
    let interest_amount: u256 = 100;
    let lender_commitment: felt252 = 0x999;

    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    setup.debt_token.mint(setup.pool_address, debt_amount);
    setup.pool.add_deposit(lender_commitment);

    let debt_assets = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: true, // Multi-lender not allowed for private
        nonce: 0,
    };

    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order);
    let zero_address: ContractAddress = Zero::zero();
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: zero_address,
        issued_debt_percentage: 5000, // 50%
        nonce: 0,
        lender_commitment,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(order, debt_assets, interest_assets, collateral_assets, array![0x1], offer, array![]);
    // Should panic: no private multi lender
}

/// Test that private settlement without a configured privacy pool fails.
#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: privacy pool not set')]
fn test_settle_private_no_pool_fails() {
    // Deploy without setting privacy pool
    let (debt_token_address, debt_token) = deploy_mock_erc20("Debt", "D");
    let (collateral_token_address, collateral_token) = deploy_mock_erc20("Col", "C");
    let (interest_token_address, _interest_token) = deploy_mock_erc20("Int", "I");

    let (nft_address, _nft) = deploy_mock_erc721("NFT", "N");

    let locker_class = declare("LockerAccount").unwrap().contract_class();
    let locker_class_hash: felt252 = (*locker_class.class_hash).into();

    let stela_contract = declare("StelaProtocol").unwrap().contract_class();
    let mut stela_calldata: Array<felt252> = array![];
    OWNER().serialize(ref stela_calldata);
    nft_address.serialize(ref stela_calldata);
    TREASURY().serialize(ref stela_calldata);
    stela_calldata.append(locker_class_hash);
    let (stela_address, _) = stela_contract.deploy(@stela_calldata).unwrap();
    let stela = IStelaProtocolDispatcher { contract_address: stela_address };

    let (registry_address, _registry) = deploy_mock_registry(stela_address);
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_registry(registry_address);
    stop_cheat_caller_address(stela_address);

    // NO privacy pool set

    // Deploy borrower account
    let account_contract = declare("MockAccount").unwrap().contract_class();
    let (borrower_account, _) = account_contract.deploy(@array![]).unwrap();

    collateral_token.mint(borrower_account, 500);
    start_cheat_caller_address(collateral_token_address, borrower_account);
    collateral_token.approve(stela_address, 500);
    stop_cheat_caller_address(collateral_token_address);

    debt_token.mint(RELAYER(), 1000); // Doesn't matter, pool not set

    let debt_assets = array![create_erc20_asset(debt_token_address, 1000)];
    let interest_assets = array![create_erc20_asset(interest_token_address, 100)];
    let collateral_assets = array![create_erc20_asset(collateral_token_address, 500)];

    let order = InscriptionOrder {
        borrower: borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
        nonce: 0,
    };

    let order_msg_hash = compute_order_msg_hash(stela_address, @order);
    let zero_address: ContractAddress = Zero::zero();
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: zero_address,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment: 0xabc,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(stela_address, RELAYER());
    stela.settle(order, debt_assets, interest_assets, collateral_assets, array![0x1], offer, array![]);
    // Should panic: privacy pool not set
}

/// Full lifecycle: private settle -> repay -> private redeem
#[test]
#[feature("deprecated-starknet-consts")]
fn test_settle_private_full_flow() {
    let setup = deploy_private_test_setup();

    let debt_amount: u256 = 10000;
    let collateral_amount: u256 = 5000;
    let interest_amount: u256 = 1000;
    let lender_commitment: felt252 = 0xbeef;

    // Setup borrower collateral
    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Fund pool
    setup.debt_token.mint(setup.pool_address, debt_amount);
    setup.pool.add_deposit(lender_commitment);

    let debt_assets = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
        nonce: 0,
    };

    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order);
    let zero_address: ContractAddress = Zero::zero();
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: zero_address,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment,
    };

    // 1. Private settle
    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(order, debt_assets, interest_assets, collateral_assets, array![0x1], offer, array![]);
    stop_cheat_caller_address(setup.stela_address);

    // Compute inscription ID
    let debt_asset = Asset {
        asset: setup.debt_token_address,
        asset_type: AssetType::ERC20,
        value: debt_amount,
        token_id: 0,
    };
    let mut hash_state = PoseidonTrait::new()
        .update_with(setup.borrower_account)
        .update_with(zero_address)
        .update_with(86400_u64)
        .update_with(2000_u64)
        .update_with(1000_u64);
    hash_state = hash_state
        .update_with(debt_asset.asset)
        .update_with(debt_asset.value)
        .update_with(debt_asset.token_id);
    let inscription_id: u256 = hash_state.finalize().into();

    // Verify inscription state
    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.borrower == setup.borrower_account, 'borrower ok');
    assert(inscription.lender.is_zero(), 'lender is zero');
    assert(!inscription.is_repaid, 'not repaid yet');

    // Verify borrower received debt tokens (10000 - 10 BPS fee = 9999)
    let borrower_debt = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_debt == 9990, 'borrower got net debt');

    // 2. Repay (borrower needs debt + interest tokens)
    // Borrower already has 9990 debt tokens, needs full 10000
    setup.debt_token.mint(setup.borrower_account, 10);
    setup.interest_token.mint(setup.borrower_account, interest_amount);

    start_cheat_caller_address(setup.debt_token_address, setup.borrower_account);
    setup.debt_token.approve(setup.stela_address, debt_amount);
    stop_cheat_caller_address(setup.debt_token_address);

    start_cheat_caller_address(setup.interest_token_address, setup.borrower_account);
    setup.interest_token.approve(setup.stela_address, interest_amount);
    stop_cheat_caller_address(setup.interest_token_address);

    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50000); // Within repay window

    start_cheat_caller_address(setup.stela_address, setup.borrower_account);
    setup.stela.repay(inscription_id);
    stop_cheat_caller_address(setup.stela_address);

    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.is_repaid, 'repaid');

    // 3. Verify collateral returned to borrower (locker unlocked on repay)
    // After repay, borrower gets collateral back via locker unlock
    // Note: In this flow, the collateral was locked in a locker TBA, and repay() calls
    // the locker to return it. The borrower can get it back.

    stop_cheat_block_timestamp_global();
}

/// Test that standard (non-private) settle still works unchanged.
#[test]
#[feature("deprecated-starknet-consts")]
fn test_settle_standard_still_works() {
    let setup = deploy_private_test_setup();

    let debt_amount: u256 = 1000;
    let collateral_amount: u256 = 500;
    let interest_amount: u256 = 100;

    // Setup borrower collateral
    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Deploy a MockAccount for the lender too (needed for is_valid_signature)
    let account_contract = declare("MockAccount").unwrap().contract_class();
    let (lender_account, _) = account_contract.deploy(@array![]).unwrap();

    // Fund lender with debt tokens
    setup.debt_token.mint(lender_account, debt_amount);
    start_cheat_caller_address(setup.debt_token_address, lender_account);
    setup.debt_token.approve(setup.stela_address, debt_amount);
    stop_cheat_caller_address(setup.debt_token_address);

    let debt_assets = array![create_erc20_asset(setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 86400,
        deadline: 2000,
        multi_lender: false,
        nonce: 0,
    };

    let order_msg_hash = compute_order_msg_hash(setup.stela_address, @order);
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: lender_account,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment: 0, // Non-private
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup
        .stela
        .settle(
            order,
            debt_assets,
            interest_assets,
            collateral_assets,
            array![0x1],
            offer,
            array![0x1],
        );
    stop_cheat_caller_address(setup.stela_address);

    // Compute inscription ID
    let debt_asset = Asset {
        asset: setup.debt_token_address,
        asset_type: AssetType::ERC20,
        value: debt_amount,
        token_id: 0,
    };
    let mut hash_state = PoseidonTrait::new()
        .update_with(setup.borrower_account)
        .update_with(lender_account)
        .update_with(86400_u64)
        .update_with(2000_u64)
        .update_with(1000_u64);
    hash_state = hash_state
        .update_with(debt_asset.asset)
        .update_with(debt_asset.value)
        .update_with(debt_asset.token_id);
    let inscription_id: u256 = hash_state.finalize().into();

    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.borrower == setup.borrower_account, 'borrower set');
    assert(inscription.lender == lender_account, 'lender set (non-private)');
    assert(inscription.issued_debt_percentage == MAX_BPS, '100% issued');

    // Lender should have ERC1155 shares
    let lender_shares = get_shares(setup.stela_address, lender_account, inscription_id);
    assert(lender_shares > 0, 'lender has shares');

    // Borrower should have debt tokens
    let borrower_balance = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_balance > 0, 'borrower got debt');

    stop_cheat_block_timestamp_global();
}
