//! Reputation Service
//!
//! This service integrates with the Soroban Reputation Index contract to:
//! - Query player reputation scores (skill and fair_play)
//! - Update local database with on-chain reputation data
//! - Filter bad actors from matchmaking
//! - Track anti-cheat flags and penalties

use crate::config::Config;
use sqlx::{PgPool, Row};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use thiserror::Error;
use tracing::{debug, error, info, warn};

const REPUTATION_SCORING_VERSION: i32 = 1;
const MIN_REPUTATION_SCORE: i64 = 0;
const MAX_SKILL_SCORE: i64 = 3_000;
const MAX_FAIR_PLAY_SCORE: i64 = 100;

#[derive(Error, Debug)]
pub enum ReputationError {
    #[error("Contract not found: {0}")]
    ContractNotFound(String),
    #[error("RPC error: {0}")]
    RpcError(String),
    #[error("Database error: {0}")]
    DatabaseError(String),
    #[error("Invalid reputation data: {0}")]
    InvalidData(String),
}

use serde::{Deserialize, Serialize};

/// Reputation data for a player
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerReputation {
    pub user_id: uuid::Uuid,
    pub skill_score: i32,
    pub fair_play_score: i32,
    pub scoring_version: i32,
    pub last_update_ts: u64,
    pub is_bad_actor: bool,
}

impl PlayerReputation {
    /// Determine if a player should be filtered from matchmaking
    pub fn should_filter(&self, min_fair_play: i32) -> bool {
        self.is_bad_actor || self.fair_play_score < min_fair_play
    }

    /// Get reputation tier based on scores
    pub fn get_tier(&self) -> ReputationTier {
        if self.fair_play_score >= 90 && self.skill_score >= 1500 {
            ReputationTier::Elite
        } else if self.fair_play_score >= 70 && self.skill_score >= 1200 {
            ReputationTier::Good
        } else if self.fair_play_score >= 50 {
            ReputationTier::Average
        } else {
            ReputationTier::Poor
        }
    }
}

/// Reputation tiers for matchmaking categorization
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReputationTier {
    Elite,   // High skill, excellent behavior
    Good,    // Decent skill, good behavior
    Average, // Moderate scores
    Poor,    // Low fair play or skill
}

pub struct ReputationService {
    db_pool: PgPool,
    config: Config,
}

impl ReputationService {
    pub fn new(db_pool: PgPool, config: Config) -> Self {
        Self { db_pool, config }
    }

    /// Get player reputation from local cache (synced with on-chain data)
    pub async fn get_player_reputation(
        &self,
        user_id: uuid::Uuid,
    ) -> Result<PlayerReputation, ReputationError> {
        let record = sqlx::query!(
            r#"
            SELECT 
                id as user_id,
                COALESCE(skill_score, 1000) as skill_score,
                COALESCE(fair_play_score, 100) as fair_play_score,
                reputation_scoring_version as scoring_version,
                reputation_last_updated,
                COALESCE(is_bad_actor, false) as is_bad_actor
            FROM users
            WHERE id = $1
            "#,
            user_id
        )
        .fetch_optional(&self.db_pool)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
        .ok_or_else(|| ReputationError::InvalidData(format!("User {} not found", user_id)))?;

        Ok(PlayerReputation {
            user_id: record.user_id,
            skill_score: record.skill_score,
            fair_play_score: record.fair_play_score,
            scoring_version: record.scoring_version,
            last_update_ts: record
                .reputation_last_updated
                .map(|t| t.timestamp() as u64)
                .unwrap_or(0),
            is_bad_actor: record.is_bad_actor,
        })
    }

    /// Update player reputation from on-chain contract
    /// This should be called periodically or after match events
    pub async fn sync_reputation_from_chain(
        &self,
        user_id: uuid::Uuid,
    ) -> Result<PlayerReputation, ReputationError> {
        // TODO: Implement actual Soroban contract call to fetch on-chain reputation
        // For now, we'll use the cached value from the database
        // In production, this would call the ReputationIndex contract's get_reputation() method
        
        debug!("Syncing reputation for user {}", user_id);
        
        // Fetch current cached reputation
        let reputation = self.get_player_reputation(user_id).await?;
        
        // TODO: Call Soroban contract here using soroban_service
        // Example (pseudo-code):
        // let contract_address = self.get_contract_address("reputation_index").await?;
        // let soroban_client = SorobanClient::new(&self.config.stellar.network_url);
        // let on_chain_rep = soroban_client
        //     .invoke_contract::<ReputationData>(
        //         &contract_address,
        //         "get_reputation",
        //         vec![user_public_key]
        //     )
        //     .await?;
        //
        // // Update local cache
        // self.update_local_reputation(user_id, on_chain_rep).await?;

        Ok(reputation)
    }

