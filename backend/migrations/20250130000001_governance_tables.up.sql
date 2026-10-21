-- Governance Multisig Tables Migration
-- Creates tables for tracking governance proposals, approvals, and chain synchronization

-- ============================================================================
-- Governance Proposals Table
-- ============================================================================
-- Tracks all governance proposals submitted through the multisig contract

CREATE TABLE IF NOT EXISTS governance_proposals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- On-chain proposal ID (hex-encoded 32 bytes, e.g., "0x1234...")
    proposal_id VARCHAR(66) UNIQUE NOT NULL,
    -- Target contract address (Stellar contract ID)
    target_contract VARCHAR(56) NOT NULL,
    -- Function name to invoke on the target
    function VARCHAR(64) NOT NULL,
    -- Function arguments as JSON (XDR-decoded for readability)
    args JSONB NOT NULL DEFAULT '{}',
    -- Human-readable description of the proposal
    description TEXT,
    -- Current proposal status
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'EXECUTED', 'CANCELLED', 'FAILED')),
    -- Address of the signer who created the proposal
    proposer VARCHAR(56) NOT NULL,
    -- When the proposal was created in our database
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Earliest time the proposal can be executed (if time-locked)
    execute_after TIMESTAMPTZ,
    -- When the proposal was executed (if executed)
    executed_at TIMESTAMPTZ,
    -- Hash of the last blockchain transaction related to this proposal
    last_chain_tx VARCHAR(66)
);

-- Index for querying by status
CREATE INDEX IF NOT EXISTS idx_governance_proposals_status
    ON governance_proposals(status);

-- Index for querying by proposer
CREATE INDEX IF NOT EXISTS idx_governance_proposals_proposer
    ON governance_proposals(proposer);

-- Index for time-based queries
CREATE INDEX IF NOT EXISTS idx_governance_proposals_created_at
    ON governance_proposals(created_at DESC);

-- ============================================================================
-- Governance Approvals Table
-- ============================================================================
-- Tracks individual signer approvals for proposals

CREATE TABLE IF NOT EXISTS governance_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Reference to the proposal being approved
    proposal_id VARCHAR(66) NOT NULL REFERENCES governance_proposals(proposal_id) ON DELETE CASCADE,
    -- Address of the signer who approved
    signer VARCHAR(56) NOT NULL,
    -- Hash of the approval transaction on chain
    chain_tx VARCHAR(66),
    -- When the approval was recorded
    approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Each signer can only approve once per proposal
    UNIQUE(proposal_id, signer)
);

-- Index for querying approvals by proposal
CREATE INDEX IF NOT EXISTS idx_governance_approvals_proposal
    ON governance_approvals(proposal_id);

-- Index for querying approvals by signer
CREATE INDEX IF NOT EXISTS idx_governance_approvals_signer
    ON governance_approvals(signer);

-- ============================================================================
-- Governance Chain Sync Table
-- ============================================================================
-- Audit log of all blockchain transactions related to governance

