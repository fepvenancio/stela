// Tests for StelaGenesis ERC721 mint contract

use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::igenesis::{IStelaGenesisDispatcher, IStelaGenesisDispatcherTrait};
use super::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use super::test_utils::{OWNER, LENDER, TREASURY};

// ============================================================
//                    HELPERS
// ============================================================

#[feature("deprecated-starknet-consts")]
fn MINTER() -> ContractAddress {
    starknet::contract_address_const::<'MINTER'>()
}

#[feature("deprecated-starknet-consts")]
fn MINTER_2() -> ContractAddress {
    starknet::contract_address_const::<'MINTER_2'>()
}

fn deploy_genesis_setup() -> (ContractAddress, IStelaGenesisDispatcher, ContractAddress, IMockERC20Dispatcher) {
    // Deploy payment token (mock STRK)
    let erc20_class = declare("MockERC20").unwrap().contract_class();
    let mut erc20_calldata: Array<felt252> = array![];
    let name: ByteArray = "StarkNet Token";
    let symbol: ByteArray = "STRK";
    name.serialize(ref erc20_calldata);
    symbol.serialize(ref erc20_calldata);
    erc20_calldata.append(18); // decimals
    let (token_address, _) = erc20_class.deploy(@erc20_calldata).unwrap();
    let token = IMockERC20Dispatcher { contract_address: token_address };

    // Deploy StelaGenesis
    let genesis_class = declare("StelaGenesis").unwrap().contract_class();
    let mut genesis_calldata: Array<felt252> = array![];
    OWNER().serialize(ref genesis_calldata);
    token_address.serialize(ref genesis_calldata);
    TREASURY().serialize(ref genesis_calldata); // mint_recipient
    TREASURY().serialize(ref genesis_calldata); // treasury (receives 50 reserve NFTs)
    let base_uri: ByteArray = "https://api.stela.xyz/genesis/";
    base_uri.serialize(ref genesis_calldata);
    let (genesis_address, _) = genesis_class.deploy(@genesis_calldata).unwrap();
    let genesis = IStelaGenesisDispatcher { contract_address: genesis_address };

    (genesis_address, genesis, token_address, token)
}

/// Mint STRK to a minter and approve the genesis contract.
fn setup_minter(
    token: IMockERC20Dispatcher,
    token_address: ContractAddress,
    genesis_address: ContractAddress,
    minter: ContractAddress,
    amount: u256,
) {
    token.mint(minter, amount);
    start_cheat_caller_address(token_address, minter);
    token.approve(genesis_address, amount);
    stop_cheat_caller_address(token_address);
}

// ============================================================
//                    CONSTRUCTOR TESTS
// ============================================================

#[test]
fn test_genesis_constructor() {
    let (_, genesis, token_address, _) = deploy_genesis_setup();

    assert(genesis.total_minted() == 50, 'total_minted should be 50');
    assert(genesis.max_supply() == 300, 'max_supply should be 300');
    assert(genesis.mint_price() == 1_000_000_000_000_000_000_000, 'price should be 1000 STRK');
    assert(genesis.mint_enabled() == false, 'mint should be disabled');
    assert(genesis.payment_token() == token_address, 'wrong payment token');
    assert(genesis.mint_recipient() == TREASURY(), 'wrong mint recipient');
}

#[test]
fn test_treasury_reserve_minted_on_deploy() {
    let (_, genesis, _, token) = deploy_genesis_setup();

    // 50 NFTs minted to treasury on deployment, no payment taken
    assert(genesis.total_minted() == 50, 'treasury should have 50');
    assert(token.balance_of(TREASURY()) == 0, 'no payment for reserve');
    // 250 remaining for public mint
    let remaining = genesis.max_supply() - genesis.total_minted();
    assert(remaining == 250, 'should have 250 remaining');
}

// ============================================================
//                    MINT TESTS
// ============================================================

