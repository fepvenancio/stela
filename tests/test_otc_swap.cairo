// Tests for OTC swap functionality (duration = 0)

use snforge_std::{
    start_cheat_block_timestamp_global, start_cheat_caller_address, stop_cheat_block_timestamp_global,
    stop_cheat_caller_address,
};
use stela::interfaces::istela::IStelaProtocolDispatcherTrait;
use stela::types::asset::AssetType;
use stela::types::inscription::InscriptionParams;
use super::test_utils::{BORROWER, create_erc20_asset, create_otc_swap_params, deploy_stela};

// ============================================================
//                    OTC SWAP TESTS
// ============================================================

#[test]
#[feature("deprecated-starknet-consts")]
fn test_create_otc_swap() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(contract_address, BORROWER());

    let debt_token = starknet::contract_address_const::<'DEBT'>();
    let collateral_token = starknet::contract_address_const::<'COL'>();

    // Create OTC swap - duration is 0
    let params = create_otc_swap_params(debt_token, 1000, collateral_token, 500, 2000);

    let inscription_id = stela.create_inscription(params);

    // Verify inscription was created with duration 0
    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.duration == 0, 'duration is 0');
    assert(inscription.borrower == BORROWER(), 'borrower mismatch');
    assert(inscription.deadline == 2000, 'deadline mismatch');
    assert(inscription.interest_asset_count == 0, 'no interest assets');

    stop_cheat_caller_address(contract_address);
    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
fn test_otc_swap_no_interest() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(contract_address, BORROWER());

    let debt_token = starknet::contract_address_const::<'DEBT'>();
    let collateral_token = starknet::contract_address_const::<'COL'>();

    // OTC swaps have no interest component
    let params = create_otc_swap_params(debt_token, 5000, collateral_token, 5000, 2000);

    let inscription_id = stela.create_inscription(params);

    let inscription = stela.get_inscription(inscription_id);
    assert(inscription.interest_asset_count == 0, 'no interest');
    assert(inscription.debt_asset_count == 1, '1 debt asset');
    assert(inscription.collateral_asset_count == 1, '1 collateral');

    stop_cheat_caller_address(contract_address);
    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("deprecated-starknet-consts")]
#[should_panic(expected: 'STELA: swap no multi lender')]
fn test_swap_rejects_multi_lender() {
    let (contract_address, stela) = deploy_stela();

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(contract_address, BORROWER());

    let debt_token = starknet::contract_address_const::<'DEBT'>();
    let collateral_token = starknet::contract_address_const::<'COL'>();

    // duration=0 + multi_lender=true should be rejected
    let params = InscriptionParams {
        is_borrow: true,
        debt_assets: array![create_erc20_asset(debt_token, 1000)],
        interest_assets: array![],
        collateral_assets: array![create_erc20_asset(collateral_token, 500)],
        duration: 0,
        deadline: 2000,
        multi_lender: true,
    };

    stela.create_inscription(params);
}
