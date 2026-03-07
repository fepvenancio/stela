// Tests for the discount model in stela.cairo.
// Validates _calculate_discount via observable fee amounts in settle().
//
// Discount model:
//   Base: 15% for holding any Genesis NFT
//   Volume: 5% per tier (7 tiers)
//   Multi-NFT: 2% per additional NFT
//   Cap: 50%
//
// Fee structure (all at settle, no redeem fee):
//   Loans: 5 BPS relayer + 20 BPS treasury = 25 BPS (floor: 10 BPS treasury)
//   Swaps: 5 BPS relayer + 10 BPS treasury = 15 BPS (floor: 5 BPS treasury)

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
use stela::interfaces::igenesis::{IStelaGenesisDispatcher, IStelaGenesisDispatcherTrait};
use stela::interfaces::istela::{IStelaProtocolDispatcher, IStelaProtocolDispatcherTrait};
use stela::snip12::{InscriptionOrder, LendOffer, hash_assets};
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
struct DiscountSetup {
    stela_address: ContractAddress,
    stela: IStelaProtocolDispatcher,
    debt_token_address: ContractAddress,
    debt_token: IMockERC20Dispatcher,
    collateral_token_address: ContractAddress,
    collateral_token: IMockERC20Dispatcher,
    interest_token_address: ContractAddress,
    interest_token: IMockERC20Dispatcher,
    genesis_address: ContractAddress,
    genesis: IStelaGenesisDispatcher,
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

fn create_erc20_asset(token: ContractAddress, value: u256) -> Asset {
    Asset { asset: token, asset_type: AssetType::ERC20, value, token_id: 0 }
}

/// Deploy setup for discount tests.
/// Includes Genesis NFT contract configured on Stela.
#[feature("deprecated-starknet-consts")]
fn deploy_discount_setup() -> DiscountSetup {
    let (debt_token_address, debt_token) = deploy_erc20("Debt Token", "DEBT");
    let (collateral_token_address, collateral_token) = deploy_erc20("Collateral Token", "COL");
    let (interest_token_address, interest_token) = deploy_erc20("Interest Token", "INT");
    let (pay_token_address, _pay_token) = deploy_erc20("Payment Token", "PAY");
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

    // Set treasury
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_treasury(TREASURY());
    stop_cheat_caller_address(stela_address);

    // Deploy StelaGenesis
    let genesis_class = declare("StelaGenesis").unwrap().contract_class();
    let mut genesis_calldata: Array<felt252> = array![];
    OWNER().serialize(ref genesis_calldata);
    pay_token_address.serialize(ref genesis_calldata);
    TREASURY().serialize(ref genesis_calldata); // mint_recipient
    TREASURY().serialize(ref genesis_calldata); // treasury
    let base_uri: ByteArray = "https://api.stela.xyz/genesis/";
    base_uri.serialize(ref genesis_calldata);
    let (genesis_address, _) = genesis_class.deploy(@genesis_calldata).unwrap();
    let genesis = IStelaGenesisDispatcher { contract_address: genesis_address };

    // Set genesis contract on Stela
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_genesis_contract(genesis_address);
    stop_cheat_caller_address(stela_address);

    // Whitelist debt token for volume tracking
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_volume_token_whitelisted(debt_token_address, true);
    stop_cheat_caller_address(stela_address);

    // Deploy MockAccounts
    let account_class = declare("MockAccount").unwrap().contract_class();
    let (borrower_account, _) = account_class.deploy(@array![]).unwrap();
    let (lender_account, _) = account_class.deploy(@array![]).unwrap();

    DiscountSetup {
        stela_address,
        stela,
        debt_token_address,
        debt_token,
        collateral_token_address,
        collateral_token,
        interest_token_address,
        interest_token,
        genesis_address,
        genesis,
        borrower_account,
        lender_account,
    }
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

/// Execute settle() and return the borrower's net debt received.
/// This allows us to measure fee deductions (and thus discount effects).
#[feature("deprecated-starknet-consts")]
fn do_settle_and_get_borrower_net(
    setup: @DiscountSetup,
    debt_amount: u256,
    collateral_amount: u256,
    interest_amount: u256,
    duration: u64,
    deadline: u64,
    timestamp: u64,
    nonce: felt252,
) -> u256 {
    // Fund borrower
    (*setup.collateral_token).mint(*setup.borrower_account, collateral_amount);
    start_cheat_caller_address(*setup.collateral_token_address, *setup.borrower_account);
    (*setup.collateral_token).approve(*setup.stela_address, collateral_amount);
    stop_cheat_caller_address(*setup.collateral_token_address);

    // Fund lender
    (*setup.debt_token).mint(*setup.lender_account, debt_amount);
    start_cheat_caller_address(*setup.debt_token_address, *setup.lender_account);
    (*setup.debt_token).approve(*setup.stela_address, debt_amount);
    stop_cheat_caller_address(*setup.debt_token_address);

    let debt_assets = array![create_erc20_asset(*setup.debt_token_address, debt_amount)];
    let interest_assets = array![create_erc20_asset(*setup.interest_token_address, interest_amount)];
    let collateral_assets = array![create_erc20_asset(*setup.collateral_token_address, collateral_amount)];

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
        nonce,
    };

    let order_msg_hash = compute_order_msg_hash(*setup.stela_address, @order);
    let offer = LendOffer {
        order_hash: order_msg_hash,
        lender: *setup.lender_account,
        issued_debt_percentage: MAX_BPS,
        nonce,
    };

    let borrower_before = (*setup.debt_token).balance_of(*setup.borrower_account);

    start_cheat_block_timestamp_global(timestamp);
    start_cheat_caller_address(*setup.stela_address, RELAYER());
    (*setup.stela).settle(
        order, debt_assets, interest_assets, collateral_assets,
        array![0x1], offer, array![0x1],
    );
    stop_cheat_caller_address(*setup.stela_address);

    let borrower_after = (*setup.debt_token).balance_of(*setup.borrower_account);
    borrower_after - borrower_before
}

// ============================================================
//       DISCOUNT: NO NFT = NO DISCOUNT (FULL FEE)
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_discount_zero_nfts() {
    let setup = deploy_discount_setup();

    // Lender has 0 Genesis NFTs -> no discount
    // Settle fee: 5 relayer + 20 treasury = 25 BPS total
    // debt_amount = 100_000
    // relayer = 100_000 * 5 / 10_000 = 50
    // treasury = 100_000 * 20 / 10_000 = 200
    // total fee = 250
    // borrower net = 99_750

    let borrower_net = do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 86400, 2000, 1000, 0,
    );

