// Tests for Genesis fee split logic in stela.cairo.
// Verifies settle() and redeem() fee routing with and without fee_vault set.
//
// Fee split (with vault):
//   settle: 5 relayer + 20 vault = 25 BPS
//   redeem: 10 vault = 10 BPS
// Without vault (zero address): legacy relayer-only fee.

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
use stela::interfaces::ifee_vault::{IFeeVaultDispatcher, IFeeVaultDispatcherTrait};
use stela::interfaces::igenesis::{IStelaGenesisDispatcher, IStelaGenesisDispatcherTrait};
use stela::interfaces::istela::{IStelaProtocolDispatcher, IStelaProtocolDispatcherTrait};
use stela::mocks::mock_privacy_pool::{IMockPrivacyPoolDispatcher, IMockPrivacyPoolDispatcherTrait};
use stela::snip12::{InscriptionOrder, LendOffer, hash_assets};
use stela::types::asset::{Asset, AssetType};
use stela::utils::share_math::MAX_BPS;
use super::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use super::mocks::mock_erc721::IMockERC721Dispatcher;
use super::mocks::mock_registry::{IMockRegistryDispatcher, IMockRegistryDispatcherTrait};
use super::test_utils::OWNER;

// ============================================================
//                    TEST ADDRESSES
// ============================================================

#[feature("deprecated-starknet-consts")]
fn RELAYER() -> ContractAddress {
    starknet::contract_address_const::<'RELAYER'>()
}

#[feature("deprecated-starknet-consts")]
fn TREASURY() -> ContractAddress {
    starknet::contract_address_const::<'TREASURY'>()
}

#[feature("deprecated-starknet-consts")]
fn HOLDER() -> ContractAddress {
    starknet::contract_address_const::<'HOLDER'>()
}

// ============================================================
//                    TEST SETUP
// ============================================================

