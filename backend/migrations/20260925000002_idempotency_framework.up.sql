-- Idempotency Framework and User/Elo schema alignment

-- Idempotency Keys Table
CREATE TABLE IF NOT EXISTS idempotency_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key VARCHAR(255) NOT NULL UNIQUE,
    request_hash VARCHAR(64) NOT NULL,
    response_status SMALLINT NOT NULL,
    response_headers JSONB,
    response_body JSONB,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    used_at TIMESTAMP WITH TIME ZONE,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    request_method VARCHAR(10),
    request_path TEXT,
    request_user_agent TEXT,
    request_ip_address INET
);

-- Idempotency Configuration Table
CREATE TABLE IF NOT EXISTS idempotency_configs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    route_pattern TEXT NOT NULL UNIQUE,
    enabled BOOLEAN NOT NULL DEFAULT true,
    ttl_seconds INTEGER NOT NULL DEFAULT 86400,
    max_response_size_kb INTEGER NOT NULL DEFAULT 1024,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Request Logs Table
CREATE TABLE IF NOT EXISTS request_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key VARCHAR(255) REFERENCES idempotency_keys(key) ON DELETE SET NULL,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    method VARCHAR(10) NOT NULL,
    path TEXT NOT NULL,
    query_params TEXT,
    headers JSONB,
    body_hash VARCHAR(64),
    response_status SMALLINT,
    response_size_bytes INTEGER,
    processing_time_ms INTEGER,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    client_ip INET,
    user_agent TEXT
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_key ON idempotency_keys(key);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_expires_at ON idempotency_keys(expires_at);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_used_at ON idempotency_keys(used_at);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_created_at ON idempotency_keys(created_at);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_user_id ON idempotency_keys(user_id);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_request_hash ON idempotency_keys(request_hash);
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_key_expires ON idempotency_keys(key, expires_at);

CREATE INDEX IF NOT EXISTS idx_idempotency_configs_route_pattern ON idempotency_configs(route_pattern);
CREATE INDEX IF NOT EXISTS idx_idempotency_configs_enabled ON idempotency_configs(enabled);

CREATE INDEX IF NOT EXISTS idx_request_logs_idempotency_key ON request_logs(idempotency_key);
CREATE INDEX IF NOT EXISTS idx_request_logs_user_id ON request_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_request_logs_created_at ON request_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_request_logs_method_path ON request_logs(method, path);
CREATE INDEX IF NOT EXISTS idx_request_logs_response_status ON request_logs(response_status);
CREATE INDEX IF NOT EXISTS idx_request_logs_user_created ON request_logs(user_id, created_at DESC);

-- Analytics Views
CREATE OR REPLACE VIEW active_idempotency_keys AS
SELECT 
    ik.*,
    CASE 
        WHEN ik.used_at IS NULL THEN 'pending'
        WHEN ik.expires_at <= NOW() THEN 'expired'
        ELSE 'used'
    END as status,
    EXTRACT(EPOCH FROM (ik.expires_at - NOW()))::INTEGER as seconds_until_expiry
FROM idempotency_keys ik
WHERE ik.expires_at > NOW()
ORDER BY ik.created_at DESC;

CREATE OR REPLACE VIEW idempotency_usage_stats AS
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    COUNT(*) as total_keys,
    COUNT(CASE WHEN used_at IS NOT NULL THEN 1 END) as used_keys,
    COUNT(CASE WHEN used_at IS NULL THEN 1 END) as unused_keys,
    AVG(EXTRACT(EPOCH FROM (used_at - created_at)))::INTEGER as avg_time_to_use_seconds
FROM idempotency_keys
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY DATE_TRUNC('hour', created_at)
ORDER BY hour DESC;

CREATE OR REPLACE VIEW idempotency_conflicts AS
SELECT 
    key,
    COUNT(*) as usage_count,
    MIN(created_at) as first_used,
    MAX(created_at) as last_used,
    COUNT(DISTINCT request_hash) as unique_hashes,
    CASE 
        WHEN COUNT(DISTINCT request_hash) > 1 THEN true 
        ELSE false 
    END as has_conflict