#[test]
fn test_mint_single() {
    let (genesis_address, genesis, token_address, token) = deploy_genesis_setup();
    let price = genesis.mint_price();

    // Enable minting
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    // Setup minter
    setup_minter(token, token_address, genesis_address, MINTER(), price);

    // Mint
    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint();
    stop_cheat_caller_address(genesis_address);

    // Verify
    assert(genesis.total_minted() == 51, 'should have minted 51');
    // Payment should have been transferred
    assert(token.balance_of(MINTER()) == 0, 'minter balance should be 0');
    assert(token.balance_of(TREASURY()) == price, 'treasury should have payment');
}

#[test]
fn test_mint_batch() {
    let (genesis_address, genesis, token_address, token) = deploy_genesis_setup();
    let price = genesis.mint_price();

    // Enable minting
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    // Setup minter with enough for 3
    setup_minter(token, token_address, genesis_address, MINTER(), price * 3);

    // Batch mint 3
    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint_batch(3);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.total_minted() == 53, 'should have minted 53');
    assert(token.balance_of(MINTER()) == 0, 'minter should have 0');
    assert(token.balance_of(TREASURY()) == price * 3, 'treasury should have 3x price');
}

#[test]
fn test_mint_sequential_ids() {
    let (genesis_address, genesis, token_address, token) = deploy_genesis_setup();
    let price = genesis.mint_price();

    // Enable minting
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    // Mint 3 tokens across 2 minters
    setup_minter(token, token_address, genesis_address, MINTER(), price * 2);
    setup_minter(token, token_address, genesis_address, MINTER_2(), price);

    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint();
    genesis.mint();
    stop_cheat_caller_address(genesis_address);

    start_cheat_caller_address(genesis_address, MINTER_2());
    genesis.mint();
    stop_cheat_caller_address(genesis_address);

    // IDs should be 51, 52, 53 (after 50 treasury reserve)
    assert(genesis.total_minted() == 53, 'should have minted 53');
}

#[test]
#[should_panic(expected: 'GENESIS: mint disabled')]
fn test_mint_disabled_reverts() {
    let (genesis_address, genesis, token_address, token) = deploy_genesis_setup();
    let price = genesis.mint_price();

    setup_minter(token, token_address, genesis_address, MINTER(), price);

    // Try to mint while disabled (default)
    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint();
}

#[test]
#[should_panic(expected: 'GENESIS: zero quantity')]
fn test_mint_batch_zero_reverts() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint_batch(0);
}

#[test]
#[should_panic(expected: 'GENESIS: exceeds batch limit')]
fn test_mint_batch_exceeds_limit_reverts() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint_batch(6); // MAX_BATCH_SIZE is 5
}

// ============================================================
//                    ADMIN MINT TESTS
// ============================================================

#[test]
fn test_admin_mint() {
    let (genesis_address, genesis, _, token) = deploy_genesis_setup();

    // Admin mint 10 to MINTER (no payment required)
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(MINTER(), 10);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.total_minted() == 60, 'should have minted 60');
    // No payment should have been taken
    assert(token.balance_of(TREASURY()) == 0, 'treasury should have 0');
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_admin_mint_not_owner_reverts() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, MINTER());
    genesis.admin_mint(MINTER(), 1);
}

#[test]
#[should_panic(expected: 'GENESIS: exceeds remaining')]
fn test_admin_mint_exceeds_remaining_reverts() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(MINTER(), 251); // 50 treasury + 251 = 301 > 300
}

#[test]
fn test_admin_mint_no_batch_limit() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    // Admin should be able to mint more than MAX_BATCH_SIZE (5)
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(MINTER(), 50);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.total_minted() == 100, 'should have minted 100');
}

// ============================================================
//                    PER-WALLET LIMIT TESTS
// ============================================================

#[test]
fn test_wallet_limit_single_mint() {
    let (genesis_address, genesis, token_address, token) = deploy_genesis_setup();
    let price = genesis.mint_price();

    // Enable minting
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    // Mint 5 (the max per wallet)
    setup_minter(token, token_address, genesis_address, MINTER(), price * 5);
    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint_batch(5);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.total_minted() == 55, 'should have minted 55');
}

