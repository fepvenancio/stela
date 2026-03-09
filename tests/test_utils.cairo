// Test utilities for Stela protocol tests

use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use stela::interfaces::istela::{IStelaProtocolDispatcher, IStelaProtocolDispatcherTrait};
use stela::types::inscription::InscriptionParams;
use stela::types::asset::{Asset, AssetType};
use super::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use super::mocks::mock_erc721::IMockERC721Dispatcher;
use super::mocks::mock_registry::{IMockRegistryDispatcher, IMockRegistryDispatcherTrait};

// ============================================================
//                    TEST ADDRESSES
// ============================================================

#[feature("deprecated-starknet-consts")]
pub fn OWNER() -> ContractAddress {
    starknet::contract_address_const::<'OWNER'>()
}

#[feature("deprecated-starknet-consts")]
pub fn BORROWER() -> ContractAddress {
    starknet::contract_address_const::<'BORROWER'>()
}

#[feature("deprecated-starknet-consts")]
pub fn LENDER() -> ContractAddress {
    starknet::contract_address_const::<'LENDER'>()
}

#[feature("deprecated-starknet-consts")]
pub fn LENDER_2() -> ContractAddress {
    starknet::contract_address_const::<'LENDER_2'>()
}

#[feature("deprecated-starknet-consts")]
pub fn TREASURY() -> ContractAddress {
    starknet::contract_address_const::<'TREASURY'>()
}

#[feature("deprecated-starknet-consts")]
pub fn NFT_CONTRACT() -> ContractAddress {
    starknet::contract_address_const::<'NFT_CONTRACT'>()
}

#[feature("deprecated-starknet-consts")]
pub fn REGISTRY() -> ContractAddress {
    starknet::contract_address_const::<'REGISTRY'>()
}

#[feature("deprecated-starknet-consts")]
pub fn MOCK_TOKEN() -> ContractAddress {
    starknet::contract_address_const::<'MOCK_TOKEN'>()
}

#[feature("deprecated-starknet-consts")]
pub fn MOCK_NFT() -> ContractAddress {
    starknet::contract_address_const::<'MOCK_NFT'>()
}

// ============================================================
//                    CONTRACT DEPLOYMENT
// ============================================================

/// Deploy the Stela contract with stub addresses (for basic tests).
/// Only use for create_inscription and view function tests.
/// For sign/repay/liquidate/redeem tests, use deploy_full_setup().
pub fn deploy_stela() -> (ContractAddress, IStelaProtocolDispatcher) {
    let contract = declare("StelaProtocol").unwrap().contract_class();

    // Constructor args: owner, inscriptions_nft, registry, implementation_hash
    let mut constructor_calldata: Array<felt252> = array![];
    OWNER().serialize(ref constructor_calldata);
    NFT_CONTRACT().serialize(ref constructor_calldata);
    REGISTRY().serialize(ref constructor_calldata);
    constructor_calldata.append(0x1234); // implementation_hash (stub)

    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IStelaProtocolDispatcher { contract_address };

    (contract_address, dispatcher)
}

/// Deploy a mock ERC20 token.
pub fn deploy_mock_erc20(name: ByteArray, symbol: ByteArray) -> (ContractAddress, IMockERC20Dispatcher) {
    let contract = declare("MockERC20").unwrap().contract_class();

    let mut constructor_calldata: Array<felt252> = array![];
    name.serialize(ref constructor_calldata);
    symbol.serialize(ref constructor_calldata);
    constructor_calldata.append(18); // decimals

    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IMockERC20Dispatcher { contract_address };

    (contract_address, dispatcher)
}

/// Deploy a mock ERC721 token.
pub fn deploy_mock_erc721(name: ByteArray, symbol: ByteArray) -> (ContractAddress, IMockERC721Dispatcher) {
    let contract = declare("MockERC721").unwrap().contract_class();

    let mut constructor_calldata: Array<felt252> = array![];
    name.serialize(ref constructor_calldata);
    symbol.serialize(ref constructor_calldata);

    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IMockERC721Dispatcher { contract_address };

    (contract_address, dispatcher)
}

/// Deploy a mock registry.
pub fn deploy_mock_registry(stela_contract: ContractAddress) -> (ContractAddress, IMockRegistryDispatcher) {
    let contract = declare("MockRegistry").unwrap().contract_class();

    let constructor_calldata: Array<felt252> = array![];

    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IMockRegistryDispatcher { contract_address };

    // Set the stela contract address after deployment
    dispatcher.set_stela_contract(stela_contract);

    (contract_address, dispatcher)
}