FROM idempotency_keys
WHERE created_at >= NOW() - INTERVAL '24 hours'
GROUP BY key
HAVING COUNT(*) > 1
ORDER BY usage_count DESC, has_conflict DESC;

CREATE OR REPLACE VIEW route_idempotency_stats AS
SELECT 
    rl.path,
    COUNT(*) as total_requests,
    COUNT(DISTINCT rl.idempotency_key) as unique_keys,
    COUNT(DISTINCT rl.user_id) as unique_users,
    AVG(rl.processing_time_ms)::INTEGER as avg_processing_time_ms,
    COUNT(CASE WHEN rl.response_status >= 400 THEN 1 END) as error_count,
    COUNT(CASE WHEN ik.key IS NOT NULL THEN 1 END) as idempotent_requests
FROM request_logs rl
LEFT JOIN idempotency_keys ik ON rl.idempotency_key = ik.key
WHERE rl.created_at >= NOW() - INTERVAL '24 hours'
GROUP BY rl.path
ORDER BY total_requests DESC;

-- Helper Functions
CREATE OR REPLACE FUNCTION cleanup_expired_idempotency_keys()
RETURNS INTEGER AS $$
DECLARE
    cleaned_count INTEGER := 0;
    step_count INTEGER := 0;
BEGIN
    DELETE FROM idempotency_keys 
    WHERE expires_at <= NOW()
    AND used_at IS NOT NULL;
    
    GET DIAGNOSTICS step_count = ROW_COUNT;
    cleaned_count := cleaned_count + step_count;
    
    DELETE FROM idempotency_keys 
    WHERE used_at IS NULL 
    AND created_at < NOW() - INTERVAL '1 hour';
    
    GET DIAGNOSTICS step_count = ROW_COUNT;
    cleaned_count := cleaned_count + step_count;
    
    RETURN cleaned_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_idempotency_stats(
    start_time TIMESTAMP WITH TIME ZONE DEFAULT NOW() - INTERVAL '24 hours',
    end_time TIMESTAMP WITH TIME ZONE DEFAULT NOW()
)
RETURNS TABLE(
    total_keys BIGINT,
    active_keys BIGINT,
    used_keys BIGINT,
    conflicts_detected BIGINT,
    avg_ttl_seconds NUMERIC,
    cache_hit_rate NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*) as total_keys,
        COUNT(CASE WHEN expires_at > NOW() THEN 1 END) as active_keys,
        COUNT(CASE WHEN used_at IS NOT NULL THEN 1 END) as used_keys,
        (SELECT COUNT(*) FROM idempotency_conflicts WHERE has_conflict = true) as conflicts_detected,
        AVG(EXTRACT(EPOCH FROM (expires_at - created_at))) as avg_ttl_seconds,
        CASE 
            WHEN COUNT(*) > 0 THEN 
                COUNT(CASE WHEN used_at IS NOT NULL THEN 1 END)::NUMERIC / COUNT(*)::NUMERIC 
            ELSE 0 
        END as cache_hit_rate
    FROM idempotency_keys
    WHERE created_at BETWEEN start_time AND end_time;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_idempotency_key(key TEXT)
