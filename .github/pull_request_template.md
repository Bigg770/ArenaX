# Pull Request Template for ArenaX

## Issue Reference
Issue: #<number> - <title>

## Description
<What does this PR do and why?>

## Changes Summary

### New Files
- `<path>` - <purpose>

### Modified Files
- `<path>` - <purpose>

## Data Classification & Retention Review

Every new or changed storage field (PostgreSQL column, Redis key, object-storage
object/prefix, log field, analytics event/property) MUST be classified before
merge. Unclassified fields block the PR.

### Data Inventory

For each sensitive data class touched by this PR, fill in a row. Use the
canonical classes below; add a row only if a genuinely new class is introduced
(and justify it in Additional Notes).

| Data class | Purpose | Sensitivity | Owner | Retention | Deletion / hold rules | Systems of record |
|---|---|---|---|---|---|---|
| Account (identity, profile, credentials, sessions) | Authenticate and operate user accounts | Restricted | Identity team | Active account + 30 days after closure | Hard-delete on account closure after grace period; auth logs anonymized; legal hold suspends deletion | PostgreSQL (`users`, `sessions`), Redis (session cache), logs |
| Match (gameplay, results, matchmaking state) | Run matches, scoring, dispute resolution | Confidential | Gameplay team | 24 months from match end | Purge/anonymize after retention; active disputes and legal holds suspend deletion | PostgreSQL (`matches`), Redis (matchmaking), object storage (replays) |
| Financial (payments, payouts, ledger, invoices) | Process payments and satisfy accounting obligations | Restricted | Finance team | 7 years (accounting exception) | Retained for statutory accounting period; deletion only after period and no hold; access restricted to Finance + Auditors | PostgreSQL (ledger), object storage (invoices/receipts) |
| Evidence (disputes, anti-cheat, moderation artifacts) | Resolve disputes and enforce integrity | Restricted | Trust & Safety team | 12 months, or until case closed + 12 months | Deleted after retention unless legal hold; hold release requires Trust & Safety lead + Legal | Object storage (evidence bucket), PostgreSQL (case metadata) |
| Telemetry (metrics, traces, analytics events) | Observability, product analytics, abuse detection | Internal | Platform team | 90 days raw; 13 months aggregated | Auto-expire raw data; aggregates anonymized; no PII in analytics properties | Logs, analytics platform, Redis (short-lived counters) |

### Field Classification (required for each new/changed field)

| Field / key | System | Sensitivity | Retention | Owner |
|---|---|---|---|---|
| `<field>` | `<PostgreSQL / Redis / object storage / logs / analytics>` | `<Public / Internal / Confidential / Restricted>` | `<period>` | `<team>` |

### Legal Hold & Accounting Exceptions

- [ ] No legal hold or accounting exception applies to data in this PR.
- [ ] Legal hold applies. Placing/releasing a hold requires written approval from
      Legal plus the data-class owner; holds are recorded in the hold register and
      enforced by the deletion job (deletion is skipped while a hold is active).
- [ ] Accounting retention exception applies (financial data, 7 years). Access is
      restricted to Finance and Auditors via role-based access control; deletion is
      blocked until the statutory period elapses.

### Validation

- [ ] Traced a representative user record through PostgreSQL, Redis, object
      storage, logs, and analytics and confirmed retention/deletion behavior.
- [ ] Confirmed deletion jobs honor legal holds and accounting retention.

## Testing Checklist
- [ ] Tests added/updated and passing
- [ ] Migrations apply cleanly (if applicable)

## Breaking Changes
<None, or describe>

## Additional Notes
<Anything reviewers should know, including justification for new data classes>
