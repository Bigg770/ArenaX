#![cfg(test)]

extern crate std;

use super::{compute_leaf, hash_sorted_pair, AirdropContract, AirdropContractClient};
use soroban_sdk::testutils::{Address as _, Ledger};
use soroban_sdk::{token, Address, BytesN, Env, Vec};

fn setup() -> (
    Env,
    AirdropContractClient<'static>,
    Address,
    Address,
    Address,
    Address,
) {
    let env = Env::default();
    env.mock_all_auths();
    env.ledger().set_timestamp(1_000);

    let admin = Address::generate(&env);
    let claimant = Address::generate(&env);
    let recovery = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token_addr = env
        .register_stellar_asset_contract_v2(token_admin)
        .address();

    let contract_id = env.register(AirdropContract, ());
    let client = AirdropContractClient::new(&env, &contract_id);

    let placeholder = BytesN::from_array(&env, &[0u8; 32]);
    client.initialize(
        &admin,
        &token_addr,
        &placeholder,
        &1_000_000i128,
        &50_000u64,
        &recovery,
    );
    token::StellarAssetClient::new(&env, &token_addr).mint(&contract_id, &1_000_000i128);

    (env, client, claimant, recovery, token_addr, contract_id)
}

fn proof_root(env: &Env, leaf: &BytesN<32>, proof: &Vec<BytesN<32>>) -> BytesN<32> {
    let mut current = leaf.clone();
    let mut i = 0u32;
    while i < proof.len() {
        let sibling = proof.get(i).unwrap();
        current = hash_sorted_pair(env, &current, &sibling);
        i += 1;
    }
    current
}

fn single_leaf_drop(
    env: &Env,
    client: &AirdropContractClient,
    contract_address: &Address,
    claimant: &Address,
    token: &Address,
    amount: i128,
) {
    let campaign_id = client.get_campaign_id() + 1;
    let leaf = compute_leaf(env, contract_address, claimant, token, campaign_id, 1, amount);
    let proof = Vec::new(env);
    let root = proof_root(env, &leaf, &proof);
    client.configure_airdrop(&root, &amount, &10_000u64);
}

#[test]
fn valid_proof_claims_tokens() {
    let (env, client, claimant, _, token_addr, contract_id) = setup();
    let amount = 250i128;
    single_leaf_drop(&env, &client, &contract_id, &claimant, &token_addr, amount);

    let result = client.claim(&claimant, &Vec::new(&env), &amount);
    assert_eq!(result.amount, amount);
    assert!(client.has_claimed(&claimant));
    assert_eq!(
        token::Client::new(&env, &token_addr).balance(&claimant),
        amount
    );
    assert_eq!(client.get_claimed_amount(), amount);
}

#[test]
#[should_panic(expected = "invalid merkle proof")]
fn invalid_proof_is_rejected() {
    let (env, client, claimant, _, token_addr, contract_id) = setup();
    let amount = 250i128;
    single_leaf_drop(&env, &client, &contract_id, &claimant, &token_addr, amount);

    let mut bogus = [0u8; 32];
    bogus[0] = 1;
    let mut proof = Vec::new(&env);
    proof.push_back(BytesN::from_array(&env, &bogus));
    client.claim(&claimant, &proof, &amount);
}

#[test]
#[should_panic(expected = "already claimed")]
fn double_claim_is_rejected() {
    let (env, client, claimant, _, token_addr, contract_id) = setup();
    let amount = 250i128;
    single_leaf_drop(&env, &client, &contract_id, &claimant, &token_addr, amount);
    let proof = Vec::new(&env);
    client.claim(&claimant, &proof, &amount);
    client.claim(&claimant, &proof, &amount);
}

#[test]
#[should_panic(expected = "airdrop has expired")]
fn expired_claim_is_rejected() {
    let (env, client, claimant, _, token_addr, contract_id) = setup();
    let amount = 250i128;
    single_leaf_drop(&env, &client, &contract_id, &claimant, &token_addr, amount);
    env.ledger().set_timestamp(10_000);
    client.claim(&claimant, &Vec::new(&env), &amount);
}