RETURNS TABLE(
    is_valid BOOLEAN,
    error_message TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        CASE 
            WHEN length(key) < 8 THEN false
            WHEN length(key) > 255 THEN false
            WHEN key !~ '^[a-zA-Z0-9_-]+$' THEN false
            ELSE true
        END as is_valid,
        CASE 
            WHEN length(key) < 8 THEN 'Key must be at least 8 characters'
            WHEN length(key) > 255 THEN 'Key must be less than 255 characters'
            WHEN key !~ '^[a-zA-Z0-9_-]+$' THEN 'Key can only contain alphanumeric characters, hyphens, and underscores'
            ELSE NULL
        END as error_message;
END;
$$ LANGUAGE plpgsql;

-- Triggers
CREATE OR REPLACE FUNCTION update_idempotency_config_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_idempotency_config_updated_at ON idempotency_configs;
CREATE TRIGGER update_idempotency_config_updated_at 
    BEFORE UPDATE ON idempotency_configs 
    FOR EACH ROW EXECUTE FUNCTION update_idempotency_config_updated_at();

CREATE OR REPLACE FUNCTION log_idempotency_request()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.used_at IS NOT NULL AND OLD.used_at IS NULL THEN
        INSERT INTO request_logs (
            idempotency_key, 
            method, 
            path, 
            response_status,
            created_at
        ) VALUES (
            NEW.key,
            NEW.request_method,
            NEW.request_path,
            NEW.response_status,
            NEW.created_at
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS log_idempotency_request ON idempotency_keys;
CREATE TRIGGER log_idempotency_request 
    AFTER UPDATE ON idempotency_keys 
    FOR EACH ROW EXECUTE FUNCTION log_idempotency_request();

-- Default Configs
INSERT INTO idempotency_configs (route_pattern, enabled, ttl_seconds, max_response_size_kb) VALUES
('/api/payments/create', true, 86400, 1024),
('/api/payments/refund', true, 86400, 1024),
('/api/wallets/deposit', true, 86400, 512),
('/api/wallets/withdraw', true, 86400, 512),
('/api/tournaments/join', true, 86400, 256),
('/api/matchmaking/join', true, 3600, 256)
ON CONFLICT (route_pattern) DO NOTHING;

-- User model alignment
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash VARCHAR(255);
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_image_url TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS reputation_score INTEGER DEFAULT 1000;
ALTER TABLE users ADD COLUMN IF NOT EXISTS stellar_account_id UUID;
ALTER TABLE users ADD COLUMN IF NOT EXISTS stellar_public_key VARCHAR(56);
ALTER TABLE users ADD COLUMN IF NOT EXISTS total_earnings NUMERIC(20, 7) DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_banned BOOLEAN DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS banned_until TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS device_fingerprint TEXT;
UPDATE users SET is_verified = false WHERE is_verified IS NULL;
ALTER TABLE users ALTER COLUMN is_verified SET NOT NULL;
UPDATE users SET is_active = true WHERE is_active IS NULL;
ALTER TABLE users ALTER COLUMN is_active SET NOT NULL;
UPDATE users SET role = 'user' WHERE role IS NULL;
ALTER TABLE users ALTER COLUMN role SET NOT NULL;

-- User ELO alignment
ALTER TABLE user_elo ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE user_elo ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Matches alignment
ALTER TABLE matches ADD COLUMN IF NOT EXISTS scheduled_at TIMESTAMPTZ;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS round_number INTEGER;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS match_number INTEGER;
ALTER TABLE matches ALTER COLUMN player1_id SET NOT NULL;
ALTER TABLE matches ALTER COLUMN match_type SET NOT NULL;
ALTER TABLE matches ALTER COLUMN status SET NOT NULL;

-- Align tournaments
ALTER TABLE tournaments ALTER COLUMN entry_fee SET NOT NULL;
ALTER TABLE tournaments ALTER COLUMN entry_fee_currency SET NOT NULL;
ALTER TABLE tournaments ALTER COLUMN prize_pool SET NOT NULL;
ALTER TABLE tournaments ALTER COLUMN prize_pool_currency SET NOT NULL;
ALTER TABLE tournaments ALTER COLUMN status SET NOT NULL;
ALTER TABLE tournaments ALTER COLUMN bracket_type SET NOT NULL;

-- Align tournament_participants
ALTER TABLE tournament_participants ALTER COLUMN tournament_id SET NOT NULL;
ALTER TABLE tournament_participants ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE tournament_participants ALTER COLUMN entry_fee_paid SET NOT NULL;
ALTER TABLE tournament_participants ALTER COLUMN status SET NOT NULL;

-- Align tournament_rounds
ALTER TABLE tournament_rounds ALTER COLUMN tournament_id SET NOT NULL;
ALTER TABLE tournament_rounds ALTER COLUMN status SET NOT NULL;

-- Align tournament_matches
ALTER TABLE tournament_matches ALTER COLUMN tournament_id SET NOT NULL;
ALTER TABLE tournament_matches ALTER COLUMN round_id SET NOT NULL;
ALTER TABLE tournament_matches ALTER COLUMN player1_id SET NOT NULL;
ALTER TABLE tournament_matches ALTER COLUMN status SET NOT NULL;

-- Align prize_pools
ALTER TABLE prize_pools ALTER COLUMN tournament_id SET NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN total_amount SET NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN currency SET NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN stellar_account SET NOT NULL;
ALTER TABLE prize_pools ALTER COLUMN distribution_percentages SET NOT NULL;

-- Align wallets
ALTER TABLE wallets ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE wallets ALTER COLUMN balance SET NOT NULL;
ALTER TABLE wallets ALTER COLUMN escrow_balance SET NOT NULL;
ALTER TABLE wallets ALTER COLUMN currency SET NOT NULL;
ALTER TABLE wallets ALTER COLUMN is_active SET NOT NULL;

-- Align transactions
ALTER TABLE transactions ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE transactions ALTER COLUMN currency SET NOT NULL;
ALTER TABLE transactions ALTER COLUMN status SET NOT NULL;
UPDATE transactions SET description = '' WHERE description IS NULL;
ALTER TABLE transactions ALTER COLUMN description SET NOT NULL;

-- Align matchmaking_queue
ALTER TABLE matchmaking_queue ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE matchmaking_queue ALTER COLUMN status SET NOT NULL;

-- Align match_scores
ALTER TABLE match_scores ALTER COLUMN match_id SET NOT NULL;
ALTER TABLE match_scores ALTER COLUMN player_id SET NOT NULL;
ALTER TABLE match_scores ALTER COLUMN verified SET NOT NULL;

-- Align match_disputes
ALTER TABLE match_disputes ADD COLUMN IF NOT EXISTS resolved_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE match_disputes ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE match_disputes ALTER COLUMN match_id SET NOT NULL;
ALTER TABLE match_disputes ALTER COLUMN disputing_player_id SET NOT NULL;
ALTER TABLE match_disputes ALTER COLUMN status SET NOT NULL;

-- Align user_elo
ALTER TABLE user_elo ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN current_rating SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN peak_rating SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN games_played SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN wins SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN losses SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN draws SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN win_streak SET NOT NULL;
ALTER TABLE user_elo ALTER COLUMN loss_streak SET NOT NULL;

-- Align elo_history
ALTER TABLE elo_history ALTER COLUMN user_id SET NOT NULL;

-- Align stellar_accounts
ALTER TABLE stellar_accounts ALTER COLUMN account_type SET NOT NULL;
ALTER TABLE stellar_accounts ALTER COLUMN is_funded SET NOT NULL;
ALTER TABLE stellar_accounts ALTER COLUMN is_active SET NOT NULL;
ALTER TABLE stellar_accounts ALTER COLUMN balance_xlm SET NOT NULL;

-- Align stellar_transactions
ALTER TABLE stellar_transactions ALTER COLUMN asset_code SET NOT NULL;
ALTER TABLE stellar_transactions ALTER COLUMN status SET NOT NULL;

-- Align api_keys
ALTER TABLE api_keys ALTER COLUMN rotation_interval TYPE BIGINT USING (EXTRACT(EPOCH FROM rotation_interval)::BIGINT);

-- Align api_key_usage_logs
ALTER TABLE api_key_usage_logs ALTER COLUMN scopes_used SET DEFAULT '{}'::text[];
UPDATE api_key_usage_logs SET scopes_used = '{}' WHERE scopes_used IS NULL;
ALTER TABLE api_key_usage_logs ALTER COLUMN scopes_used SET NOT NULL;

-- Align reputation_events
ALTER TABLE reputation_events ALTER COLUMN user_id SET NOT NULL;

