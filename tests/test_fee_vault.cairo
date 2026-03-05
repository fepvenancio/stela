// Tests for FeeVault multi-token fee distribution contract

use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::ifee_vault::{IFeeVaultDispatcher, IFeeVaultDispatcherTrait};
use stela::interfaces::igenesis::{IStelaGenesisDispatcher, IStelaGenesisDispatcherTrait};
use super::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use super::test_utils::OWNER;

// ============================================================
//                    HELPERS
// ============================================================

#[feature("deprecated-starknet-consts")]
fn HOLDER_1() -> ContractAddress {
    starknet::contract_address_const::<'HOLDER_1'>()
}

#[feature("deprecated-starknet-consts")]
fn HOLDER_2() -> ContractAddress {
    starknet::contract_address_const::<'HOLDER_2'>()
}

#[feature("deprecated-starknet-consts")]
fn DEPOSITOR() -> ContractAddress {
    starknet::contract_address_const::<'DEPOSITOR'>()
}

#[feature("deprecated-starknet-consts")]
fn TREASURY() -> ContractAddress {
    starknet::contract_address_const::<'TREASURY'>()
}

struct VaultSetup {
    vault_address: ContractAddress,
    vault: IFeeVaultDispatcher,
    genesis_address: ContractAddress,
    genesis: IStelaGenesisDispatcher,
    fee_token_address: ContractAddress,
    fee_token: IMockERC20Dispatcher,
    fee_token_2_address: ContractAddress,
    fee_token_2: IMockERC20Dispatcher,
}

fn deploy_vault_setup() -> VaultSetup {
    // Deploy payment token for genesis
    let erc20_class = declare("MockERC20").unwrap().contract_class();

    let mut pay_calldata: Array<felt252> = array![];
    let name: ByteArray = "StarkNet Token";
    let symbol: ByteArray = "STRK";
    name.serialize(ref pay_calldata);
    symbol.serialize(ref pay_calldata);
    pay_calldata.append(18);
    let (pay_token_address, _) = erc20_class.deploy(@pay_calldata).unwrap();

    // Deploy fee token 1
    let mut ft1_calldata: Array<felt252> = array![];
    let name1: ByteArray = "Fee Token 1";
    let symbol1: ByteArray = "FT1";
    name1.serialize(ref ft1_calldata);
    symbol1.serialize(ref ft1_calldata);
    ft1_calldata.append(18);
    let (fee_token_address, _) = erc20_class.deploy(@ft1_calldata).unwrap();
    let fee_token = IMockERC20Dispatcher { contract_address: fee_token_address };

    // Deploy fee token 2
    let mut ft2_calldata: Array<felt252> = array![];
    let name2: ByteArray = "Fee Token 2";
    let symbol2: ByteArray = "FT2";
    name2.serialize(ref ft2_calldata);
    symbol2.serialize(ref ft2_calldata);
    ft2_calldata.append(18);
    let (fee_token_2_address, _) = erc20_class.deploy(@ft2_calldata).unwrap();
    let fee_token_2 = IMockERC20Dispatcher { contract_address: fee_token_2_address };

    // Deploy StelaGenesis
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

    // Deploy FeeVault
    let vault_class = declare("FeeVault").unwrap().contract_class();
    let mut vault_calldata: Array<felt252> = array![];
    OWNER().serialize(ref vault_calldata);
    genesis_address.serialize(ref vault_calldata);
    let total_nfts: u256 = 500;
    total_nfts.serialize(ref vault_calldata);
    let (vault_address, _) = vault_class.deploy(@vault_calldata).unwrap();
    let vault = IFeeVaultDispatcher { contract_address: vault_address };

    // Admin mint NFTs to holders: HOLDER_1 gets #101, HOLDER_2 gets #102 (1-100 are treasury)
    start_cheat_caller_address(genesis_address, OWNER());
    genesis.admin_mint(HOLDER_1(), 1); // token_id = 101
    genesis.admin_mint(HOLDER_2(), 1); // token_id = 102
    stop_cheat_caller_address(genesis_address);

    VaultSetup {
        vault_address,
        vault,
        genesis_address,
        genesis,
        fee_token_address,
        fee_token,
        fee_token_2_address,
        fee_token_2,
    }
}