/// Full test setup structure.
#[derive(Drop)]
pub struct TestSetup {
    pub stela_address: ContractAddress,
    pub stela: IStelaProtocolDispatcher,
    pub debt_token_address: ContractAddress,
    pub debt_token: IMockERC20Dispatcher,
    pub collateral_token_address: ContractAddress,
    pub collateral_token: IMockERC20Dispatcher,
    pub interest_token_address: ContractAddress,
    pub interest_token: IMockERC20Dispatcher,
    pub nft_address: ContractAddress,
    pub nft: IMockERC721Dispatcher,
    pub registry_address: ContractAddress,
    pub registry: IMockRegistryDispatcher,
    pub locker_class_hash: felt252,
}

/// Deploy a full test environment with all mocks.
/// Properly wires all contracts together (solves chicken-and-egg via set_registry).
///
/// Deploy order:
/// 1. Mock tokens (ERC20 x3, ERC721)
/// 2. Declare LockerAccount class
/// 3. Deploy Stela with placeholder registry
/// 4. Deploy MockRegistry with real Stela address
/// 5. Call set_registry + set_inscriptions_nft on Stela (as owner) to wire real addresses
pub fn deploy_full_setup() -> TestSetup {
    // Step 1: Deploy mock tokens
    let (debt_token_address, debt_token) = deploy_mock_erc20("Debt Token", "DEBT");
    let (collateral_token_address, collateral_token) = deploy_mock_erc20("Collateral Token", "COL");
    let (interest_token_address, interest_token) = deploy_mock_erc20("Interest Token", "INT");

    // Deploy mock NFT (inscriptions NFT)
    let (nft_address, nft) = deploy_mock_erc721("Inscriptions NFT", "AGREE");

    // Step 2: Declare LockerAccount to get class hash
    let locker_class = declare("LockerAccount").unwrap().contract_class();
    let locker_class_hash: felt252 = (*locker_class.class_hash).into();

    // Step 3: Deploy Stela with placeholder registry (will update after)
    let stela_contract = declare("StelaProtocol").unwrap().contract_class();
    let mut stela_calldata: Array<felt252> = array![];
    OWNER().serialize(ref stela_calldata);
    nft_address.serialize(ref stela_calldata); // Real NFT address
    REGISTRY().serialize(ref stela_calldata); // Placeholder — will update via set_registry
    stela_calldata.append(locker_class_hash);

    let (stela_address, _) = stela_contract.deploy(@stela_calldata).unwrap();
    let stela = IStelaProtocolDispatcher { contract_address: stela_address };

    // Step 4: Deploy mock registry with real Stela address
    let (registry_address, registry) = deploy_mock_registry(stela_address);

    // Step 5: Wire real registry into Stela (owner calls set_registry)
    start_cheat_caller_address(stela_address, OWNER());
    stela.set_registry(registry_address);
    stop_cheat_caller_address(stela_address);

    TestSetup {
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
        locker_class_hash,
    }
}

/// Setup borrower with collateral tokens and approval.
pub fn setup_borrower_with_collateral(setup: @TestSetup, borrower: ContractAddress, amount: u256) {
    // Mint collateral to borrower
    (*setup.collateral_token).mint(borrower, amount);

    // Approve Stela contract to spend collateral
    start_cheat_caller_address(*setup.collateral_token_address, borrower);
    (*setup.collateral_token).approve(*setup.stela_address, amount);
    stop_cheat_caller_address(*setup.collateral_token_address);
}

/// Setup lender with debt tokens and approval.
pub fn setup_lender_with_debt(setup: @TestSetup, lender: ContractAddress, amount: u256) {
    // Mint debt tokens to lender
    (*setup.debt_token).mint(lender, amount);

    // Approve Stela contract to spend debt tokens
    start_cheat_caller_address(*setup.debt_token_address, lender);
    (*setup.debt_token).approve(*setup.stela_address, amount);
    stop_cheat_caller_address(*setup.debt_token_address);
}

/// Setup borrower with debt + interest tokens for repayment.
pub fn setup_borrower_for_repayment(
    setup: @TestSetup, borrower: ContractAddress, debt_amount: u256, interest_amount: u256,
) {
    // Borrower needs debt + interest tokens for repayment
    (*setup.debt_token).mint(borrower, debt_amount);
    (*setup.interest_token).mint(borrower, interest_amount);

    // Approve Stela contract
    start_cheat_caller_address(*setup.debt_token_address, borrower);
    (*setup.debt_token).approve(*setup.stela_address, debt_amount);
    stop_cheat_caller_address(*setup.debt_token_address);

    start_cheat_caller_address(*setup.interest_token_address, borrower);
    (*setup.interest_token).approve(*setup.stela_address, interest_amount);
    stop_cheat_caller_address(*setup.interest_token_address);
}

