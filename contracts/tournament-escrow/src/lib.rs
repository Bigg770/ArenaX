#![no_std]

use soroban_sdk::{
    contract, contractimpl, contracttype, symbol_short, token, Address, BytesN, Env, Map, Vec,
};

const MAX_PARTICIPANTS: u32 = 64;

/// Maximum duration for emergency pause: 7 days. Enforces bounded response without permanent lockout (#57).
pub const MAX_PAUSE_DURATION: u64 = 604_800;

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
pub struct PauseState {
    pub paused: bool,
    pub paused_at: u64,
    pub expires_at: u64,
    pub paused_by: Address,
    pub reason: Symbol,
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
    Guardian,
    PauseState,
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
        env.storage().instance().set(&DataKey::Resolver, &resolver);
        env.events()
            .publish((symbol_short!("INIT"),), (admin, resolver));
    }

    pub fn set_resolver(env: Env, admin: Address, resolver: Address) {
        Self::require_admin(&env, &admin);
        env.storage().instance().set(&DataKey::Resolver, &resolver);
        env.events()
            .publish((symbol_short!("RESOLVER"),), (admin, resolver));
    }

    /// Configure a guardian with narrow pause authority (#57).
    pub fn set_guardian(env: Env, admin: Address, guardian: Address) {
        Self::require_admin(&env, &admin);
        env.storage().instance().set(&DataKey::Guardian, &guardian);
        env.events()
            .publish((symbol_short!("GUARDIAN"),), (admin, guardian));
    }

    pub fn get_guardian(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::Guardian)
    }

    /// Trigger emergency pause.
    ///
    /// Callable by Guardian (narrow pause authority) or Admin.
    /// Enforces bounded pause with max duration to avoid permanent lockout (#57).
    pub fn emergency_pause(env: Env, caller: Address, reason: Symbol, duration_seconds: u64) {
        caller.require_auth();
        Self::require_pause_authority(&env, &caller);

        let duration = if duration_seconds == 0 || duration_seconds > MAX_PAUSE_DURATION {
            MAX_PAUSE_DURATION
        } else {
            duration_seconds
        };

        let now = env.ledger().timestamp();
        let expires_at = now.saturating_add(duration);

        let state = PauseState {
            paused: true,
            paused_at: now,
            expires_at,
            paused_by: caller.clone(),
            reason: reason.clone(),
        };

        env.storage().instance().set(&DataKey::PauseState, &state);
        env.events()
            .publish((symbol_short!("PAUSED"),), (caller, reason, expires_at));
    }

    /// Resume operations after emergency pause.
    ///
    /// Requires reviewed recovery: only admin can unpause early (#57).
    pub fn unpause(env: Env, admin: Address) {
        Self::require_admin(&env, &admin);

        let state = PauseState {
            paused: false,
            paused_at: 0,
            expires_at: 0,
            paused_by: admin.clone(),
            reason: symbol_short!("RESUMED"),
        };

        env.storage().instance().set(&DataKey::PauseState, &state);
        env.events().publish((symbol_short!("UNPAUSED"),), admin);
    }

    /// Query whether the contract is actively in emergency pause.
    ///
    /// Returns false if the bounded pause duration has expired (#57).
    pub fn is_emergency_paused(env: Env) -> bool {
        Self::check_is_paused(&env)
    }

    pub fn get_pause_state(env: Env) -> Option<PauseState> {
        env.storage().instance().get(&DataKey::PauseState)
    }

    pub fn create_escrow(
        env: Env,
        resolver: Address,
        tournament_id: BytesN<32>,
        asset: Address,
        entry_amount: i128,
    ) {
        Self::require_not_paused(&env);
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
        Self::require_not_paused(&env);
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

    /// User-fund exit during emergency or pause (#57).
    ///
    /// Allows participants to reclaim their own deposits even when the contract
    /// is paused or disputed, preventing permanent lockout.
    pub fn emergency_withdraw(env: Env, tournament_id: BytesN<32>, participant: Address) {
        participant.require_auth();

        let key = DataKey::Escrow(tournament_id.clone());
        let mut escrow: Escrow = env
            .storage()
            .persistent()
            .get(&key)
            .expect("escrow not found");

        if escrow.status != EscrowStatus::Active && escrow.status != EscrowStatus::Disputed {
            panic!("escrow is already settled");
        }

        let amount = escrow
            .deposits
            .get(participant.clone())
            .expect("participant has no deposit");

        if amount <= 0 {
            panic!("no refundable deposit");
        }

        // Deduct from total and remove deposit record
        escrow.deposits.remove(participant.clone());
        escrow.total_held = escrow.total_held.checked_sub(amount).expect("underflow");

        let mut new_participants = Vec::new(&env);
        for p in escrow.participants.iter() {
            if p != participant {
                new_participants.push_back(p);
            }
        }
        escrow.participants = new_participants;

        env.storage().persistent().set(&key, &escrow);

        token::Client::new(&env, &escrow.asset).transfer(
            &env.current_contract_address(),
            &participant,
            &amount,
        );

        env.events().publish(
            (symbol_short!("EMERG_EXIT"), tournament_id),
            (participant, amount),
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
    /// Winner payouts are blocked while paused to prevent exploit drains (#57).
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
            Self::require_not_paused(&env);
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

    fn check_is_paused(env: &Env) -> bool {
        if let Some(state) = env
            .storage()
            .instance()
            .get::<DataKey, PauseState>(&DataKey::PauseState)
        {
            if state.paused && env.ledger().timestamp() < state.expires_at {
                return true;
            }
        }
        false
    }

    fn require_not_paused(env: &Env) {
        if Self::check_is_paused(env) {
            panic!("contract is emergency paused");
        }
    }

    fn require_pause_authority(env: &Env, caller: &Address) {
        let admin: Address = env
            .storage()
            .instance()
            .get(&DataKey::Admin)
            .expect("not initialized");
        let guardian: Option<Address> = env.storage().instance().get(&DataKey::Guardian);

        if *caller == admin {
            return;
        }
        if let Some(g) = guardian {
            if *caller == g {
                return;
            }
        }
        panic!("caller is not authorized to pause");
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