/// Mint tokens to depositor and approve vault.
fn setup_depositor(
    token: IMockERC20Dispatcher,
    token_address: ContractAddress,
    vault_address: ContractAddress,
    depositor: ContractAddress,
    amount: u256,
) {
    token.mint(depositor, amount);
    start_cheat_caller_address(token_address, depositor);
    token.approve(vault_address, amount);
    stop_cheat_caller_address(token_address);
}

// ============================================================
//                    CONSTRUCTOR TESTS
// ============================================================

#[test]
fn test_vault_constructor() {
    let setup = deploy_vault_setup();

    assert(setup.vault.get_genesis_nft() == setup.genesis_address, 'wrong genesis nft');
    let tokens = setup.vault.get_fee_tokens();
    assert(tokens.len() == 0, 'should have 0 fee tokens');
}

// ============================================================
//                    DEPOSIT TESTS
// ============================================================

#[test]
fn test_deposit_single() {
    let setup = deploy_vault_setup();
    let deposit_amount: u256 = 50_000; // 50,000 / 500 = 100 per NFT

    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        deposit_amount,
    );

    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, deposit_amount);
    stop_cheat_caller_address(setup.vault_address);

    // Verify cumulative per NFT
    assert(setup.vault.cumulative_per_nft(setup.fee_token_address) == 100, 'should be 100 per nft');

    // Verify auto-registration
    let tokens = setup.vault.get_fee_tokens();
    assert(tokens.len() == 1, 'should have 1 fee token');

    // Verify vault received the tokens
    assert(setup.fee_token.balance_of(setup.vault_address) == deposit_amount, 'vault should hold tokens');
}

#[test]
fn test_deposit_dust_accumulation() {
    let setup = deploy_vault_setup();

    // Deposit 499 (less than 500 NFTs — entire amount becomes dust)
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        499,
    );

    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 499);
    stop_cheat_caller_address(setup.vault_address);

    assert(setup.vault.cumulative_per_nft(setup.fee_token_address) == 0, 'should be 0 (all dust)');

    // Deposit 1 more — now total dust = 500, which distributes as 1 per NFT
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        1,
    );

    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 1);
    stop_cheat_caller_address(setup.vault_address);

    assert(setup.vault.cumulative_per_nft(setup.fee_token_address) == 1, 'should be 1 after dust resolves');
}

#[test]
fn test_deposit_multiple_tokens() {
    let setup = deploy_vault_setup();

    // Deposit token 1
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        3_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 3_000);
    stop_cheat_caller_address(setup.vault_address);

    // Deposit token 2
    setup_depositor(
        setup.fee_token_2,
        setup.fee_token_2_address,
        setup.vault_address,
        DEPOSITOR(),
        6_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_2_address, 6_000);
    stop_cheat_caller_address(setup.vault_address);

    // Verify independent tracking
    assert(setup.vault.cumulative_per_nft(setup.fee_token_address) == 6, 'token1: 3000/500 = 6');
    assert(setup.vault.cumulative_per_nft(setup.fee_token_2_address) == 12, 'token2: 6000/500 = 12');

    let tokens = setup.vault.get_fee_tokens();
    assert(tokens.len() == 2, 'should have 2 fee tokens');
}

#[test]
#[should_panic(expected: 'VAULT: zero amount')]
fn test_deposit_zero_reverts() {
    let setup = deploy_vault_setup();

    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 0);
}

// ============================================================
//                    CLAIM TESTS
// ============================================================

#[test]
fn test_claim_single_token() {
    let setup = deploy_vault_setup();
    let deposit_amount: u256 = 50_000; // 100 per NFT

    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        deposit_amount,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, deposit_amount);
    stop_cheat_caller_address(setup.vault_address);

    // HOLDER_1 claims for token_id = 101
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.claim(101);
    stop_cheat_caller_address(setup.vault_address);

    assert(setup.fee_token.balance_of(HOLDER_1()) == 100, 'holder1 should get 100');
    // Claimable should now be 0
    assert(setup.vault.claimable(101, setup.fee_token_address) == 0, 'should be 0 after claim');
}

