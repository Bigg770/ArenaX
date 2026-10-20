DROP TABLE reputation_match_applications;

ALTER TABLE reputation_events
DROP COLUMN match_authority_id,
DROP COLUMN scoring_version;

ALTER TABLE users
DROP COLUMN reputation_scoring_version;