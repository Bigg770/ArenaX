//! Append-only, tamper-evident audit log for privileged operator actions.
//!
//! Records are chained by hash so any mutation of history is detectable, and
//! sensitive fields (credentials, private evidence) are redacted before storage.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

/// Roles allowed to perform privileged operator actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperatorRole {
    Admin,
    Moderator,
    Support,
}

impl OperatorRole {
    /// Whether this role may perform the given sensitive action.
    pub fn can_perform(&self, action: &SensitiveAction) -> bool {
        match self {
            OperatorRole::Admin => true,
            OperatorRole::Moderator => matches!(
                action,
                SensitiveAction::Moderation | SensitiveAction::DisputeResolution
            ),
            // Support is read-only: may search the audit log but never act.
            OperatorRole::Support => false,
        }
    }

    /// Whether this role may read/search the audit log.
    pub fn can_read_audit(&self) -> bool {
        matches!(self, OperatorRole::Admin | OperatorRole::Moderator | OperatorRole::Support)
    }
}

/// Categories of privileged actions that must be attributable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SensitiveAction {
    Moderation,
    DisputeResolution,
    AccountSuspension,
    FeatureFlag,
    Payout,
}

impl SensitiveAction {
    /// Policy: these actions always require a human-supplied reason.
    pub fn requires_reason(&self) -> bool {
        matches!(
            self,
            SensitiveAction::AccountSuspension | SensitiveAction::Payout | SensitiveAction::DisputeResolution
        )
    }
}

/// Authenticated operator identity attached to every record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Actor {
    pub id: String,
    pub role: OperatorRole,
}

/// A request to record a privileged action.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditRequest {
    pub actor: Actor,
    pub action: SensitiveAction,
    pub target: String,
    pub reason: Option<String>,
    #[serde(default)]
    pub before: Option<serde_json::Value>,
    #[serde(default)]
    pub after: Option<serde_json::Value>,
}

/// Errors surfaced when an action is denied or the log is tampered with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuditError {
    Unauthenticated,
    Forbidden,
    ReasonRequired,
    IntegrityViolation { index: usize },
}

/// A stored, immutable audit record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditRecord {
    pub seq: u64,
    pub actor_id: String,
    pub actor_role: OperatorRole,
    pub action: SensitiveAction,
    pub target: String,
    pub reason: Option<String>,
    pub before: Option<serde_json::Value>,
    pub after: Option<serde_json::Value>,
    pub prev_hash: String,
    pub hash: String,
}

/// Append-only audit log backed by a hash chain.
#[derive(Debug, Default)]
pub struct AuditLog {
    records: Vec<AuditRecord>,
}

const GENESIS_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

/// Keys whose values must never be persisted in the audit log.
const REDACTED_KEYS: &[&str] = &[
    "password",
    "password_hash",
    "token",
    "access_token",
    "refresh_token",
    "secret",
    "api_key",
    "credential",
    "private_evidence",
    "evidence",
    "ssn",
    "card_number",
];

fn redact_value(value: &serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => {
            let mut out = BTreeMap::new();
            for (k, v) in map {
                if REDACTED_KEYS.iter().any(|r| k.eq_ignore_ascii_case(r)) {
                    out.insert(k.clone(), serde_json::Value::String("[REDACTED]".into()));
                } else {
                    out.insert(k.clone(), redact_value(v));
                }
            }
            serde_json::Value::Object(out.into_iter().collect())
        }
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.iter().map(redact_value).collect())
        }
        other => other.clone(),
    }
}

fn compute_hash(record: &AuditRecord) -> String {
    let mut hasher = Sha256::new();
    hasher.update(record.seq.to_le_bytes());
    hasher.update(record.actor_id.as_bytes());
    hasher.update(format!("{:?}", record.actor_role).as_bytes());
    hasher.update(format!("{:?}", record.action).as_bytes());
    hasher.update(record.target.as_bytes());
    hasher.update(record.reason.as_deref().unwrap_or("").as_bytes());
    hasher.update(record.before.as_ref().map(|v| v.to_string()).unwrap_or_default().as_bytes());
    hasher.update(record.after.as_ref().map(|v| v.to_string()).unwrap_or_default().as_bytes());
    hasher.update(record.prev_hash.as_bytes());
    format!("{:x}", hasher.finalize())
}

