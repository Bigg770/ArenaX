#![no_std]

use soroban_sdk::{
    contract, contractimpl, contracttype, symbol_short, token, Address, BytesN, Env, Map, Vec,
};

const MAX_PARTICIPANTS: u32 = 64;

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EscrowStatus {
    Active,
    Disputed,
    Released,
    Refunded,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Escrow {
    pub asset: Address,
    pub entry_amount: i128,
    pub total_held: i128,
    pub participants: Vec<Address>,
    pub deposits: Map<Address, i128>,
    pub status: EscrowStatus,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Admin,
    Resolver,
    Escrow(BytesN<32>),
}

#[contract]
pub struct TournamentEscrow;

#[contractimpl]
impl TournamentEscrow {
    pub fn initialize(env: Env, admin: Address, resolver: Address) {
        if env.storage().instance().has(&DataKey::Admin) {
            panic!("already initialized");
        }
        admin.require_auth();
        env.storage().instance().set(&DataKey::Admin, &admin);
        env.storage()
            .instance()
            .set(&DataKey::Resolver, &resolver);
        env.events()
            .publish((symbol_short!("INIT"),), (admin, resolver));
    }

    pub fn set_resolver(env: Env, admin: Address, resolver: Address) {
        Self::require_admin(&env, &admin);
        env.storage()
            .instance()
            .set(&DataKey::Resolver, &resolver);
        env.events()
            .publish((symbol_short!("RESOLVER"),), (admin, resolver));
    }

    pub fn create_escrow(
        env: Env,
        resolver: Address,
        tournament_id: BytesN<32>,
        asset: Address,
        entry_amount: i128,
    ) {
        Self::require_resolver(&env, &resolver);
        if entry_amount <= 0 {
            panic!("entry amount must be positive");
        }
        let key = DataKey::Escrow(tournament_id.clone());
        if env.storage().persistent().has(&key) {
            panic!("escrow already exists");
        }

        let escrow = Escrow {
            asset: asset.clone(),
            entry_amount,
            total_held: 0,
            participants: Vec::new(&env),
            deposits: Map::new(&env),
            status: EscrowStatus::Active,
        };
        env.storage().persistent().set(&key, &escrow);
        env.events().publish(
            (symbol_short!("CREATED"), tournament_id),
            (asset, entry_amount),
        );
    }

    pub fn deposit(env: Env, tournament_id: BytesN<32>, participant: Address, amount: i128) {
        participant.require_auth();
        if amount <= 0 {
            panic!("amount must be positive");
        }
        let key = DataKey::Escrow(tournament_id.clone());
        let mut escrow: Escrow = env
            .storage()
            .persistent()
            .get(&key)
            .expect("escrow not found");
        if escrow.status != EscrowStatus::Active {
            panic!("escrow is not accepting deposits");
        }
        if amount != escrow.entry_amount {
            panic!("deposit must match entry amount");
        }
        if escrow.deposits.contains_key(participant.clone()) {
            panic!("participant already deposited");
        }
        if escrow.participants.len() >= MAX_PARTICIPANTS {
            panic!("participant limit reached");
        }
        let new_total = escrow
            .total_held
            .checked_add(amount)
            .expect("escrow total overflow");

        token::Client::new(&env, &escrow.asset).transfer(
            &participant,
            &env.current_contract_address(),
            &amount,
        );
        escrow.participants.push_back(participant.clone());
        escrow.deposits.set(participant.clone(), amount);
        escrow.total_held = new_total;
        env.storage().persistent().set(&key, &escrow);
        env.events().publish(
            (symbol_short!("DEPOSIT"), tournament_id),
            (participant, amount, new_total),
        );
    }

    pub fn dispute(env: Env, resolver: Address, tournament_id: BytesN<32>) {
        Self::require_resolver(&env, &resolver);
        let key = DataKey::Escrow(tournament_id.clone());
        let mut escrow: Escrow = env
            .storage()
            .persistent()
            .get(&key)
            .expect("escrow not found");
        if escrow.status != EscrowStatus::Active {
            panic!("escrow is not active");
        }
        escrow.status = EscrowStatus::Disputed;
        env.storage().persistent().set(&key, &escrow);
        env.events()
            .publish((symbol_short!("DISPUTE"), tournament_id), resolver);
    }

    /// Settle to `winner`, or refund every participant when `winner` is `None`.
    /// A disputed escrow can only be settled by the configured resolver.
    pub fn resolve(
        env: Env,
        resolver: Address,
        tournament_id: BytesN<32>,
        winner: Option<Address>,
    ) {
        Self::require_resolver(&env, &resolver);
        let key = DataKey::Escrow(tournament_id.clone());
        let mut escrow: Escrow = env
            .storage()
            .persistent()
            .get(&key)
            .expect("escrow not found");
        if escrow.status != EscrowStatus::Active && escrow.status != EscrowStatus::Disputed {
            panic!("escrow is already settled");
        }
        let client = token::Client::new(&env, &escrow.asset);
        let contract_address = env.current_contract_address();
        if let Some(winner) = winner {
            if escrow.total_held <= 0 {
                panic!("escrow has no deposits");
            }
            if !escrow.deposits.contains_key(winner.clone()) {
                panic!("winner is not a participant");
            }
            let payout = escrow.total_held;
            escrow.status = EscrowStatus::Released;
            escrow.total_held = 0;
            env.storage().persistent().set(&key, &escrow);
            client.transfer(&contract_address, &winner, &payout);
            env.events().publish(
                (symbol_short!("RELEASE"), tournament_id),
                (winner, payout, resolver),
            );
        } else {
            let refund_total = escrow.total_held;
            escrow.status = EscrowStatus::Refunded;
            escrow.total_held = 0;
            env.storage().persistent().set(&key, &escrow);
            let mut index = 0;
            while index < escrow.participants.len() {
                let participant = escrow.participants.get(index).unwrap();
                let amount = escrow.deposits.get(participant.clone()).unwrap();
                client.transfer(&contract_address, &participant, &amount);
                env.events().publish(
                    (symbol_short!("REFUND"), tournament_id.clone()),
                    (participant, amount),
                );
                index += 1;
            }
            env.events().publish(
                (symbol_short!("REFUNDED"), tournament_id),
                (refund_total, resolver),
            );
        }
    }

    pub fn get_escrow(env: Env, tournament_id: BytesN<32>) -> Option<Escrow> {
        env.storage()
            .persistent()
            .get(&DataKey::Escrow(tournament_id))
    }

    pub fn get_admin(env: Env) -> Address {
        env.storage().instance().get(&DataKey::Admin).unwrap()
    }

    fn require_admin(env: &Env, admin: &Address) {
        admin.require_auth();
        let stored: Address = env
            .storage()
            .instance()
            .get(&DataKey::Admin)
            .expect("not initialized");
        if *admin != stored {
            panic!("caller is not admin");
        }
    }

    fn require_resolver(env: &Env, resolver: &Address) {
        resolver.require_auth();
        let stored: Address = env
            .storage()
            .instance()
            .get(&DataKey::Resolver)
            .expect("not initialized");
        if *resolver != stored {
            panic!("caller is not resolver");
        }
    }
}

#[cfg(test)]
mod test;