#[test]
fn test_claim_token_specific() {
    let setup = deploy_vault_setup();

    // Deposit both tokens
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        3_000,
    );
    setup_depositor(
        setup.fee_token_2,
        setup.fee_token_2_address,
        setup.vault_address,
        DEPOSITOR(),
        6_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 3_000);
    setup.vault.deposit(setup.fee_token_2_address, 6_000);
    stop_cheat_caller_address(setup.vault_address);

    // Claim only token 1
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.claim_token(101, setup.fee_token_address);
    stop_cheat_caller_address(setup.vault_address);

    assert(setup.fee_token.balance_of(HOLDER_1()) == 6, 'should get 6 of token1');
    // Token 2 should still be claimable
    assert(setup.vault.claimable(101, setup.fee_token_2_address) == 12, 'token2 still claimable');
}

#[test]
fn test_claim_after_multiple_deposits() {
    let setup = deploy_vault_setup();

    // First deposit: 3,000 (6 per NFT)
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        3_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 3_000);
    stop_cheat_caller_address(setup.vault_address);

    // Second deposit: 6,000 (12 per NFT)
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        6_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 6_000);
    stop_cheat_caller_address(setup.vault_address);

    // Cumulative should be 18 (6 + 12)
    assert(setup.vault.cumulative_per_nft(setup.fee_token_address) == 18, 'should be 18 cumulative');

    // Claim
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.claim(101);
    stop_cheat_caller_address(setup.vault_address);

    assert(setup.fee_token.balance_of(HOLDER_1()) == 18, 'should get accumulated 18');
}

#[test]
fn test_claim_with_zero_claimable() {
    let setup = deploy_vault_setup();

    // No deposits yet — claim should succeed silently
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.claim(101);
    stop_cheat_caller_address(setup.vault_address);

    assert(setup.fee_token.balance_of(HOLDER_1()) == 0, 'should have 0');
}

#[test]
fn test_claim_batch() {
    let setup = deploy_vault_setup();

    // Mint more NFTs to HOLDER_1 (tokens 103 and 104)
    start_cheat_caller_address(setup.genesis_address, OWNER());
    setup.genesis.admin_mint(HOLDER_1(), 2); // token_ids 103, 104
    stop_cheat_caller_address(setup.genesis_address);

    // Deposit
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        30_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 30_000);
    stop_cheat_caller_address(setup.vault_address);

    // Batch claim tokens 101, 103, 104
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.claim_batch(array![101, 103, 104]);
    stop_cheat_caller_address(setup.vault_address);

    // 60 per NFT * 3 NFTs = 180
    assert(setup.fee_token.balance_of(HOLDER_1()) == 180, 'should get 180 total');
}

#[test]
#[should_panic(expected: 'VAULT: not owner')]
fn test_claim_not_owner_reverts() {
    let setup = deploy_vault_setup();

    // Deposit
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        30_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 30_000);
    stop_cheat_caller_address(setup.vault_address);

    // HOLDER_2 tries to claim token_id = 101 (owned by HOLDER_1)
    start_cheat_caller_address(setup.vault_address, HOLDER_2());
    setup.vault.claim(101);
}

#[test]
fn test_double_claim_gets_zero_second_time() {
    let setup = deploy_vault_setup();

    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        30_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 30_000);
    stop_cheat_caller_address(setup.vault_address);

    // First claim
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.claim(101);
    stop_cheat_caller_address(setup.vault_address);
    assert(setup.fee_token.balance_of(HOLDER_1()) == 60, 'first claim: 60');

    // Second claim (no new deposits)
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.claim(101);
    stop_cheat_caller_address(setup.vault_address);
    assert(setup.fee_token.balance_of(HOLDER_1()) == 60, 'second claim: still 60');
}

// ============================================================
//                    VIEW TESTS
// ============================================================

#[test]
fn test_claimable_all() {
    let setup = deploy_vault_setup();

    // Deposit both tokens
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        3_000,
    );
    setup_depositor(
        setup.fee_token_2,
        setup.fee_token_2_address,
        setup.vault_address,
        DEPOSITOR(),
        6_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 3_000);
    setup.vault.deposit(setup.fee_token_2_address, 6_000);
    stop_cheat_caller_address(setup.vault_address);

    let (tokens, amounts) = setup.vault.claimable_all(101);
    assert(tokens.len() == 2, 'should have 2 tokens');
    assert(amounts.len() == 2, 'should have 2 amounts');
    assert(*amounts.at(0) == 6, 'token1: 6');
    assert(*amounts.at(1) == 12, 'token2: 12');
}

