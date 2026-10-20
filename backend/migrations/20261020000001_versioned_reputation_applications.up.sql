ALTER TABLE users
ADD COLUMN reputation_scoring_version INTEGER NOT NULL DEFAULT 0;

ALTER TABLE reputation_events
ADD COLUMN scoring_version INTEGER NOT NULL DEFAULT 0,
ADD COLUMN match_authority_id UUID REFERENCES match_authority(id) ON DELETE SET NULL;

WITH previous_scores AS (
    SELECT id,
           COALESCE(skill_score, 1000) AS skill_score,
           COALESCE(fair_play_score, 100) AS fair_play_score
    FROM users
), normalized_scores AS (
    UPDATE users AS u
    SET skill_score = LEAST(3000, GREATEST(0, COALESCE(u.skill_score, 1000))),
        fair_play_score = LEAST(100, GREATEST(0, COALESCE(u.fair_play_score, 100))),
        reputation_scoring_version = 1
    FROM previous_scores
    WHERE u.id = previous_scores.id
    RETURNING u.id, u.skill_score, u.fair_play_score
)
INSERT INTO reputation_events (
    user_id, event_type, skill_delta, fair_play_delta, scoring_version
)
SELECT normalized_scores.id,
       'score_normalization',
       normalized_scores.skill_score - previous_scores.skill_score,
       normalized_scores.fair_play_score - previous_scores.fair_play_score,
       1
FROM normalized_scores
JOIN previous_scores ON previous_scores.id = normalized_scores.id
WHERE normalized_scores.skill_score <> previous_scores.skill_score
   OR normalized_scores.fair_play_score <> previous_scores.fair_play_score;

CREATE TABLE reputation_match_applications (
    match_id UUID NOT NULL REFERENCES match_authority(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scoring_version INTEGER NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (match_id, user_id, scoring_version)
);

COMMENT ON TABLE reputation_match_applications IS
    'Idempotency ledger preventing duplicate match reputation updates per scoring version';