# Backend

This service handles account, match, financial, evidence, and telemetry data. The
policies below define how each data class is classified, retained, and deleted
across every storage system we operate.

## Data inventory and retention controls

Systems of record: **PostgreSQL** (primary relational store), **Redis** (cache /
ephemeral state), **object storage** (S3-compatible buckets for evidence and
exports), **logs** (structured application/audit logs), and **analytics**
(warehouse / event pipeline).

| Data class | Purpose | Sensitivity | Owner | Retention | Deletion / hold rules | Systems of record |
| --- | --- | --- | --- | --- | --- | --- |
| Account profile (name, email, auth identifiers) | Authentication and account management | Confidential (PII) | Identity team | Life of account + 30 days after deletion request | Hard-deleted on account deletion after 30-day grace; Redis keys evicted immediately; logs redacted | PostgreSQL, Redis, logs |
| Match records (participants, results, timestamps) | Gameplay history and dispute resolution | Internal | Gameplay team | 24 months from match completion | Purged by scheduled job; anonymized aggregates may persist in analytics | PostgreSQL, analytics |
| Financial records (payments, payouts, ledger entries) | Billing, tax, and accounting obligations | Restricted (financial) | Finance team | 7 years (accounting retention exception) | Not deleted on account deletion; retained under accounting exception, access restricted to Finance role | PostgreSQL, object storage (exports), analytics |
| Evidence (uploads, reports, moderation artifacts) | Trust & safety investigations and appeals | Restricted | Trust & Safety team | 12 months from case closure, or longer while a legal hold is active | Deleted at expiry unless under legal hold; object storage objects removed with metadata row | Object storage, PostgreSQL |
| Telemetry (events, metrics, traces) | Reliability, debugging, product analytics | Internal (pseudonymized) | Platform team | 90 days raw; 13 months aggregated | Raw events dropped by TTL; Redis ephemeral keys expire automatically; aggregates retained without identifiers | Redis, logs, analytics |

## Deletion behavior

- **Account deletion:** profile data hard-deleted after the 30-day grace period;
  Redis session/cache keys removed immediately; log entries are redacted rather
  than rewritten.
- **Match records:** purged 24 months after completion by a scheduled job;
  anonymized aggregates may remain in analytics.
- **Financial records:** retained for the accounting period (7 years) and are
  **not** removed on account deletion.
- **Evidence:** deleted 12 months after case closure unless a legal hold applies.
- **Telemetry:** raw events expire via TTL (90 days); aggregated metrics retained
  up to 13 months without identifiers.

## Legal hold and accounting retention exceptions

Two exceptions override normal deletion:

1. **Legal hold** — suspends deletion of any data class tied to an active
   investigation or litigation. Holds may be **placed or released only by the
   Legal team** (or an authorized Trust & Safety lead acting on Legal's written
   instruction). Each hold records the requester, scope, and reason.
2. **Accounting retention** — financial records are retained for 7 years to meet
   tax and accounting obligations, regardless of account deletion.

**Access control:** placing or releasing a hold requires the `legal_hold:manage`
permission, granted only to the Legal role. Access to data under hold or under the
accounting exception is restricted to the owning team's role (Finance for
financial records, Legal/Trust & Safety for held evidence) and is logged in the
audit trail. Deletion jobs must check for active holds and skip matching records.

## Review guidance for new storage fields

Any change that adds or modifies a persisted field (PostgreSQL column, Redis key,
object storage attribute, log field, or analytics event property) **must** be
classified in the pull request before merge:

- **Sensitivity** — Public / Internal / Confidential / Restricted.
- **Retention** — explicit period and deletion behavior.
- **Owner** — the team accountable for the data.

PRs that introduce unclassified storage fields should be blocked in review until
this table is updated.