    assert(borrower_net == 99_750, 'no discount: net 99750');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       DISCOUNT: 1 NFT, 0 VOLUME = 15% DISCOUNT
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_discount_one_nft_zero_volume() {
    let setup = deploy_discount_setup();

    // Mint 1 Genesis NFT to lender
    start_cheat_caller_address(setup.genesis_address, OWNER());
    setup.genesis.admin_mint(setup.lender_account, 1);
    stop_cheat_caller_address(setup.genesis_address);

    // 15% discount on SETTLE_TREASURY_BASE (20 BPS)
    // discounted = 20 - (20 * 15 / 100) = 20 - 3 = 17 BPS (integer math: 300/100=3)
    // Floor is 10 BPS, so treasury = max(17, 10) = 17 BPS
    // relayer = 5 BPS (never discounted)
    // total fee = 5 + 17 = 22 BPS
    // debt 100_000: fee = 100_000 * 22 / 10_000 = 220
    // borrower net = 100_000 - 220 = 99_780

    let borrower_net = do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 86400, 2000, 1000, 0,
    );

    assert(borrower_net == 99_780, '1 nft: net 99780');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       DISCOUNT: 5 NFTs, 0 VOLUME = 23% (15 + 2*4)
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_discount_five_nfts_zero_volume() {
    let setup = deploy_discount_setup();

    // Mint 5 Genesis NFTs to lender
    start_cheat_caller_address(setup.genesis_address, OWNER());
    setup.genesis.admin_mint(setup.lender_account, 5);
    stop_cheat_caller_address(setup.genesis_address);

    // 23% discount: 15 base + 2 * 4 additional = 23%
    // discounted = 20 - (20 * 23 / 100) = 20 - 4 = 16 BPS (460/100=4)
    // Floor 10 BPS, so treasury = max(16, 10) = 16 BPS
    // relayer = 5
    // total = 21 BPS
    // fee = 100_000 * 21 / 10_000 = 210
    // borrower net = 99_790

    let borrower_net = do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 86400, 2000, 1000, 0,
    );