#[derive(Drop)]
struct FeeSplitSetup {
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
    vault_address: ContractAddress,
    vault: IFeeVaultDispatcher,
    genesis_address: ContractAddress,
    pool_address: ContractAddress,
    pool: IMockPrivacyPoolDispatcher,
    borrower_account: ContractAddress,
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

/// Deploy full setup including Stela, FeeVault, Genesis, and MockAccounts.
#[feature("deprecated-starknet-consts")]
fn deploy_fee_split_setup() -> FeeSplitSetup {
    // Tokens
    let (debt_token_address, debt_token) = deploy_erc20("Debt Token", "DEBT");
    let (collateral_token_address, collateral_token) = deploy_erc20("Collateral Token", "COL");
    let (interest_token_address, interest_token) = deploy_erc20("Interest Token", "INT");
    let (pay_token_address, _pay_token) = deploy_erc20("Payment Token", "PAY");

    // NFT for inscriptions
    let (nft_address, _nft) = deploy_erc721("Inscriptions NFT", "AGREE");

    // Locker class hash
    let locker_class = declare("LockerAccount").unwrap().contract_class();
    let locker_class_hash: felt252 = (*locker_class.class_hash).into();

    // Deploy Stela
    let stela_contract = declare("StelaProtocol").unwrap().contract_class();
    let mut stela_calldata: Array<felt252> = array![];
    OWNER().serialize(ref stela_calldata);
    nft_address.serialize(ref stela_calldata);
    TREASURY().serialize(ref stela_calldata); // placeholder registry
    stela_calldata.append(locker_class_hash);
    let (stela_address, _) = stela_contract.deploy(@stela_calldata).unwrap();
    let stela = IStelaProtocolDispatcher { contract_address: stela_address };

    // Registry
    let (registry_address, _registry) = deploy_registry(stela_address);
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_registry(registry_address);
    stop_cheat_caller_address(stela_address);

    // Set relayer fee (10 BPS for legacy path)
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_relayer_fee(10);
    stop_cheat_caller_address(stela_address);

    // Set inscription fee to 0 (isolate Genesis fee split from share dilution)
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_inscription_fee(0);
    stop_cheat_caller_address(stela_address);

    // Set treasury
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_treasury(TREASURY());
    stop_cheat_caller_address(stela_address);

    // Deploy StelaGenesis (needed for FeeVault's owner_of checks)
    let genesis_class = declare("StelaGenesis").unwrap().contract_class();
    let mut genesis_calldata: Array<felt252> = array![];
    OWNER().serialize(ref genesis_calldata);
    pay_token_address.serialize(ref genesis_calldata);
    TREASURY().serialize(ref genesis_calldata); // mint_recipient
    TREASURY().serialize(ref genesis_calldata); // treasury (receives 100 reserve NFTs)
    let base_uri: ByteArray = "https://api.stela.xyz/genesis/";
    base_uri.serialize(ref genesis_calldata);
    let (genesis_address, _) = genesis_class.deploy(@genesis_calldata).unwrap();
    let genesis = IStelaGenesisDispatcher { contract_address: genesis_address };

    // Mint a Genesis NFT to HOLDER (token_id = 101, after 100 treasury reserve)
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(HOLDER(), 1);
    stop_cheat_caller_address(genesis_address);

    // Deploy FeeVault
    let vault_class = declare("FeeVault").unwrap().contract_class();
    let mut vault_calldata: Array<felt252> = array![];
    OWNER().serialize(ref vault_calldata);
    genesis_address.serialize(ref vault_calldata);
    let total_nfts: u256 = 500;
    total_nfts.serialize(ref vault_calldata);
    stela_address.serialize(ref vault_calldata); // authorized depositor
    let (vault_address, _) = vault_class.deploy(@vault_calldata).unwrap();
    let vault = IFeeVaultDispatcher { contract_address: vault_address };

    // Pre-register fee tokens on vault (deposit no longer auto-registers)
    start_cheat_caller_address(vault_address, OWNER());
    vault.register_token(debt_token_address);
    vault.register_token(interest_token_address);
    stop_cheat_caller_address(vault_address);

    // Set fee vault on Stela
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_fee_vault(vault_address);
    stop_cheat_caller_address(stela_address);

    // Deploy MockPrivacyPool
    let pool_contract = declare("MockPrivacyPool").unwrap().contract_class();
    let pool_calldata: Array<felt252> = array![];
    let (pool_address, _) = pool_contract.deploy(@pool_calldata).unwrap();
    let pool = IMockPrivacyPoolDispatcher { contract_address: pool_address };

    start_cheat_caller_address(stela_address, OWNER());
    stela.set_privacy_pool(pool_address);
    stop_cheat_caller_address(stela_address);

    // Deploy MockAccounts for borrower + lender (SNIP-12 verification)
    let account_class = declare("MockAccount").unwrap().contract_class();
    let (borrower_account, _) = account_class.deploy(@array![]).unwrap();
    let (lender_account, _) = account_class.deploy(@array![]).unwrap();

    FeeSplitSetup {
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
        vault_address,
        vault,
        genesis_address,
        pool_address,
        pool,
        borrower_account,
        lender_account,
    }
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
    let chain_id: felt252 = 0x534e5f5345504f4c4941; // SN_SEPOLIA

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

/// Compute LendOffer SNIP-12 message hash.
fn compute_offer_msg_hash(
    stela_address: ContractAddress, offer: @LendOffer, lender: ContractAddress,
) -> felt252 {
    let struct_hash = offer.hash_struct();
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
        .update_with(lender)
        .update_with(struct_hash)
        .finalize()
}

fn get_shares(stela_address: ContractAddress, account: ContractAddress, token_id: u256) -> u256 {
    let erc1155 = IERC1155Dispatcher { contract_address: stela_address };
    erc1155.balance_of(account, token_id)
}

/// Execute settle() and return the inscription_id.
/// Handles asset setup, order construction, and settlement.
#[feature("deprecated-starknet-consts")]
fn do_settle(
    setup: @FeeSplitSetup,
    debt_amount: u256,
    collateral_amount: u256,
    interest_amount: u256,
    duration: u64,
    deadline: u64,
    timestamp: u64,
) -> u256 {
    // Fund borrower with collateral and approve
    (*setup.collateral_token).mint(*setup.borrower_account, collateral_amount);
    start_cheat_caller_address(*setup.collateral_token_address, *setup.borrower_account);
    (*setup.collateral_token).approve(*setup.stela_address, collateral_amount);
    stop_cheat_caller_address(*setup.collateral_token_address);

    // Fund lender with debt and approve
    (*setup.debt_token).mint(*setup.lender_account, debt_amount);
    start_cheat_caller_address(*setup.debt_token_address, *setup.lender_account);
    (*setup.debt_token).approve(*setup.stela_address, debt_amount);
    stop_cheat_caller_address(*setup.debt_token_address);

    // Build assets
    let debt_assets = array![create_erc20_asset(*setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(*setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(*setup.collateral_token_address, collateral_amount)];

    // Build order
    let order = InscriptionOrder {
        borrower: *setup.borrower_account,
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

    let order_msg_hash = compute_order_msg_hash(*setup.stela_address, @order);

    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: *setup.lender_account,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment: 0,
    };

    // Settle
    start_cheat_block_timestamp_global(timestamp);
    start_cheat_caller_address(*setup.stela_address, RELAYER());
    (*setup.stela)
        .settle(
            order,
            debt_assets,
            interest_assets,
            collateral_assets,
            array![0x1], // borrower sig (MockAccount accepts any)
            offer,
            array![0x1], // lender sig (MockAccount accepts any)
        );
    stop_cheat_caller_address(*setup.stela_address);

    // Compute inscription_id
    let debt_asset = Asset {
        asset: *setup.debt_token_address,
        asset_type: AssetType::ERC20,
        value: debt_amount,
        token_id: 0,
    };
    let lender = *setup.lender_account;
    let borrower = *setup.borrower_account;
    let mut hash_state = PoseidonTrait::new()
        .update_with(borrower)
        .update_with(lender)
        .update_with(duration)
        .update_with(deadline)
        .update_with(timestamp);
    hash_state = hash_state
        .update_with(debt_asset.asset)
        .update_with(debt_asset.value)
        .update_with(debt_asset.token_id);
    let inscription_id: u256 = hash_state.finalize().into();

    inscription_id
}

// ============================================================
//   SETTLE WITH VAULT: 2-WAY SPLIT (5 relayer / 20 vault)
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_settle_with_vault_fee_split() {
    let setup = deploy_fee_split_setup();

    let debt_amount: u256 = 100_000; // Large enough for integer division precision
    let collateral_amount: u256 = 50_000;
    let interest_amount: u256 = 10_000;

    let inscription_id = do_settle(
        @setup, debt_amount, collateral_amount, interest_amount, 86400, 2000, 1000,
    );

    // Verify inscription created
    let inscription = setup.stela.get_inscription(inscription_id);
    assert(inscription.issued_debt_percentage == MAX_BPS, '100% issued');

    // Fee calculations (25 BPS total):
    // relayer = 100_000 * 5 / 10_000 = 50
    // vault   = 100_000 * 20 / 10_000 = 200
    // treasury = 100_000 * 0 / 10_000 = 0
    // total_fee = 50 + 200 + 0 = 250
    // borrower net = 100_000 - 250 = 99_750

    let borrower_balance = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_balance == 99_750, 'borrower net 99750');

    let relayer_balance = setup.debt_token.balance_of(RELAYER());
    assert(relayer_balance == 50, 'relayer fee 50');

    let treasury_balance = setup.debt_token.balance_of(TREASURY());
    assert(treasury_balance == 0, 'treasury fee 0');

    // Vault holds the deposited fee
    let vault_balance = setup.debt_token.balance_of(setup.vault_address);
    assert(vault_balance == 200, 'vault fee 200');

    // Vault cumulative_per_nft should be 200 / 500 = 0 (dust: 200)
    // The vault received 200 tokens, cumulative_per_nft = 0 per NFT.
    // But if we deposit enough across multiple settles, it accumulates.
    let cumulative = setup.vault.cumulative_per_nft(setup.debt_token_address);
    assert(cumulative == 0, 'cumulative 0 (200<500 dust)');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   SETTLE WITHOUT VAULT: LEGACY RELAYER-ONLY FEE
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_settle_without_vault_legacy_fee() {
    let setup = deploy_fee_split_setup();

    // Disable vault (set to zero address)
    let zero: ContractAddress = Zero::zero();
    start_cheat_caller_address(setup.stela_address, OWNER());
    setup.stela.set_fee_vault(zero);
    stop_cheat_caller_address(setup.stela_address);

    let debt_amount: u256 = 100_000;
    let collateral_amount: u256 = 50_000;
    let interest_amount: u256 = 10_000;

    let _inscription_id = do_settle(
        @setup, debt_amount, collateral_amount, interest_amount, 86400, 2000, 1000,
    );

    // Legacy: relayer_fee = 10 BPS (set in deploy_fee_split_setup)
    // relayer = 100_000 * 10 / 10_000 = 100
    // borrower net = 100_000 - 100 = 99_900

    let borrower_balance = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_balance == 99_900, 'borrower net 99900');

    let relayer_balance = setup.debt_token.balance_of(RELAYER());
    assert(relayer_balance == 100, 'relayer fee 100');

    // No treasury or vault fees
    let treasury_balance = setup.debt_token.balance_of(TREASURY());
    assert(treasury_balance == 0, 'no treasury fee');

    let vault_balance = setup.debt_token.balance_of(setup.vault_address);
    assert(vault_balance == 0, 'no vault fee');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   REDEEM WITH VAULT: 10 BPS TO VAULT
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_redeem_with_vault_fee_split() {
    let setup = deploy_fee_split_setup();

    let debt_amount: u256 = 100_000;
    let collateral_amount: u256 = 50_000;
    let interest_amount: u256 = 10_000;

    let inscription_id = do_settle(
        @setup, debt_amount, collateral_amount, interest_amount, 86400, 2000, 1000,
    );

    // Repay: borrower needs debt + interest tokens
    setup.debt_token.mint(setup.borrower_account, debt_amount);
    setup.interest_token.mint(setup.borrower_account, interest_amount);

    start_cheat_caller_address(setup.debt_token_address, setup.borrower_account);
    setup.debt_token.approve(setup.stela_address, debt_amount);
    stop_cheat_caller_address(setup.debt_token_address);

    start_cheat_caller_address(setup.interest_token_address, setup.borrower_account);
    setup.interest_token.approve(setup.stela_address, interest_amount);
    stop_cheat_caller_address(setup.interest_token_address);

    // Advance time within repay window
    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50_000);

    start_cheat_caller_address(setup.stela_address, setup.borrower_account);
    setup.stela.repay(inscription_id);
    stop_cheat_caller_address(setup.stela_address);

    // Record balances before redeem
    let lender_debt_before = setup.debt_token.balance_of(setup.lender_account);
    let lender_interest_before = setup.interest_token.balance_of(setup.lender_account);
    let treasury_before = setup.debt_token.balance_of(TREASURY());

    // Lender redeems all shares
    let lender_shares = get_shares(setup.stela_address, setup.lender_account, inscription_id);
    assert(lender_shares > 0, 'lender has shares');

    start_cheat_caller_address(setup.stela_address, setup.lender_account);
    setup.stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(setup.stela_address);

    // Redeem fee on debt: 100_000 * 10 / 10_000 = 100 (vault), 100_000 * 0 / 10_000 = 0 (treasury)
    // Net debt to lender = 100_000 - 100 - 0 = 99_900
    let lender_debt_after = setup.debt_token.balance_of(setup.lender_account);
    let lender_debt_received = lender_debt_after - lender_debt_before;
    assert(lender_debt_received == 99_900, 'lender debt net 99900');

    // Redeem fee on interest: 10_000 * 10 / 10_000 = 10 (vault), 10_000 * 0 / 10_000 = 0 (treasury)
    // Net interest to lender = 10_000 - 10 - 0 = 9_990
    let lender_interest_after = setup.interest_token.balance_of(setup.lender_account);
    let lender_interest_received = lender_interest_after - lender_interest_before;
    assert(lender_interest_received == 9_990, 'lender interest net 9990');

    // Treasury gets 0 (TREASURY_BPS = 0)
    let treasury_after = setup.debt_token.balance_of(TREASURY());
    let treasury_debt_fee = treasury_after - treasury_before;
    assert(treasury_debt_fee == 0, 'treasury redeem debt fee 0');

    let treasury_interest = setup.interest_token.balance_of(TREASURY());
    assert(treasury_interest == 0, 'treasury redeem interest fee 0');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   REDEEM WITHOUT VAULT: FULL PAYOUT
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_redeem_without_vault_full_payout() {
    let setup = deploy_fee_split_setup();

    // Disable vault
    let zero: ContractAddress = Zero::zero();
    start_cheat_caller_address(setup.stela_address, OWNER());
    setup.stela.set_fee_vault(zero);
    stop_cheat_caller_address(setup.stela_address);

    let debt_amount: u256 = 100_000;
    let collateral_amount: u256 = 50_000;
    let interest_amount: u256 = 10_000;

    let inscription_id = do_settle(
        @setup, debt_amount, collateral_amount, interest_amount, 86400, 2000, 1000,
    );

    // Repay
    setup.debt_token.mint(setup.borrower_account, debt_amount);
    setup.interest_token.mint(setup.borrower_account, interest_amount);
    start_cheat_caller_address(setup.debt_token_address, setup.borrower_account);
    setup.debt_token.approve(setup.stela_address, debt_amount);
    stop_cheat_caller_address(setup.debt_token_address);
    start_cheat_caller_address(setup.interest_token_address, setup.borrower_account);
    setup.interest_token.approve(setup.stela_address, interest_amount);
    stop_cheat_caller_address(setup.interest_token_address);

    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50_000);

    start_cheat_caller_address(setup.stela_address, setup.borrower_account);
    setup.stela.repay(inscription_id);
    stop_cheat_caller_address(setup.stela_address);

    // Lender redeems
    let lender_shares = get_shares(setup.stela_address, setup.lender_account, inscription_id);
    let lender_debt_before = setup.debt_token.balance_of(setup.lender_account);

    start_cheat_caller_address(setup.stela_address, setup.lender_account);
    setup.stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(setup.stela_address);

    // No redeem fee — lender gets full debt amount back
    let lender_debt_after = setup.debt_token.balance_of(setup.lender_account);
    let lender_debt_received = lender_debt_after - lender_debt_before;
    assert(lender_debt_received == debt_amount, 'full debt payout');

    // Interest also full payout
    let lender_interest = setup.interest_token.balance_of(setup.lender_account);
    assert(lender_interest == interest_amount, 'full interest payout');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   PRIVATE SETTLE WITH VAULT: FEE SPLIT WORKS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_private_settle_with_vault_fee_split() {
    let setup = deploy_fee_split_setup();

    let debt_amount: u256 = 100_000;
    let collateral_amount: u256 = 50_000;
    let interest_amount: u256 = 10_000;
    let lender_commitment: felt252 = 0xfee5117;

    // Fund borrower collateral
    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Fund pool with debt
    setup.debt_token.mint(setup.pool_address, debt_amount);

    // Register deposit
    setup.pool.add_deposit(lender_commitment);

    // Build assets and order
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
    setup.stela.settle(
        order, debt_assets, interest_assets, collateral_assets,
        array![0x1], offer, array![],
    );
    stop_cheat_caller_address(setup.stela_address);

    // Fee from pool settle: same 25 BPS split
    // relayer = 100_000 * 5 / 10_000 = 50
    // vault   = 100_000 * 20 / 10_000 = 200
    // treasury = 100_000 * 0 / 10_000 = 0
    // borrower net = 100_000 - 250 = 99_750

    let borrower_balance = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_balance == 99_750, 'private borrower net 99750');

    let relayer_balance = setup.debt_token.balance_of(RELAYER());
    assert(relayer_balance == 50, 'private relayer fee 50');

    let treasury_balance = setup.debt_token.balance_of(TREASURY());
    assert(treasury_balance == 0, 'private treasury fee 0');

    let vault_balance = setup.debt_token.balance_of(setup.vault_address);
    assert(vault_balance == 200, 'private vault fee 200');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   MULTIPLE DEBT ASSETS: FEE APPLIED PER-ASSET
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_settle_multiple_debt_assets() {
    let setup = deploy_fee_split_setup();

    let debt_amount_1: u256 = 100_000;
    let debt_amount_2: u256 = 200_000;
    let collateral_amount: u256 = 150_000;
    let interest_amount: u256 = 10_000;

    // Deploy second debt token
    let (debt2_address, debt2_token) = deploy_erc20("Debt Token 2", "DEBT2");

    // Pre-register second debt token on vault
    start_cheat_caller_address(setup.vault_address, OWNER());
    setup.vault.register_token(debt2_address);
    stop_cheat_caller_address(setup.vault_address);

    // Fund borrower collateral
    setup.collateral_token.mint(setup.borrower_account, collateral_amount);
    start_cheat_caller_address(setup.collateral_token_address, setup.borrower_account);
    setup.collateral_token.approve(setup.stela_address, collateral_amount);
    stop_cheat_caller_address(setup.collateral_token_address);

    // Fund lender with both debt tokens
    setup.debt_token.mint(setup.lender_account, debt_amount_1);
    start_cheat_caller_address(setup.debt_token_address, setup.lender_account);
    setup.debt_token.approve(setup.stela_address, debt_amount_1);
    stop_cheat_caller_address(setup.debt_token_address);

    debt2_token.mint(setup.lender_account, debt_amount_2);
    start_cheat_caller_address(debt2_address, setup.lender_account);
    debt2_token.approve(setup.stela_address, debt_amount_2);
    stop_cheat_caller_address(debt2_address);

    // Build multi-asset arrays
    let debt_assets = array![
        create_erc20_asset(setup.debt_token_address, debt_amount_1),
        create_erc20_asset(debt2_address, debt_amount_2),
    ];
    let interest_assets = array![create_erc20_asset(setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(setup.collateral_token_address, collateral_amount)];

    let order = InscriptionOrder {
        borrower: setup.borrower_account,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 2,
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
        lender: setup.lender_account,
        issued_debt_percentage: MAX_BPS,
        nonce: 0,
        lender_commitment: 0,
    };

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup.stela.settle(
        order, debt_assets, interest_assets, collateral_assets,
        array![0x1], offer, array![0x1],
    );
    stop_cheat_caller_address(setup.stela_address);

    // Asset 1: 100_000
    //   relayer = 50, vault = 200, treasury = 0, borrower_net = 99_750
    // Asset 2: 200_000
    //   relayer = 100, vault = 400, treasury = 0, borrower_net = 199_500
    // Total borrower: 99_750 + 199_500 = 299_250

    let borrower_debt1 = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_debt1 == 99_750, 'borrower debt1 net');

    let borrower_debt2 = debt2_token.balance_of(setup.borrower_account);
    assert(borrower_debt2 == 199_500, 'borrower debt2 net');

    // Relayer total: 50 + 100 = 150 (split across two tokens)
    let relayer_debt1 = setup.debt_token.balance_of(RELAYER());
    assert(relayer_debt1 == 50, 'relayer debt1 fee');

    let relayer_debt2 = debt2_token.balance_of(RELAYER());
    assert(relayer_debt2 == 100, 'relayer debt2 fee');

    // Vault: 200 + 400 = 600
    let vault_debt1 = setup.debt_token.balance_of(setup.vault_address);
    assert(vault_debt1 == 200, 'vault debt1 fee');

    let vault_debt2 = debt2_token.balance_of(setup.vault_address);
    assert(vault_debt2 == 400, 'vault debt2 fee');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   BACKWARDS COMPATIBILITY: vault=zero behaves same as old
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_backwards_compat_vault_zero() {
    let setup = deploy_fee_split_setup();

    // Disable vault
    let zero: ContractAddress = Zero::zero();
    start_cheat_caller_address(setup.stela_address, OWNER());
    setup.stela.set_fee_vault(zero);
    stop_cheat_caller_address(setup.stela_address);

    assert(setup.stela.get_fee_vault() == zero, 'vault disabled');

    let debt_amount: u256 = 10_000;
    let collateral_amount: u256 = 5_000;
    let interest_amount: u256 = 1_000;

    let inscription_id = do_settle(
        @setup, debt_amount, collateral_amount, interest_amount, 86400, 2000, 1000,
    );

    // Legacy relayer fee: 10 BPS -> 10_000 * 10 / 10_000 = 10
    let relayer_balance = setup.debt_token.balance_of(RELAYER());
    assert(relayer_balance == 10, 'legacy relayer 10');

    let borrower_balance = setup.debt_token.balance_of(setup.borrower_account);
    assert(borrower_balance == 9_990, 'legacy borrower 9990');

    // No vault or treasury fees
    let vault_balance = setup.debt_token.balance_of(setup.vault_address);
    assert(vault_balance == 0, 'no vault fee legacy');

    // Treasury gets 0 from settle in legacy mode
    // (Treasury is also OWNER which is the default treasury set in constructor,
    // but we set it explicitly to TREASURY in setup)
    let treasury_balance = setup.debt_token.balance_of(TREASURY());
    assert(treasury_balance == 0, 'no treasury fee legacy');

    // Repay and redeem — should be full payout
    setup.debt_token.mint(setup.borrower_account, debt_amount);
    setup.interest_token.mint(setup.borrower_account, interest_amount);
    start_cheat_caller_address(setup.debt_token_address, setup.borrower_account);
    setup.debt_token.approve(setup.stela_address, debt_amount);
    stop_cheat_caller_address(setup.debt_token_address);
    start_cheat_caller_address(setup.interest_token_address, setup.borrower_account);
    setup.interest_token.approve(setup.stela_address, interest_amount);
    stop_cheat_caller_address(setup.interest_token_address);

    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50_000);

    start_cheat_caller_address(setup.stela_address, setup.borrower_account);
    setup.stela.repay(inscription_id);
    stop_cheat_caller_address(setup.stela_address);

    let lender_shares = get_shares(setup.stela_address, setup.lender_account, inscription_id);
    start_cheat_caller_address(setup.stela_address, setup.lender_account);
    setup.stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(setup.stela_address);

    // Lender should get full amounts (no redeem fee)
    let lender_interest = setup.interest_token.balance_of(setup.lender_account);
    assert(lender_interest == interest_amount, 'lender full interest');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   FULL LIFECYCLE WITH VAULT: SETTLE -> REPAY -> REDEEM -> CLAIM
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_full_lifecycle_with_vault_and_claim() {
    let setup = deploy_fee_split_setup();

    let debt_amount: u256 = 3_000_000; // Large to make vault cumulative > 0
    let collateral_amount: u256 = 1_500_000;
    let interest_amount: u256 = 300_000;

    let inscription_id = do_settle(
        @setup, debt_amount, collateral_amount, interest_amount, 86400, 2000, 1000,
    );

    // Settle vault deposit: 3_000_000 * 20 / 10_000 = 6_000
    // cumulative_per_nft = 6_000 / 500 = 12
    let cumulative = setup.vault.cumulative_per_nft(setup.debt_token_address);
    assert(cumulative == 12, 'cumulative 12 after settle');

    // Repay
    setup.debt_token.mint(setup.borrower_account, debt_amount);
    setup.interest_token.mint(setup.borrower_account, interest_amount);
    start_cheat_caller_address(setup.debt_token_address, setup.borrower_account);
    setup.debt_token.approve(setup.stela_address, debt_amount);
    stop_cheat_caller_address(setup.debt_token_address);
    start_cheat_caller_address(setup.interest_token_address, setup.borrower_account);
    setup.interest_token.approve(setup.stela_address, interest_amount);
    stop_cheat_caller_address(setup.interest_token_address);

    stop_cheat_block_timestamp_global();
    start_cheat_block_timestamp_global(50_000);

    start_cheat_caller_address(setup.stela_address, setup.borrower_account);
    setup.stela.repay(inscription_id);
    stop_cheat_caller_address(setup.stela_address);

    // Redeem
    let lender_shares = get_shares(setup.stela_address, setup.lender_account, inscription_id);
    start_cheat_caller_address(setup.stela_address, setup.lender_account);
    setup.stela.redeem(inscription_id, lender_shares);
    stop_cheat_caller_address(setup.stela_address);

    // Redeem vault deposit for debt: 3_000_000 * 10 / 10_000 = 3_000
    // cumulative_per_nft += 3_000 / 500 = 6  ->  total = 12 + 6 = 18
    let cumulative_after = setup.vault.cumulative_per_nft(setup.debt_token_address);
    assert(cumulative_after == 18, 'cumulative 18 after redeem');

    // Redeem vault deposit for interest: 300_000 * 10 / 10_000 = 300
    // cumulative_per_nft = 300 / 500 = 0 (300 < 500, all dust)
    let cumulative_interest = setup.vault.cumulative_per_nft(setup.interest_token_address);
    assert(cumulative_interest == 0, 'interest cumulative 0 (dust)');

    // NFT holder claims from vault
    let holder_balance_before = setup.debt_token.balance_of(HOLDER());
    start_cheat_caller_address(setup.vault_address, HOLDER());
    setup.vault.claim(101); // token_id = 101 (after 100 treasury reserve)
    stop_cheat_caller_address(setup.vault_address);

    let holder_balance_after = setup.debt_token.balance_of(HOLDER());
    assert(holder_balance_after - holder_balance_before == 18, 'holder claimed 18');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//   ADMIN: SET/GET FEE VAULT
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_set_fee_vault() {
    let setup = deploy_fee_split_setup();

    assert(setup.stela.get_fee_vault() == setup.vault_address, 'vault set correctly');

    let zero: ContractAddress = Zero::zero();
    start_cheat_caller_address(setup.stela_address, OWNER());
    setup.stela.set_fee_vault(zero);
    stop_cheat_caller_address(setup.stela_address);

    assert(setup.stela.get_fee_vault() == zero, 'vault zeroed');
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'Caller is not the owner')]
fn test_set_fee_vault_non_owner() {
    let setup = deploy_fee_split_setup();

    start_cheat_caller_address(setup.stela_address, RELAYER());
    setup.stela.set_fee_vault(RELAYER());
}
