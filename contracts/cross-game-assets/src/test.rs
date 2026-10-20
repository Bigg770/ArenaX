#![cfg(test)]

use super::{CrossGameAssets, CrossGameAssetsClient};
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{Address, BytesN, Env, String};

fn setup() -> (Env, CrossGameAssetsClient<'static>, Address, Address, Address, BytesN<32>) {
    let env = Env::default();
    env.mock_all_auths();
    let admin = Address::generate(&env);
    let owner = Address::generate(&env);
    let recipient = Address::generate(&env);
    let asset_id = BytesN::from_array(&env, &[3; 32]);
    let contract_id = env.register(CrossGameAssets, ());
    let client = CrossGameAssetsClient::new(&env, &contract_id);

    client.initialize(&admin);
    client.register_asset(
        &asset_id,
        &1,
        &0,
        &String::from_str(&env, "fixture"),
        &((1 << 1) | (1 << 2)),
        &0,
        &true,
        &true,
    );
    client.mint(&admin, &owner, &asset_id, &10, &1);

    (env, client, owner, recipient, admin, asset_id)
}

#[test]
fn transfer_rejects_spoofed_source_game() {
    let (_env, client, owner, recipient, _, asset_id) = setup();
    assert!(client
        .try_transfer(&owner, &recipient, &asset_id, &1, &2, &1)
        .is_err());
}

#[test]
fn game_ids_outside_compatibility_mask_are_rejected() {
    let (_env, client, owner, recipient, _, asset_id) = setup();
    assert!(!client.is_game_compatible(&asset_id, &64));
    assert!(client
        .try_transfer(&owner, &recipient, &asset_id, &1, &1, &64)
        .is_err());
}

#[test]
fn transferred_balance_tracks_destination_game() {
    let (_env, client, owner, recipient, _, asset_id) = setup();
    client.transfer(&owner, &recipient, &asset_id, &4, &1, &2);
    assert!(client
        .try_transfer(&recipient, &owner, &asset_id, &1, &1, &2)
        .is_err());
    assert!(client
        .try_transfer(&recipient, &owner, &asset_id, &1, &2, &1)
        .is_ok());
}