CREATE TABLE IF NOT EXISTS governance_chain_sync (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Proposal ID this sync relates to
    proposal_id VARCHAR(66) NOT NULL,
    -- Type of operation (CREATE, APPROVE, REVOKE, EXECUTE, CANCEL)
    operation VARCHAR(32) NOT NULL
        CHECK (operation IN ('CREATE', 'APPROVE', 'REVOKE', 'EXECUTE', 'CANCEL')),
    -- Transaction hash on the blockchain
    tx_hash VARCHAR(66) NOT NULL,
    -- Status of the transaction
    tx_status VARCHAR(20) NOT NULL
        CHECK (tx_status IN ('PENDING', 'SUCCESS', 'FAILED')),
    -- When this sync record was created
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for querying by proposal
CREATE INDEX IF NOT EXISTS idx_governance_chain_sync_proposal
    ON governance_chain_sync(proposal_id);

-- Index for querying by transaction hash
CREATE INDEX IF NOT EXISTS idx_governance_chain_sync_tx_hash
    ON governance_chain_sync(tx_hash);

-- Index for time-based queries
CREATE INDEX IF NOT EXISTS idx_governance_chain_sync_synced_at
    ON governance_chain_sync(synced_at DESC);

-- ============================================================================
-- Operator Audit Log Table (append-only, tamper-evident hash chain)
-- ============================================================================
-- Records privileged operator actions (moderation, dispute resolution,
-- account suspension, feature-flag and payout interventions) with actor,
-- reason, target and before/after metadata. Credentials and private evidence
-- are intentionally excluded from the metadata payload.

CREATE TABLE IF NOT EXISTS operator_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Monotonic sequence used to order the hash chain
    seq BIGSERIAL UNIQUE NOT NULL,
    -- Authenticated operator who performed the action
    actor_id VARCHAR(128) NOT NULL,
    -- Role asserted at action time (e.g. ADMIN, MODERATOR, SUPPORT)
    actor_role VARCHAR(32) NOT NULL,
    -- Category of privileged action
    action VARCHAR(64) NOT NULL
        CHECK (action IN (
            'MODERATION',
            'DISPUTE_RESOLUTION',
            'ACCOUNT_SUSPENSION',
            'FEATURE_FLAG',
            'PAYOUT_INTERVENTION'
        )),
    -- Type of the affected entity (e.g. user, dispute, payout, flag)
    target_type VARCHAR(64) NOT NULL,
    -- Identifier of the affected entity
    target_id VARCHAR(128) NOT NULL,
    -- Operator-supplied justification (required where policy demands it)
    reason TEXT,
    -- Redacted before/after state (no credentials or private evidence)
    before_state JSONB NOT NULL DEFAULT '{}',
    after_state JSONB NOT NULL DEFAULT '{}',
    -- Hash of the previous record in the chain (NULL for genesis)
    prev_hash VARCHAR(64),
    -- Hash of this record's canonical payload chained with prev_hash
    record_hash VARCHAR(64) NOT NULL,
    -- When the action was recorded
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for searching by actor
CREATE INDEX IF NOT EXISTS idx_operator_audit_log_actor
    ON operator_audit_log(actor_id);

-- Index for searching by action category
CREATE INDEX IF NOT EXISTS idx_operator_audit_log_action
    ON operator_audit_log(action);

-- Index for searching by target
CREATE INDEX IF NOT EXISTS idx_operator_audit_log_target
    ON operator_audit_log(target_type, target_id);

-- Index for time-based queries
CREATE INDEX IF NOT EXISTS idx_operator_audit_log_created_at
    ON operator_audit_log(created_at DESC);

-- Enforce append-only semantics: block UPDATE and DELETE on audit records
CREATE OR REPLACE FUNCTION operator_audit_log_block_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'operator_audit_log is append-only; % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_operator_audit_log_no_update ON operator_audit_log;
CREATE TRIGGER trg_operator_audit_log_no_update
    BEFORE UPDATE ON operator_audit_log
    FOR EACH ROW EXECUTE FUNCTION operator_audit_log_block_mutation();

DROP TRIGGER IF EXISTS trg_operator_audit_log_no_delete ON operator_audit_log;
CREATE TRIGGER trg_operator_audit_log_no_delete
    BEFORE DELETE ON operator_audit_log
    FOR EACH ROW EXECUTE FUNCTION operator_audit_log_block_mutation();

-- ============================================================================
-- Views
-- ============================================================================

-- View for proposals with approval counts
CREATE OR REPLACE VIEW v_governance_proposals_with_approvals AS
SELECT
    p.*,
    COALESCE(a.approval_count, 0) as approval_count,
    a.approvers
FROM governance_proposals p
LEFT JOIN (
    SELECT
        proposal_id,
        COUNT(*) as approval_count,
        ARRAY_AGG(signer ORDER BY approved_at) as approvers
    FROM governance_approvals
    GROUP BY proposal_id
) a ON p.proposal_id = a.proposal_id;

-- View for pending proposals that can be executed (have enough approvals)
-- Note: This would need to know the current threshold from the contract
-- For now, we create a simple view showing pending proposals with approvals
CREATE OR REPLACE VIEW v_governance_pending_proposals AS
SELECT
    p.proposal_id,
    p.target_contract,
    p.function,
    p.description,
    p.proposer,
    p.created_at,
    p.execute_after,
    COALESCE(a.approval_count, 0) as approval_count,
    a.approvers
FROM governance_proposals p
LEFT JOIN (
    SELECT
        proposal_id,
        COUNT(*) as approval_count,
        ARRAY_AGG(signer ORDER BY approved_at) as approvers
    FROM governance_approvals
    GROUP BY proposal_id
) a ON p.proposal_id = a.proposal_id
WHERE p.status = 'PENDING' OR p.status = 'APPROVED'
ORDER BY p.created_at DESC;

-- ============================================================================
-- Comments
-- ============================================================================

COMMENT ON TABLE governance_proposals IS
    'Tracks governance proposals for the ArenaX multisig governance contract';

COMMENT ON TABLE governance_approvals IS
    'Tracks individual signer approvals for governance proposals';

COMMENT ON TABLE governance_chain_sync IS
    'Audit log of blockchain transactions related to governance operations';

COMMENT ON TABLE operator_audit_log IS
    'Append-only, hash-chained audit log of privileged operator actions (moderation, disputes, suspensions, feature flags, payouts)';

COMMENT ON COLUMN governance_proposals.proposal_id IS
    'On-chain proposal identifier (hex-encoded 32 bytes)';

COMMENT ON COLUMN governance_proposals.status IS
    'Current status: PENDING (awaiting approvals), APPROVED (ready to execute), EXECUTED, CANCELLED, or FAILED';

COMMENT ON COLUMN governance_chain_sync.operation IS
    'Type of governance operation: CREATE, APPROVE, REVOKE, EXECUTE, or CANCEL';

COMMENT ON COLUMN operator_audit_log.prev_hash IS
    'Hash of the previous audit record; NULL only for the genesis record';

COMMENT ON COLUMN operator_audit_log.record_hash IS
    'SHA-256 of the canonical record payload chained with prev_hash; used for integrity verification';

COMMENT ON COLUMN operator_audit_log.before_state IS
    'Redacted before-state metadata; must never contain credentials or private evidence';

COMMENT ON COLUMN operator_audit_log.after_state IS
    'Redacted after-state metadata; must never contain credentials or private evidence';
