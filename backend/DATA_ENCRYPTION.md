# Data Encryption & Key Management

This document describes how sensitive data is encrypted at rest and in transit, how keys are managed, and how to respond to a suspected secret exposure. It also contains the least-privilege API threat model (see [API Threat Model](#api-threat-model)).

## Encryption at rest

- Database: managed Postgres with storage-level encryption enabled by the provider.
- Sensitive columns (e.g. wallet addresses, payout details) are application-encrypted with AES-256-GCM using keys from the secret manager.
- Backups inherit provider storage encryption; restore procedures are documented in the runbook.

## Encryption in transit

- All external traffic terminates TLS 1.2+ at the load balancer; HTTP is redirected to HTTPS.
- Internal service-to-service calls use TLS where supported by the provider.

## Key management

- Keys live in the platform secret manager, never in source control.
- Keys are scoped per environment (dev/staging/prod) and rotated on a schedule and on suspected exposure.
- Access to keys is limited to the deploy role and on-call security owner (least privilege).

## Secret rotation runbook

1. Identify the exposed secret and its scope (see `.env.example` for the full inventory).
2. Revoke/rotate at the provider first, then update the secret manager.
3. Redeploy affected services so they pick up the new value.
4. Verify health checks and auth flows.
5. Record the incident, timeline, and follow-up actions.

## Exposure response

- Treat any committed secret as compromised; rotate immediately.
- Scan history and remove the secret from the working tree; do not rely on history rewrite alone.
- Notify the security owner and, if customer data is involved, follow the disclosure policy.

## API Threat Model

This is a least-privilege threat model for the API. It makes trust boundaries and abuse cases explicit for gaming, financial, and blockchain flows. It is reviewed and updated whenever an API or custody boundary changes.

### Assets

- User identities and sessions (credentials, tokens).
- Match results and dispute records (integrity of competitive outcomes).
- Payment and payout records, balances, and ledger entries.
- Uploaded files (avatars, evidence, receipts).
- Smart-contract administration keys and on-chain custody.

### Actors

- Anonymous internet client.
- Authenticated player.
- Match reporter / oracle (reports results).
- Dispute resolver / admin.
- Finance operator (payments/payouts).
- Contract administrator (on-chain custody).
- Insider / compromised service account (worst case).

### Entry points & trust transitions

| Flow | Entry point | Trust transition |
| --- | --- | --- |
| Auth | `/auth/*` | anonymous → authenticated session |
| Match reporting | match report endpoint | authenticated player → trusted result |
| Disputes | dispute endpoints | player claim → resolver decision |
| Payments | payment/payout endpoints | player → financial ledger |
| Uploads | upload endpoints | anonymous/player → stored object |
| Contract admin | admin/contract endpoints | operator → on-chain custody |

### Mitigations mapped to code & tests

| Risk | Mitigation | Code | Tests |
| --- | --- | --- | --- |
| Session forgery / replay | Signed, expiring tokens; server-side validation | auth middleware | auth unit/integration tests |
| Forged match results | Reporter authorization + result validation before persistence | match reporting handler | match reporting tests |
| Dispute tampering | Resolver-only transitions; immutable audit trail | dispute service | dispute tests |
| Payment fraud / double-spend | Idempotency keys, ledger checks, role-gated payout endpoints | payments service | payments tests |
| Malicious uploads | Type/size validation, isolated storage, no execution | upload handler | upload validation tests |
| Contract admin abuse | Least-privilege admin role, multi-step confirmation, key isolation | contract admin module | admin authorization tests |
| Secret leakage | Secret manager, rotation runbook, CI secret scanning | `.github/workflows/ci.yml`, `.env.example` | CI checks |

### Accepted residual risks

- Provider-level storage encryption is trusted; we do not independently verify at-rest encryption of backups.
- On-chain custody relies on the contract administrator key holder following the multi-step process; a compromised admin key is a residual risk mitigated only by rotation speed.
- Uploaded files are scanned for type/size but not for all malware classes; downstream consumers must treat uploads as untrusted.

### High-risk findings & ownership

- Contract admin key compromise: owner = security lead; decision = rotate on suspicion, tracked in the security backlog.
- Payment idempotency gaps: owner = finance operator; tracked as a linked issue in the payments backlog.
- Any new high-risk finding must have a linked issue or an explicit owner/decision recorded here before merge.

### Maintenance

Update this model whenever an API endpoint, auth flow, payment path, upload path, or custody boundary changes. Security review signs off against the misuse-case checklist before release.