    /// Apply reputation once after the on-chain match authority is finalized.
    pub async fn update_reputation_on_finalized_match(
        &self,
        match_id: uuid::Uuid,
    ) -> Result<(), ReputationError> {
        let mut tx = self
            .db_pool
            .begin()
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        let match_record = sqlx::query(
            "SELECT state::text AS state, player_a, player_b, winner \
             FROM match_authority WHERE id = $1 FOR UPDATE",
        )
        .bind(match_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
        .ok_or_else(|| ReputationError::InvalidData("Match not found".to_string()))?;
        let state: String = match_record
            .try_get("state")
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let player_a: String = match_record
            .try_get("player_a")
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let player_b: String = match_record
            .try_get("player_b")
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let winner: Option<String> = match_record
            .try_get("winner")
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        if state != "FINALIZED" {
            return Err(ReputationError::InvalidData(
                "Match must be finalized before reputation is updated".to_string(),
            ));
        }
        if player_a == player_b || ![player_a.as_str(), player_b.as_str()].contains(&winner.as_deref().unwrap_or("")) {
            return Err(ReputationError::InvalidData(
                "Finalized match must have two distinct participants and a participant winner".to_string(),
            ));
        }

        let mut participant_addresses = vec![player_a.clone(), player_b.clone()];
        participant_addresses.sort_unstable();
        let accounts = sqlx::query(
            "SELECT public_key, user_id FROM stellar_accounts \
             WHERE public_key = ANY($1) AND user_id IS NOT NULL",
        )
        .bind(&participant_addresses)
        .fetch_all(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let mut participant_ids = HashMap::new();
        for account in accounts {
            let public_key: String = account
                .try_get("public_key")
                .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
            let user_id: uuid::Uuid = account
                .try_get("user_id")
                .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
            participant_ids.insert(public_key, user_id);
        }
        if participant_ids.len() != 2
            || participant_ids.values().collect::<HashSet<_>>().len() != 2
        {
            return Err(ReputationError::InvalidData(
                "Finalized match participants must map to registered users".to_string(),
            ));
        }

        for participant_address in participant_addresses {
            let player_id = *participant_ids
                .get(&participant_address)
                .ok_or_else(|| ReputationError::InvalidData("Match participant not found".to_string()))?;
            let skill_delta = if winner.as_deref() == Some(participant_address.as_str()) {
                25
            } else {
                -25
            };
            let fair_play_delta = 1; // Completion bonus

            let newly_applied = sqlx::query(
                "INSERT INTO reputation_match_applications (match_id, user_id, scoring_version) \
                 VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING match_id",
            )
            .bind(match_id)
            .bind(player_id)
            .bind(REPUTATION_SCORING_VERSION)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
            .is_some();

            if !newly_applied {
                continue;
            }

            let current = sqlx::query(
                "SELECT COALESCE(skill_score, 1000)::bigint AS skill_score, \
                 COALESCE(fair_play_score, 100)::bigint AS fair_play_score \
                 FROM users WHERE id = $1 FOR UPDATE",
            )
            .bind(player_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
            .ok_or_else(|| ReputationError::InvalidData("Match participant not found".to_string()))?;
            let previous_skill: i64 = current
                .try_get("skill_score")
                .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
            let previous_fair_play: i64 = current
                .try_get("fair_play_score")
                .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
            let previous_skill = previous_skill.clamp(MIN_REPUTATION_SCORE, MAX_SKILL_SCORE);
            let previous_fair_play =
                previous_fair_play.clamp(MIN_REPUTATION_SCORE, MAX_FAIR_PLAY_SCORE);
            let next_skill = previous_skill
                .checked_add(i64::from(skill_delta))
                .ok_or_else(|| ReputationError::InvalidData("Skill score overflow".to_string()))?
                .clamp(MIN_REPUTATION_SCORE, MAX_SKILL_SCORE);
            let next_fair_play = previous_fair_play
                .checked_add(i64::from(fair_play_delta))
                .ok_or_else(|| ReputationError::InvalidData("Fair-play score overflow".to_string()))?
                .clamp(MIN_REPUTATION_SCORE, MAX_FAIR_PLAY_SCORE);
            let applied_skill_delta = (next_skill - previous_skill) as i32;
            let applied_fair_play_delta = (next_fair_play - previous_fair_play) as i32;

            sqlx::query(
                "UPDATE users SET skill_score = $1, fair_play_score = $2, \
                 reputation_scoring_version = $3, reputation_last_updated = NOW(), \
                 updated_at = NOW() WHERE id = $4",
            )
            .bind(next_skill as i32)
            .bind(next_fair_play as i32)
            .bind(REPUTATION_SCORING_VERSION)
            .bind(player_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

            // Record reputation event
            sqlx::query!(
                r#"
                INSERT INTO reputation_events (
                    user_id, event_type, skill_delta, fair_play_delta,
                    match_authority_id, scoring_version
                ) VALUES ($1, $2, $3, $4, $5, $6)
                "#,
                player_id,
                "match_completion",
                applied_skill_delta,
                applied_fair_play_delta,
                match_id,
                REPUTATION_SCORING_VERSION
            )
            .execute(&mut *tx)
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

            // Check if player should be flagged as bad actor
            let rep = sqlx::query!(
                r#"SELECT fair_play_score FROM users WHERE id = $1"#,
                player_id
            )
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

            if rep.fair_play_score < 30 {
                sqlx::query!(
                    r#"UPDATE users SET is_bad_actor = true WHERE id = $1"#,
                    player_id
                )
                .execute(&mut *tx)
                .await
                .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

                warn!("Player {} flagged as bad actor (fair_play < 30)", player_id);
            }
        }

        tx.commit()
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        info!(
            "Updated reputation for {} players in match {}",
            participant_ids.len(),
            match_id
        );

        Ok(())
    }

    /// Apply anti-cheat penalty to a player
    pub async fn apply_anticheat_penalty(
        &self,
        user_id: uuid::Uuid,
        match_id: uuid::Uuid,
        penalty: i32,
        transaction_hash: Option<String>,
    ) -> Result<(), ReputationError> {
        if penalty <= 0 {
            return Err(ReputationError::InvalidData(
                "Penalty must be positive".to_string(),
            ));
        }
        let mut tx = self
            .db_pool
            .begin()
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        let previous_fair_play: i64 = sqlx::query_scalar(
            "SELECT COALESCE(fair_play_score, 100)::bigint FROM users WHERE id = $1 FOR UPDATE",
        )
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
        .ok_or_else(|| ReputationError::InvalidData("User not found".to_string()))?;

        // Apply penalty to fair_play score (capped at 0)
        let result = sqlx::query!(
            r#"
            UPDATE users
            SET 
                fair_play_score = LEAST($2::bigint, GREATEST($3::bigint, COALESCE(fair_play_score, 100)::bigint - $1::bigint))::integer,
                anticheat_flags_count = LEAST(2147483647::bigint, COALESCE(anticheat_flags_count, 0)::bigint + 1)::integer,
                reputation_scoring_version = $5,
                reputation_last_updated = NOW(),
                updated_at = NOW(),
                is_bad_actor = CASE 
                    WHEN COALESCE(fair_play_score, 100)::bigint - $1::bigint < 30 THEN true
                    ELSE is_bad_actor
                END
            WHERE id = $4
            RETURNING fair_play_score
            "#,
            penalty,
            MAX_FAIR_PLAY_SCORE,
            MIN_REPUTATION_SCORE,
            user_id,
            REPUTATION_SCORING_VERSION
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let previous_fair_play = previous_fair_play.clamp(MIN_REPUTATION_SCORE, MAX_FAIR_PLAY_SCORE);
        let applied_delta = i64::from(result.fair_play_score.unwrap_or(0)) - previous_fair_play;

        // Record penalty event
        sqlx::query!(
            r#"
            INSERT INTO reputation_events (
                user_id, event_type, skill_delta, fair_play_delta, match_id, 
                transaction_hash, metadata, scoring_version
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            "#,
            user_id,
            "anticheat_penalty",
            0,
            applied_delta as i32,
            match_id,
            transaction_hash,
            serde_json::json!({"requested_penalty": penalty}).to_string(),
            REPUTATION_SCORING_VERSION
        )
        .execute(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        tx.commit()
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        warn!(
            "Applied anti-cheat penalty {} to user {} (new fair_play: {})",
            penalty, user_id, result.fair_play_score.unwrap_or(0)
        );

        Ok(())
    }

    /// Get list of players filtered by reputation (for matchmaking)
    pub async fn filter_bad_actors(
        &self,
        candidate_ids: &[uuid::Uuid],
        min_fair_play: i32,
    ) -> Result<Vec<uuid::Uuid>, ReputationError> {
        if candidate_ids.is_empty() {
            return Ok(vec![]);
        }

        let filtered = sqlx::query!(
            r#"
            SELECT id
            FROM users
            WHERE id = ANY($1)
              AND is_bad_actor = false
              AND COALESCE(fair_play_score, 100) >= $2
            "#,
            candidate_ids,
            min_fair_play
        )
        .fetch_all(&self.db_pool)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
        .into_iter()
        .map(|r| r.id)
        .collect();

        Ok(filtered)
    }

    /// Get contract address from registry
    pub async fn get_contract_address(&self, contract_name: &str) -> Result<String, ReputationError> {
        let record = sqlx::query!(
            r#"SELECT contract_address FROM soroban_contracts WHERE contract_name = $1 AND is_active = true"#,
            contract_name
        )
        .fetch_optional(&self.db_pool)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
        .ok_or_else(|| ReputationError::ContractNotFound(contract_name.to_string()))?;

        Ok(record.contract_address)
    }

    /// Apply time-based decay to player reputation (periodic maintenance)
    pub async fn apply_decay(&self, user_id: uuid::Uuid, decay_amount: i32) -> Result<(), ReputationError> {
        if decay_amount < 0 {
            return Err(ReputationError::InvalidData(
                "Decay amount cannot be negative".to_string(),
            ));
        }

        let mut tx = self
            .db_pool
            .begin()
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let previous = sqlx::query(
            "SELECT COALESCE(skill_score, 1000)::bigint AS skill_score, \
             COALESCE(fair_play_score, 100)::bigint AS fair_play_score \
             FROM users WHERE id = $1 FOR UPDATE",
        )
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?
        .ok_or_else(|| ReputationError::InvalidData("User not found".to_string()))?;
        let previous_skill: i64 = previous
            .try_get("skill_score")
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let previous_fair_play: i64 = previous
            .try_get("fair_play_score")
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;
        let previous_skill = previous_skill.clamp(MIN_REPUTATION_SCORE, MAX_SKILL_SCORE);
        let previous_fair_play =
            previous_fair_play.clamp(MIN_REPUTATION_SCORE, MAX_FAIR_PLAY_SCORE);
        let next_skill = (previous_skill - i64::from(decay_amount))
            .clamp(MIN_REPUTATION_SCORE, MAX_SKILL_SCORE);
        let next_fair_play = (previous_fair_play - i64::from(decay_amount))
            .clamp(MIN_REPUTATION_SCORE, MAX_FAIR_PLAY_SCORE);
        let skill_delta = (next_skill - previous_skill) as i32;
        let fair_play_delta = (next_fair_play - previous_fair_play) as i32;

        sqlx::query(
            "UPDATE users SET skill_score = $1, fair_play_score = $2, \
             reputation_scoring_version = $3, reputation_last_updated = NOW(), \
             updated_at = NOW() WHERE id = $4",
        )
        .bind(next_skill as i32)
        .bind(next_fair_play as i32)
        .bind(REPUTATION_SCORING_VERSION)
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        sqlx::query(
            "INSERT INTO reputation_events (user_id, event_type, skill_delta, fair_play_delta, scoring_version) \
             VALUES ($1, 'decay', $2, $3, $4)",
        )
        .bind(user_id)
        .bind(skill_delta)
        .bind(fair_play_delta)
        .bind(REPUTATION_SCORING_VERSION)
        .execute(&mut *tx)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        tx.commit()
            .await
            .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        debug!("Applied decay {} to user {}", decay_amount, user_id);

        Ok(())
    }

    /// Get reputation statistics for monitoring
    pub async fn get_reputation_stats(&self) -> Result<ReputationStats, ReputationError> {
        let stats = sqlx::query!(
            r#"
            SELECT 
                COUNT(*) FILTER (WHERE is_bad_actor = true) as bad_actors_count,
                COUNT(*) FILTER (WHERE COALESCE(fair_play_score, 100) < 50) as low_fair_play_count,
                COUNT(*) FILTER (WHERE COALESCE(skill_score, 1000) >= 1500) as high_skill_count,
                AVG(COALESCE(skill_score, 1000)) as avg_skill,
                AVG(COALESCE(fair_play_score, 100)) as avg_fair_play
            FROM users
            WHERE is_active = true
            "#
        )
        .fetch_one(&self.db_pool)
        .await
        .map_err(|e| ReputationError::DatabaseError(e.to_string()))?;

        Ok(ReputationStats {
            bad_actors_count: stats.bad_actors_count.unwrap_or(0) as i64,
            low_fair_play_count: stats.low_fair_play_count.unwrap_or(0) as i64,
            high_skill_count: stats.high_skill_count.unwrap_or(0) as i64,
            avg_skill: stats.avg_skill.unwrap_or(1000.0),
            avg_fair_play: stats.avg_fair_play.unwrap_or(100.0),
        })
    }
}

/// Reputation statistics for monitoring
#[derive(Debug, Clone)]
pub struct ReputationStats {
    pub bad_actors_count: i64,
    pub low_fair_play_count: i64,
    pub high_skill_count: i64,
    pub avg_skill: f64,
    pub avg_fair_play: f64,
}

#[cfg(test)]
mod tests {}
