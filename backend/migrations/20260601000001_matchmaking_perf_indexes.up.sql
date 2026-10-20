-- Migration: 20260601000001_matchmaking_perf_indexes
-- Description: Add composite indexes to matchmaking_queue to fix high-latency
--              queries that were doing full-table scans on (game, game_mode, status).
--
-- Query plans / cardinality assumptions (issue #92):
--   * Matchmaker worker hot path filters (game, game_mode, status = 0) and
--     orders by joined_at.  Assumes the waiting set is a small fraction of the
--     table (<< 10%), so a partial index keeps it compact.
--   * Average-wait-time aggregate filters (game, game_mode, status = 1,
--     matched_at IS NOT NULL, joined_at >= ...).  Assumes matched rows are the
--     dominant historical volume, so the partial predicate bounds the scan.
--   * Target latency: matchmaker poll < 20ms p99; stats aggregate < 100ms p99
--     on a seeded dataset of ~1M rows.
--   * Write amplification: three narrow indexes on an append/update-heavy queue;
--     acceptable given the read-heavy worker and stats paths.

-- Composite index used by the background worker's active-game queries and by
-- the stats handler.  Replaces the separate (status) and (game, game_mode)
-- indexes for queries that filter on all three columns.
CREATE INDEX IF NOT EXISTS idx_matchmaking_queue_game_mode_status
    ON matchmaking_queue (game, game_mode, status);

-- Partial index for the common hot path: only waiting entries.
-- Keeps the index small and fast for the matchmaker worker.
-- status INTEGER: 0=waiting, 1=matched, 2=expired, 3=cancelled
CREATE INDEX IF NOT EXISTS idx_matchmaking_queue_waiting
    ON matchmaking_queue (game, game_mode, joined_at)
    WHERE status = 0;

-- Composite index for the average-wait-time aggregate query which filters on
-- (status = 1 (matched), matched_at IS NOT NULL, joined_at >= ...).
CREATE INDEX IF NOT EXISTS idx_matchmaking_queue_matched_stats
    ON matchmaking_queue (game, game_mode, joined_at)
    WHERE status = 1 AND matched_at IS NOT NULL;
