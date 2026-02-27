use stela::snip12::{InscriptionOrder, LendOffer, hash_assets};
use stela::types::asset::{Asset, AssetType};
use openzeppelin_utils::cryptography::snip12::StructHash;
use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;

/// Test that hash_assets produces a known result matching JS SDK's hashAssets.
#[test]
fn test_hash_assets_matches_js() {
    let strk_addr: starknet::ContractAddress =
        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
        .try_into()
        .unwrap();

    let assets = array![
        Asset {
            asset: strk_addr,
            asset_type: AssetType::ERC20,
            value: 1000000000000000_u256,
            token_id: 0_u256,
        },
    ];

    let result = hash_assets(assets.span());
    let expected: felt252 =
        0x7c13b6e20f6dfc424c1c50458f2e2e98e2d3f16ae40444d6ff4e0c7eb89ca08;

    println!("Cairo hash:    {}", result);
    println!("Expected (JS): {}", expected);
    assert(result == expected, 'hash mismatch with JS SDK');
}

/// Test that InscriptionOrder.hash_struct() matches JS SDK's TypedData encoding.
#[test]
fn test_order_struct_hash_matches_js() {
    let strk_addr: starknet::ContractAddress =
        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
        .try_into()
        .unwrap();

    let borrower: starknet::ContractAddress =
        0x005441affcd25fe95554b13690346ebec62a27282327dd297cab01a897b08310
        .try_into()
        .unwrap();

    let debt_assets = array![
        Asset { asset: strk_addr, asset_type: AssetType::ERC20, value: 1000000000000000_u256, token_id: 0_u256 },
    ];
    let interest_assets = array![
        Asset { asset: strk_addr, asset_type: AssetType::ERC20, value: 100000000000000_u256, token_id: 0_u256 },
    ];
    let collateral_assets = array![
        Asset { asset: strk_addr, asset_type: AssetType::ERC20, value: 2000000000000000_u256, token_id: 0_u256 },
    ];

    let order = InscriptionOrder {
        borrower,
        debt_hash: hash_assets(debt_assets.span()),
        interest_hash: hash_assets(interest_assets.span()),
        collateral_hash: hash_assets(collateral_assets.span()),
        debt_count: 1,
        interest_count: 1,
        collateral_count: 1,
        duration: 3600,
        deadline: 1772105000,
        multi_lender: false,
        nonce: 0,
    };

    let struct_hash = order.hash_struct();
    println!("Order struct hash: {}", struct_hash);

    // Now compute the full message hash as the contract would:
    // 'StarkNet Message' + domain_hash + account + struct_hash
    // Domain: name='Stela', version='v1', chainId=SN_SEPOLIA, revision=1
    let domain_type_hash = selector!(
        "\"StarknetDomain\"(\"name\":\"shortstring\",\"version\":\"shortstring\",\"chainId\":\"shortstring\",\"revision\":\"shortstring\")"
    );
    let chain_id: felt252 = 0x534e5f5345504f4c4941; // SN_SEPOLIA

    let domain_hash = PoseidonTrait::new()
        .update_with(domain_type_hash)
        .update_with('Stela')
        .update_with('v1')
        .update_with(chain_id)
        .update_with(1) // revision = 1 (integer, NOT shortstring '1' = 0x31)
        .finalize();

    println!("Domain hash: {}", domain_hash);

    let msg_hash = PoseidonTrait::new()
        .update_with('StarkNet Message')
        .update_with(domain_hash)
        .update_with(borrower) // account = borrower
        .update_with(struct_hash)
        .finalize();

    println!("Full message hash: {}", msg_hash);
    println!("(Compare with JS getMessageHash output)");

    // --- LendOffer hash test ---
    let lender: starknet::ContractAddress =
        0x024a7abe720dabf8fc221f9bca11e6d5ada55589028aa6655099289e87dffb1b
        .try_into()
        .unwrap();

    let offer = LendOffer {
        order_hash: msg_hash, // the order message hash
        lender,
        issued_debt_percentage: 10000_u256, // 100% = 10000 BPS
        nonce: 0,
        lender_commitment: 0, // non-private
    };

    let offer_struct_hash = offer.hash_struct();
    println!("LendOffer struct hash: {}", offer_struct_hash);

    let offer_msg_hash = PoseidonTrait::new()
        .update_with('StarkNet Message')
        .update_with(domain_hash)
        .update_with(lender)
        .update_with(offer_struct_hash)
        .finalize();

    println!("LendOffer full msg hash: {}", offer_msg_hash);

    // Cross-chain verified: matches JS SDK output for identical inputs
    let expected_js_offer_msg_hash: felt252 =
        0x486ec12329e274f9100ec02cc5eb87f570e7edc300ab8d58e18b517fa4b606e;
    assert(offer_msg_hash == expected_js_offer_msg_hash, 'LendOffer hash mismatch JS');
}