// ============================================================
//                    TEST HELPERS
// ============================================================

/// Create a simple ERC20 debt asset.
pub fn create_erc20_asset(token: ContractAddress, value: u256) -> Asset {
    Asset { asset: token, asset_type: AssetType::ERC20, value, token_id: 0 }
}

/// Create an ERC721 asset.
pub fn create_erc721_asset(nft: ContractAddress, token_id: u256) -> Asset {
    Asset { asset: nft, asset_type: AssetType::ERC721, value: 0, token_id }
}

/// Create inscription params for borrowing using real token addresses from TestSetup.
pub fn create_borrow_params_from_setup(
    setup: @TestSetup, debt_amount: u256, collateral_amount: u256, interest_amount: u256, duration: u64, deadline: u64,
) -> InscriptionParams {
    InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(*setup.debt_token_address, debt_amount)],
        interest_assets: array![create_erc20_asset(*setup.interest_token_address, interest_amount)],
        collateral_assets: array![create_erc20_asset(*setup.collateral_token_address, collateral_amount)],
        duration,
        deadline,
        multi_lender: false,
    }
}

/// Create multi-lender inscription params from TestSetup.
pub fn create_multi_lender_params_from_setup(
    setup: @TestSetup, debt_amount: u256, collateral_amount: u256, interest_amount: u256, duration: u64, deadline: u64,
) -> InscriptionParams {
    InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(*setup.debt_token_address, debt_amount)],
        interest_assets: array![create_erc20_asset(*setup.interest_token_address, interest_amount)],
        collateral_assets: array![create_erc20_asset(*setup.collateral_token_address, collateral_amount)],
        duration,
        deadline,
        multi_lender: true,
    }
}

/// Create a simple inscription params for borrowing (using arbitrary addresses).
pub fn create_borrow_params(
    debt_token: ContractAddress,
    debt_amount: u256,
    collateral_token: ContractAddress,
    collateral_amount: u256,
    interest_token: ContractAddress,
    interest_amount: u256,
    duration: u64,
    deadline: u64,
) -> InscriptionParams {
    InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token, debt_amount)],
        interest_assets: array![create_erc20_asset(interest_token, interest_amount)],
        collateral_assets: array![create_erc20_asset(collateral_token, collateral_amount)],
        duration,
        deadline,
        multi_lender: false,
    }
}

/// Create a multi-lender inscription params for borrowing.
pub fn create_multi_lender_borrow_params(
    debt_token: ContractAddress,
    debt_amount: u256,
    collateral_token: ContractAddress,
    collateral_amount: u256,
    interest_token: ContractAddress,
    interest_amount: u256,
    duration: u64,
    deadline: u64,
) -> InscriptionParams {
    InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token, debt_amount)],
        interest_assets: array![create_erc20_asset(interest_token, interest_amount)],
        collateral_assets: array![create_erc20_asset(collateral_token, collateral_amount)],
        duration,
        deadline,
        multi_lender: true,
    }
}

/// Create a lending inscription params (lender creates).
pub fn create_lend_params(
    debt_token: ContractAddress,
    debt_amount: u256,
    collateral_token: ContractAddress,
    collateral_amount: u256,
    interest_token: ContractAddress,
    interest_amount: u256,
    duration: u64,
    deadline: u64,
) -> InscriptionParams {
    InscriptionParams {
        is_borrow: false,
        debt_assets: array![create_erc20_asset(debt_token, debt_amount)],
        interest_assets: array![create_erc20_asset(interest_token, interest_amount)],
        collateral_assets: array![create_erc20_asset(collateral_token, collateral_amount)],
        duration,
        deadline,
        multi_lender: false,
    }
}

/// Create OTC swap params (duration = 0).
pub fn create_otc_swap_params(
    debt_token: ContractAddress,
    debt_amount: u256,
    collateral_token: ContractAddress,
    collateral_amount: u256,
    deadline: u64,
) -> InscriptionParams {
    InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token, debt_amount)],
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(collateral_token, collateral_amount)],
        duration: 0, // OTC swap - no duration
        deadline,
        multi_lender: false,
    }
}