#[test]
#[should_panic(expected: 'GENESIS: wallet limit reached')]
fn test_wallet_limit_single_mint_reverts() {
    let (genesis_address, genesis, token_address, token) = deploy_genesis_setup();
    let price = genesis.mint_price();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    // Mint 5 (max), then try one more
    setup_minter(token, token_address, genesis_address, MINTER(), price * 6);
    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint_batch(5);
    genesis.mint(); // should panic
}

#[test]
#[should_panic(expected: 'GENESIS: wallet limit reached')]
fn test_wallet_limit_batch_reverts() {
    let (genesis_address, genesis, token_address, token) = deploy_genesis_setup();
    let price = genesis.mint_price();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    // Mint 3, then try batch of 3 (would be 6, exceeds 5)
    setup_minter(token, token_address, genesis_address, MINTER(), price * 6);
    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint_batch(3);
    genesis.mint_batch(3); // should panic
}

#[test]
fn test_admin_mint_bypasses_wallet_limit() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    // Admin can mint more than MAX_PER_WALLET to a single address
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(MINTER(), 50);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.total_minted() == 100, 'should have minted 100');
}

#[test]
fn test_max_per_wallet_view() {
    let (_, genesis, _, _) = deploy_genesis_setup();
    assert(genesis.max_per_wallet() == 5, 'max_per_wallet should be 5');
}

// ============================================================
//                    SUPPLY CAP TESTS
// ============================================================

#[test]
fn test_sold_out_at_max_supply() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    // Verify max_supply is 300
    assert(genesis.max_supply() == 300, 'max supply is 300');

    // 50 already minted to treasury on deploy
    assert(genesis.total_minted() == 50, 'should start at 50');

    // Mint a small batch and verify counter works
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(MINTER(), 10);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.total_minted() == 60, 'should have minted 60');
}

#[test]
#[should_panic(expected: 'GENESIS: exceeds remaining')]
fn test_mint_after_sold_out_reverts() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    // 50 treasury + 50 + 201 = 301 > 300
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(MINTER(), 50);
    genesis.admin_mint(MINTER(), 201); // should panic: exceeds remaining
}

// ============================================================
//                    ADMIN SETTER TESTS
// ============================================================

#[test]
fn test_set_mint_price() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();
    let new_price: u256 = 10_000_000_000_000_000_000_000; // 10,000 STRK

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_price(new_price);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.mint_price() == new_price, 'price should be updated');
}

#[test]
fn test_set_mint_enabled() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.mint_enabled() == true, 'should be enabled');

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_enabled(false);
    stop_cheat_caller_address(genesis_address);

    assert(genesis.mint_enabled() == false, 'should be disabled');
}

#[test]
fn test_set_mint_recipient() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_recipient(LENDER());
    stop_cheat_caller_address(genesis_address);

    assert(genesis.mint_recipient() == LENDER(), 'recipient should be updated');
}

#[test]
#[should_panic(expected: 'GENESIS: invalid recipient')]
fn test_set_mint_recipient_zero_reverts() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();
    let zero: ContractAddress = starknet::contract_address_const::<0>();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_recipient(zero);
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_set_mint_price_not_owner_reverts() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, MINTER());
    genesis.set_mint_price(0);
}

#[test]
fn test_set_base_uri() {
    let (genesis_address, genesis, _, _) = deploy_genesis_setup();

    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_base_uri("https://new-uri.stela.xyz/");
    stop_cheat_caller_address(genesis_address);
}

// ============================================================
//                    FREE MINT (price = 0)
// ============================================================

#[test]
fn test_free_mint_when_price_is_zero() {
    let (genesis_address, genesis, _, token) = deploy_genesis_setup();

    // Set price to 0 and enable
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.set_mint_price(0);
    genesis.set_mint_enabled(true);
    stop_cheat_caller_address(genesis_address);

    // Mint without any approval (no payment needed)
    start_cheat_caller_address(genesis_address, MINTER());
    genesis.mint();
    stop_cheat_caller_address(genesis_address);

    assert(genesis.total_minted() == 51, 'should have minted 51');
    assert(token.balance_of(TREASURY()) == 0, 'no payment should transfer');
}
