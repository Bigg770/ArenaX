-- Optimize Leaderboard Queries — Issue #827
-- Add indexes to improve query performance for leaderboard endpoints

-- Index for leaderboard queries filtering by game and period
CREATE INDEX IF NOT EXISTS idx_leaderboards_game_period_ranking 
ON leaderboards(game, period, ranking) 
WHERE period IN ('all_time', 'weekly', 'monthly');

-- Index for user_elo queries to optimize ranking calculations
CREATE INDEX IF NOT EXISTS idx_user_elo_game_rating 
ON user_elo(game, current_rating DESC);

-- Index for matches queries to optimize player stats calculations
CREATE INDEX IF NOT EXISTS idx_matches_players_status 
ON matches(player1_id, player2_id, game_mode, status) 
WHERE status = 3;

-- Separate index for winner lookups
CREATE INDEX IF NOT EXISTS idx_matches_winner_game 
ON matches(winner_id, game_mode, status) 
WHERE status = 3;

-- Composite index for leaderboard user lookups
CREATE INDEX IF NOT EXISTS idx_leaderboards_user_game_period 
ON leaderboards(user_id, game, period);

-- Index for rank history queries
-- NOTE: no partial predicate here — NOW() is VOLATILE, which Postgres
-- rejects in index predicates ("functions in index predicate must be
-- marked IMMUTABLE"). Index all rows instead.
CREATE INDEX IF NOT EXISTS idx_leaderboards_history 
ON leaderboards(user_id, game, updated_at DESC);

-- Issue #92: tournament browse — filter by status/game, order by start_time
CREATE INDEX IF NOT EXISTS idx_tournaments_status_game_start 
ON tournaments(status, game, start_time DESC);

-- Issue #92: matchmaking queue — match open entries by game/mode ordered by enqueue time
CREATE INDEX IF NOT EXISTS idx_matchmaking_queue_game_mode_enqueued 
ON matchmaking_queue(game, game_mode, enqueued_at) 
WHERE status = 'waiting';

-- Issue #92: wallet history — per-user ledger ordered by created_at
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_user_created 
ON wallet_transactions(user_id, created_at DESC);

-- Issue #92: dispute queues — open disputes by status ordered by created_at
CREATE INDEX IF NOT EXISTS idx_disputes_status_created 
ON disputes(status, created_at) 
WHERE status IN ('open', 'under_review');

-- Add statistics for query planner optimization
ANALYZE leaderboards;
ANALYZE user_elo;
ANALYZE matches;
ANALYZE users;
ANALYZE tournaments;
ANALYZE matchmaking_queue;
ANALYZE wallet_transactions;
ANALYZE disputes;
