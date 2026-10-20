#![cfg(test)]

use super::{MatchLifecycleContract, MatchLifecycleContractClient, MatchState};
use soroban_sdk::{testutils::Address as _, Address, BytesN, Env};

#[test]
fn match_lifecycle_is_authorized_monotonic_and_finalized_once() {
    let env = Env::default();
    env.mock_all_auths();
    let admin = Address::generate(&env);
    let player_a = Address::generate(&env);
    let player_b = Address::generate(&env);
    let match_id = BytesN::from_array(&env, &[9; 32]);
    let contract_id = env.register(MatchLifecycleContract, ());
    let client = MatchLifecycleContractClient::new(&env, &contract_id);

    client.initialize(&admin);
    client.create_match(&admin, &match_id, &player_a, &player_b);
    client.start_match(&player_a, &match_id);
    client.complete_match(&admin, &match_id, &player_b);
    client.raise_dispute(&player_a, &match_id);
    client.resolve_dispute(&admin, &match_id, &player_a);
    client.finalize_match(&admin, &match_id);

    let record = client.get_match(&match_id).unwrap();
    assert_eq!(record.state, MatchState::Finalized);
    assert_eq!(record.winner, Some(player_a));
    assert_eq!(record.match_id, match_id);
    assert!(client.try_finalize_match(&admin, &match_id).is_err());
}

#[test]
fn nonparticipants_cannot_start_matches() {
    let env = Env::default();
    env.mock_all_auths();
    let admin = Address::generate(&env);
    let player_a = Address::generate(&env);
    let player_b = Address::generate(&env);
    let stranger = Address::generate(&env);
    let match_id = BytesN::from_array(&env, &[8; 32]);
    let contract_id = env.register(MatchLifecycleContract, ());
    let client = MatchLifecycleContractClient::new(&env, &contract_id);

    client.initialize(&admin);
    client.create_match(&admin, &match_id, &player_a, &player_b);
    assert!(client.try_start_match(&stranger, &match_id).is_err());
}