impl AuditLog {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a privileged action, enforcing role and reason policy.
    pub fn record(&mut self, req: AuditRequest) -> Result<&AuditRecord, AuditError> {
        if req.actor.id.trim().is_empty() {
            return Err(AuditError::Unauthenticated);
        }
        if !req.actor.role.can_perform(&req.action) {
            return Err(AuditError::Forbidden);
        }
        let reason = req.reason.as_deref().map(str::trim).filter(|r| !r.is_empty());
        if req.action.requires_reason() && reason.is_none() {
            return Err(AuditError::ReasonRequired);
        }

        let seq = self.records.len() as u64;
        let prev_hash = self
            .records
            .last()
            .map(|r| r.hash.clone())
            .unwrap_or_else(|| GENESIS_HASH.to_string());

        let mut record = AuditRecord {
            seq,
            actor_id: req.actor.id,
            actor_role: req.actor.role,
            action: req.action,
            target: req.target,
            reason: reason.map(str::to_string),
            before: req.before.as_ref().map(redact_value),
            after: req.after.as_ref().map(redact_value),
            prev_hash,
            hash: String::new(),
        };
        record.hash = compute_hash(&record);
        self.records.push(record);
        Ok(self.records.last().expect("just pushed"))
    }

    /// Read-only search over the audit log. Never mutates records.
    pub fn search(&self, actor: &Actor, query: &str) -> Result<Vec<&AuditRecord>, AuditError> {
        if actor.id.trim().is_empty() {
            return Err(AuditError::Unauthenticated);
        }
        if !actor.role.can_read_audit() {
            return Err(AuditError::Forbidden);
        }
        let q = query.to_lowercase();
        Ok(self
            .records
            .iter()
            .filter(|r| {
                q.is_empty()
                    || r.actor_id.to_lowercase().contains(&q)
                    || r.target.to_lowercase().contains(&q)
                    || r.reason.as_deref().map(|s| s.to_lowercase().contains(&q)).unwrap_or(false)
            })
            .collect())
    }

    /// Verify the hash chain is intact; detects tampering of any record.
    pub fn verify_integrity(&self) -> Result<(), AuditError> {
        let mut expected_prev = GENESIS_HASH.to_string();
        for (index, record) in self.records.iter().enumerate() {
            if record.prev_hash != expected_prev {
                return Err(AuditError::IntegrityViolation { index });
            }
            if compute_hash(record) != record.hash {
                return Err(AuditError::IntegrityViolation { index });
            }
            expected_prev = record.hash.clone();
        }
        Ok(())
    }

    pub fn records(&self) -> &[AuditRecord] {
        &self.records
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn actor(role: OperatorRole) -> Actor {
        Actor { id: "op-1".into(), role }
    }

    fn req(role: OperatorRole, action: SensitiveAction, reason: Option<&str>) -> AuditRequest {
        AuditRequest {
            actor: actor(role),
            action,
            target: "user-42".into(),
            reason: reason.map(str::to_string),
            before: None,
            after: None,
        }
    }

    #[test]
    fn denies_support_actions() {
        let mut log = AuditLog::new();
        assert_eq!(
            log.record(req(OperatorRole::Support, SensitiveAction::Moderation, Some("x"))),
            Err(AuditError::Forbidden)
        );
    }

    #[test]
    fn requires_reason_for_suspension() {
        let mut log = AuditLog::new();
        assert_eq!(
            log.record(req(OperatorRole::Admin, SensitiveAction::AccountSuspension, None)),
            Err(AuditError::ReasonRequired)
        );
    }

    #[test]
    fn records_and_redacts() {
        let mut log = AuditLog::new();
        let mut r = req(OperatorRole::Admin, SensitiveAction::Payout, Some("refund"));
        r.after = Some(serde_json::json!({ "amount": 10, "token": "secret" }));
        let rec = log.record(r).unwrap().clone();
        assert_eq!(rec.after.unwrap()["token"], "[REDACTED]");
        assert!(log.verify_integrity().is_ok());
    }

    #[test]
    fn detects_tampering() {
        let mut log = AuditLog::new();
        log.record(req(OperatorRole::Admin, SensitiveAction::FeatureFlag, None)).unwrap();
        log.records[0].target = "tampered".into();
        assert_eq!(log.verify_integrity(), Err(AuditError::IntegrityViolation { index: 0 }));
    }

    #[test]
    fn support_can_search() {
        let mut log = AuditLog::new();
        log.record(req(OperatorRole::Admin, SensitiveAction::Moderation, Some("spam"))).unwrap();
        let hits = log.search(&actor(OperatorRole::Support), "spam").unwrap();
        assert_eq!(hits.len(), 1);
    }
}