// ============================================================
//                    ADMIN TESTS
// ============================================================

#[test]
fn test_register_token() {
    let setup = deploy_vault_setup();

    start_cheat_caller_address(setup.vault_address, OWNER());
    setup.vault.register_token(setup.fee_token_address);
    stop_cheat_caller_address(setup.vault_address);

    let tokens = setup.vault.get_fee_tokens();
    assert(tokens.len() == 1, 'should have 1 token');
}

#[test]
#[should_panic(expected: 'VAULT: token registered')]
fn test_register_token_duplicate_reverts() {
    let setup = deploy_vault_setup();

    start_cheat_caller_address(setup.vault_address, OWNER());
    setup.vault.register_token(setup.fee_token_address);
    setup.vault.register_token(setup.fee_token_address); // duplicate
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_register_token_not_owner_reverts() {
    let setup = deploy_vault_setup();

    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.register_token(setup.fee_token_address);
}

#[test]
fn test_set_genesis_nft() {
    let setup = deploy_vault_setup();

    start_cheat_caller_address(setup.vault_address, OWNER());
    setup.vault.set_genesis_nft(HOLDER_1()); // arbitrary address for test
    stop_cheat_caller_address(setup.vault_address);

    assert(setup.vault.get_genesis_nft() == HOLDER_1(), 'should be updated');
}

// ============================================================
//                    SNAPSHOT TESTS
// ============================================================

#[test]
fn test_snapshot_prevents_retroactive_claim() {
    let setup = deploy_vault_setup();

    // Deposit 50,000 BEFORE minting NFT #103
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        50_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 50_000);
    stop_cheat_caller_address(setup.vault_address);

    // cumulative = 100 per NFT (50,000 / 500)
    assert(setup.vault.cumulative_per_nft(setup.fee_token_address) == 100, 'cumulative 100');

    // Link vault to genesis so mints trigger snapshot
    start_cheat_caller_address(setup.genesis_address, OWNER());
    setup.genesis.set_fee_vault(setup.vault_address);
    stop_cheat_caller_address(setup.genesis_address);

    // Mint NFT #103 to HOLDER_1 (after treasury 1-100 + admin 101-102)
    // This triggers snapshot_new_nft which sets claimed[103] = cumulative = 100
    start_cheat_caller_address(setup.genesis_address, OWNER());
    setup.genesis.admin_mint(HOLDER_1(), 1); // token_id = 103
    stop_cheat_caller_address(setup.genesis_address);

    // NFT #103 should have 0 claimable (snapshot zeroed out retroactive fees)
    assert(setup.vault.claimable(103, setup.fee_token_address) == 0, 'new nft 0 claimable');

    // NFT #101 (minted before vault link) should still have full 100
    assert(setup.vault.claimable(101, setup.fee_token_address) == 100, 'old nft 100 claimable');

    // Now deposit MORE fees
    setup_depositor(
        setup.fee_token,
        setup.fee_token_address,
        setup.vault_address,
        DEPOSITOR(),
        25_000,
    );
    start_cheat_caller_address(setup.vault_address, DEPOSITOR());
    setup.vault.deposit(setup.fee_token_address, 25_000);
    stop_cheat_caller_address(setup.vault_address);

    // cumulative = 100 + 50 = 150
    // NFT #103 should only get the new 50 (150 - 100 snapshot)
    assert(setup.vault.claimable(103, setup.fee_token_address) == 50, 'new nft earns 50');
    // NFT #101 should get all 150 (never claimed)
    assert(setup.vault.claimable(101, setup.fee_token_address) == 150, 'old nft earns 150');
}

#[test]
#[should_panic(expected: 'VAULT: not genesis contract')]
fn test_snapshot_only_callable_by_genesis() {
    let setup = deploy_vault_setup();

    // Random caller tries to snapshot — should revert
    start_cheat_caller_address(setup.vault_address, HOLDER_1());
    setup.vault.snapshot_new_nft(999);
}