#[test]
fn admin_recovers_unclaimed_tokens_after_expiry() {
    let (env, client, claimant, recovery, token_addr, contract_id) = setup();
    let amount = 250i128;
    single_leaf_drop(&env, &client, &contract_id, &claimant, &token_addr, amount);
    client.claim(&claimant, &Vec::new(&env), &amount);

    env.ledger().set_timestamp(10_000);
    let recovered = client.recover_unclaimed();
    assert_eq!(recovered, 1_000_000 - amount);
    assert_eq!(
        token::Client::new(&env, &token_addr).balance(&recovery),
        recovered
    );
    assert_eq!(
        token::Client::new(&env, &token_addr).balance(&contract_id),
        0
    );
}

/// Native (non-wasm) cost of `claim` with a depth-20 sorted Merkle proof.
///
/// Measured on soroban-sdk 23: 2_012_264 instructions, 7 memory reads,
/// 5 writes, 1_296 write bytes. Wasm execution and disk rent are not included.
/// The bounds below catch a large regression without pinning the host meter.
#[test]
fn depth_20_claim_is_measured() {
    let (env, client, claimant, _, token_addr, contract_id) = setup();
    let amount = 100i128;
    let campaign_id = client.get_campaign_id() + 1;
    let leaf = compute_leaf(
        &env,
        &contract_id,
        &claimant,
        &token_addr,
        campaign_id,
        1,
        amount,
    );

    let mut proof = Vec::new(&env);
    for level in 1u8..=20 {
        let mut bytes = [0u8; 32];
        bytes[0] = level;
        bytes[31] = 0xA5;
        proof.push_back(BytesN::from_array(&env, &bytes));
    }
    let root = proof_root(&env, &leaf, &proof);
    client.configure_airdrop(&root, &amount, &10_000u64);

    client.claim(&claimant, &proof, &amount);

    let resources = env.cost_estimate().resources();
    assert!(resources.instructions > 0, "claim must be metered");
    assert!(
        resources.memory_read_entries <= 20,
        "depth-20 claim read {} entries",
        resources.memory_read_entries
    );
    assert!(
        resources.write_entries <= 8,
        "depth-20 claim wrote {} entries",
        resources.write_entries
    );
}

#[test]
#[should_panic(expected = "additional budget is not funded")]
fn campaign_budget_cannot_exceed_funded_tokens() {
    let (env, client, _, _, _, _) = setup();
    let root = BytesN::from_array(&env, &[1u8; 32]);

    client.update_merkle_root(&root, &1);
}

#[test]
fn claim_leaf_and_nullifier_are_campaign_scoped() {
    let (env, client, claimant, _, token_addr, contract_id) = setup();
    let amount = 250i128;
    let first_campaign = client.get_campaign_id() + 1;
    let first_leaf = compute_leaf(
        &env,
        &contract_id,
        &claimant,
        &token_addr,
        first_campaign,
        1,
        amount,
    );
    let first_root = proof_root(&env, &first_leaf, &Vec::new(&env));
    client.configure_airdrop(&first_root, &amount, &10_000u64);
    client.claim(&claimant, &Vec::new(&env), &amount);

    let next_campaign = client.get_campaign_id() + 1;
    let next_leaf = compute_leaf(
        &env,
        &contract_id,
        &claimant,
        &token_addr,
        next_campaign,
        1,
        amount,
    );
    let next_root = proof_root(&env, &next_leaf, &Vec::new(&env));
    client.configure_airdrop(&next_root, &amount, &20_000u64);

    assert!(client.has_claimed_for_campaign(&first_campaign, &claimant));
    assert!(!client.has_claimed(&claimant));
    assert!(client
        .try_claim(&claimant, &Vec::new(&env), &amount)
        .is_ok());
}
