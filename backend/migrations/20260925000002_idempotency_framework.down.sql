-- Revert Idempotency Framework and User/Elo schema alignment

DROP VIEW IF EXISTS route_idempotency_stats;
DROP VIEW IF EXISTS idempotency_conflicts;
DROP VIEW IF EXISTS idempotency_usage_stats;
DROP VIEW IF EXISTS active_idempotency_keys;

DROP TRIGGER IF EXISTS log_idempotency_request ON idempotency_keys;
DROP FUNCTION IF EXISTS log_idempotency_request();
DROP TRIGGER IF EXISTS update_idempotency_config_updated_at ON idempotency_configs;
DROP FUNCTION IF EXISTS update_idempotency_config_updated_at();

DROP FUNCTION IF EXISTS validate_idempotency_key(TEXT);
DROP FUNCTION IF EXISTS get_idempotency_stats(TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE);
DROP FUNCTION IF EXISTS cleanup_expired_idempotency_keys();

DROP TABLE IF EXISTS request_logs;
DROP TABLE IF EXISTS idempotency_configs;
DROP TABLE IF EXISTS idempotency_keys;

ALTER TABLE user_elo DROP COLUMN IF EXISTS updated_at;
ALTER TABLE user_elo DROP COLUMN IF EXISTS created_at;

ALTER TABLE users ALTER COLUMN role DROP NOT NULL;
ALTER TABLE users ALTER COLUMN is_active DROP NOT NULL;
ALTER TABLE users ALTER COLUMN is_verified DROP NOT NULL;
ALTER TABLE users DROP COLUMN IF EXISTS device_fingerprint;
ALTER TABLE users DROP COLUMN IF EXISTS banned_until;
ALTER TABLE users DROP COLUMN IF EXISTS is_banned;
ALTER TABLE users DROP COLUMN IF EXISTS total_earnings;
ALTER TABLE users DROP COLUMN IF EXISTS stellar_public_key;
ALTER TABLE users DROP COLUMN IF EXISTS stellar_account_id;
ALTER TABLE users DROP COLUMN IF EXISTS reputation_score;
ALTER TABLE users DROP COLUMN IF EXISTS profile_image_url;
ALTER TABLE users DROP COLUMN IF EXISTS password_hash;

ALTER TABLE matches ALTER COLUMN status DROP NOT NULL;
ALTER TABLE matches ALTER COLUMN match_type DROP NOT NULL;
ALTER TABLE matches ALTER COLUMN player1_id DROP NOT NULL;
ALTER TABLE matches DROP COLUMN IF EXISTS match_number;
ALTER TABLE matches DROP COLUMN IF EXISTS scheduled_at;

ALTER TABLE match_disputes DROP COLUMN IF EXISTS updated_at;
ALTER TABLE match_disputes DROP COLUMN IF EXISTS resolved_by;
ALTER TABLE match_disputes ALTER COLUMN status DROP NOT NULL;
ALTER TABLE match_disputes ALTER COLUMN disputing_player_id DROP NOT NULL;
ALTER TABLE match_disputes ALTER COLUMN match_id DROP NOT NULL;

ALTER TABLE match_scores ALTER COLUMN verified DROP NOT NULL;
ALTER TABLE match_scores ALTER COLUMN player_id DROP NOT NULL;
ALTER TABLE match_scores ALTER COLUMN match_id DROP NOT NULL;

ALTER TABLE matchmaking_queue ALTER COLUMN status DROP NOT NULL;
ALTER TABLE matchmaking_queue ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE transactions ALTER COLUMN description DROP NOT NULL;
ALTER TABLE transactions ALTER COLUMN status DROP NOT NULL;
ALTER TABLE transactions ALTER COLUMN currency DROP NOT NULL;
ALTER TABLE transactions ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE wallets ALTER COLUMN is_active DROP NOT NULL;
ALTER TABLE wallets ALTER COLUMN currency DROP NOT NULL;
ALTER TABLE wallets ALTER COLUMN escrow_balance DROP NOT NULL;
ALTER TABLE wallets ALTER COLUMN balance DROP NOT NULL;
ALTER TABLE wallets ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE prize_pools ALTER COLUMN distribution_percentages DROP NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN stellar_account DROP NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN currency DROP NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN total_amount DROP NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN tournament_id DROP NOT NULL;

ALTER TABLE tournament_matches ALTER COLUMN status DROP NOT NULL;
ALTER TABLE tournament_matches ALTER COLUMN player1_id DROP NOT NULL;
ALTER TABLE tournament_matches ALTER COLUMN round_id DROP NOT NULL;
ALTER TABLE tournament_matches ALTER COLUMN tournament_id DROP NOT NULL;

ALTER TABLE tournament_rounds ALTER COLUMN status DROP NOT NULL;
ALTER TABLE tournament_rounds ALTER COLUMN tournament_id DROP NOT NULL;

ALTER TABLE tournament_participants ALTER COLUMN status DROP NOT NULL;
ALTER TABLE tournament_participants ALTER COLUMN entry_fee_paid DROP NOT NULL;
ALTER TABLE tournament_participants ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE tournament_participants ALTER COLUMN tournament_id DROP NOT NULL;

ALTER TABLE tournaments ALTER COLUMN bracket_type DROP NOT NULL;
ALTER TABLE tournaments ALTER COLUMN status DROP NOT NULL;
ALTER TABLE tournaments ALTER COLUMN prize_pool_currency DROP NOT NULL;
ALTER TABLE tournaments ALTER COLUMN prize_pool DROP NOT NULL;
ALTER TABLE tournaments ALTER COLUMN entry_fee_currency DROP NOT NULL;
ALTER TABLE tournaments ALTER COLUMN entry_fee DROP NOT NULL;

ALTER TABLE user_elo ALTER COLUMN loss_streak DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN win_streak DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN draws DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN losses DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN wins DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN games_played DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN peak_rating DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN current_rating DROP NOT NULL;
ALTER TABLE user_elo ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE elo_history ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE stellar_accounts ALTER COLUMN balance_xlm DROP NOT NULL;
ALTER TABLE stellar_accounts ALTER COLUMN is_active DROP NOT NULL;
ALTER TABLE stellar_accounts ALTER COLUMN is_funded DROP NOT NULL;
ALTER TABLE stellar_accounts ALTER COLUMN account_type DROP NOT NULL;

ALTER TABLE stellar_transactions ALTER COLUMN status DROP NOT NULL;
ALTER TABLE stellar_transactions ALTER COLUMN asset_code DROP NOT NULL;

ALTER TABLE api_keys ALTER COLUMN rotation_interval TYPE INTERVAL USING (rotation_interval || ' seconds')::INTERVAL;
ALTER TABLE api_key_usage_logs ALTER COLUMN scopes_used DROP NOT NULL;
ALTER TABLE reputation_events ALTER COLUMN user_id DROP NOT NULL;