    assert(borrower_net == 99_790, '5 nft: net 99790');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       VOLUME TRACKING: VERIFY VOLUME_SETTLED INCREMENTS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_volume_tracking_on_settle() {
    let setup = deploy_discount_setup();

    // Before settle, volume should be 0
    let volume_before = setup.stela.get_volume_settled(setup.lender_account);
    assert(volume_before == 0, 'volume starts at 0');

    do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 86400, 2000, 1000, 0,
    );

    // After settle of 100_000 debt at 100%, volume should be 100_000
    let volume_after = setup.stela.get_volume_settled(setup.lender_account);
    assert(volume_after == 100_000, 'volume 100_000');

    stop_cheat_block_timestamp_global();
}

// ============================================================
//       SWAP FEE: DURATION=0 USES 10 BPS (5 RELAYER + 5 TREASURY)
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_swap_fee_no_discount() {
    let setup = deploy_discount_setup();

    // Lender has 0 Genesis NFTs -> no discount
    // Swap fee (duration=0): 5 relayer + 10 treasury = 15 BPS total
    // debt_amount = 100_000
    // relayer = 100_000 * 5 / 10_000 = 50
    // treasury = 100_000 * 10 / 10_000 = 100
    // total fee = 150
    // borrower net = 99_850

    let borrower_net = do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 0, 2000, 1000, 0,
    );

    assert(borrower_net == 99_850, 'swap no discount: net 99850');

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_swap_fee_with_one_nft() {
    let setup = deploy_discount_setup();

    // Mint 1 Genesis NFT to lender
    start_cheat_caller_address(setup.genesis_address, OWNER());
    setup.genesis.admin_mint(setup.lender_account, 1);
    stop_cheat_caller_address(setup.genesis_address);

    // 15% discount on SWAP_TREASURY_BASE (10 BPS)
    // discounted = 10 - (10 * 15 / 100) = 10 - 1 = 9 BPS (integer math: 150/100=1)
    // Floor is 5 BPS, so treasury = max(9, 5) = 9 BPS
    // relayer = 5 BPS (never discounted)
    // total fee = 5 + 9 = 14 BPS
    // debt 100_000: fee = 100_000 * 14 / 10_000 = 140
    // borrower net = 100_000 - 140 = 99_860

    let borrower_net = do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 0, 2000, 1000, 0,
    );

    assert(borrower_net == 99_860, 'swap 1nft: net 99860');

    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_swap_fee_vs_lending_fee() {
    let setup = deploy_discount_setup();

    // First: settle a swap (duration=0) — 15 BPS total
    let swap_net = do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 0, 2000, 1000, 0,
    );

    // Second: settle a loan (duration=86400) — 25 BPS total
    let lending_net = do_settle_and_get_borrower_net(
        @setup, 100_000, 50_000, 10_000, 86400, 2000, 1000, 1,
    );

    // Swap should have lower fee (higher net)
    assert(swap_net == 99_850, 'swap net 99850');
    assert(lending_net == 99_750, 'lending net 99750');
    assert(swap_net > lending_net, 'swap fee < lending fee');

    stop_cheat_block_timestamp_global();
}
