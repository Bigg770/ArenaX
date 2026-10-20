# Match Authority Implementation

This document describes how match authority is implemented across the backend, and now also serves as the least-privilege API threat model for gaming, financial, and blockchain flows (issue #88).

## Match Authority Overview

Match authority determines which party is allowed to report results, resolve disputes, and settle payouts for a given match. Authority is scoped per match and enforced at the API boundary.

## Least-Privilege API Threat Model

### Assets

| Asset | Sensitivity | Where it lives |
| --- | --- | --- |
| User credentials / sessions | High | Auth service, session store |
| Match results & reports | Medium | Match service DB |
| Dispute records | High | Dispute service DB |
| Payment / payout records | High | Payments DB, ledger |
| Uploaded files (evidence, avatars) | Medium | Object storage |
| Smart-contract admin keys | Critical | KMS / custody boundary |
| Contract configuration | High | Chain + admin API |

### Actors

- **Anonymous visitor** — unauthenticated, read-only public endpoints.
- **Authenticated player** — can report own matches, open disputes, upload evidence.
- **Match authority / referee** — can resolve disputes and finalize results.
- **Finance operator** — can trigger payouts within limits.
- **Contract administrator** — can change on-chain configuration.
- **Service-to-service** — internal callers with scoped tokens.

### Entry Points & Trust Transitions

| Entry point | Trust transition | Mitigation | Code / tests |
| --- | --- | --- | --- |
| `POST /auth/login` | anonymous → authenticated | Rate limiting, credential hashing, session rotation | auth handlers + auth tests |
| `POST /matches/:id/report` | player → match authority | Authority check per match, idempotency, audit log | match report handler + match authority tests |
| `POST /disputes` | player → dispute reviewer | Ownership check, evidence validation | dispute handler + dispute tests |
| `POST /payments/payout` | operator → ledger | Role check, amount limits, dual control | payments handler + payout tests |
| `POST /uploads` | player → storage | MIME/size validation, signed URLs, virus scan hook | upload handler + upload tests |
| `POST /admin/contract` | admin → chain | Admin key in KMS, role gate, change log | contract admin handler + admin tests |

### Mitigations Mapped to Code & Tests

- **Auth**: least-privilege scopes on tokens; every privileged route asserts role before handler logic. Covered by auth and RBAC tests.
- **Match reporting**: only the assigned authority may finalize; conflicting reports are rejected and logged. Covered by match authority tests.
- **Disputes**: only involved parties or referees may read/write; resolution requires authority role. Covered by dispute tests.
- **Payments**: payouts require finance role plus amount ceiling; ledger writes are append-only. Covered by payout tests.
- **Uploads**: content-type and size enforced server-side; storage access via short-lived signed URLs. Covered by upload tests.
- **Contract administration**: admin key never leaves KMS; all changes require admin role and are logged. Covered by admin tests.

### Accepted Residual Risks

- **Referee collusion** on dispute resolution — accepted; mitigated by audit logging and manual review of flagged disputes. Owner: Trust & Safety.
- **Upload malware** beyond scan hook coverage — accepted; storage is isolated and served via signed URLs. Owner: Platform.
- **Payout latency vs. double-spend window** — accepted; ledger is append-only and reconciled. Owner: Finance.
- **KMS availability** affecting contract admin — accepted; admin actions are queued and retried. Owner: Infra.

### High-Risk Findings & Owners

| Finding | Risk | Owner / Decision |
| --- | --- | --- |
| Referee collusion in disputes | High | Trust & Safety — tracked, manual review |
| Admin key blast radius | High | Infra — KMS + role gate, decision recorded |
| Payout double-spend window | Medium | Finance — append-only ledger accepted |

### Maintenance

This model MUST be updated whenever an API surface or custody boundary changes (new endpoint, new role, new key holder). Security review signs off against the misuse-case checklist before merge.

## Match Authority Overview (continued)

Match authority determines which party is allowed to report results, resolve disputes, and settle payouts for a given match. Authority is scoped per match and enforced at the API boundary.
