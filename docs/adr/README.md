# Architecture Decision Records (ADRs)

This directory records high-impact, cross-cutting architecture decisions so they
are reviewable and traceable. Each ADR states the context, the chosen option,
rejected alternatives, consequences, and a revisit trigger. ADRs describe the
system **as currently implemented** and cite the relevant code paths; they must
not claim guarantees that are not yet implemented.

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-internal-ledger-vs-onchain-balances.md) | Internal ledger vs. on-chain balances | Accepted |
| [0002](0002-authoritative-match-result.md) | Authoritative match result | Accepted |
| [0003](0003-payment-finality.md) | Payment finality | Accepted |
| [0004](0004-contract-upgrade-authority.md) | Contract upgrade authority | Accepted |
| [0005](0005-backend-ownership.md) | Backend ownership | Accepted |

## Conventions

- One decision per file, numbered sequentially (`NNNN-title.md`).
- Status is one of: Proposed, Accepted, Deprecated, Superseded.
- Every ADR includes: Context, Decision, Rejected alternatives, Consequences,
  and Revisit trigger.
- Cite concrete code paths (migrations, modules, tables) so reviewers can verify
  the decision against the current deployment.

## Linking new work

New cross-cutting work (new services, custody flows, match settlement, payment
paths, or contract changes) must link to the relevant ADR in its PR description
or issue. If the work changes a decision, open a PR that **supersedes** the ADR
(add a new ADR and mark the old one `Superseded`) rather than editing history in
place.

## ADR 0001 — Internal ledger vs. on-chain balances

**Context.** The backend maintains balances used for matchmaking and settlement
while on-chain contracts hold token balances. These two views can diverge, and
we need a single rule for which is authoritative for a given operation.

**Decision.** The internal ledger is the source of truth for matchmaking and
in-app accounting; on-chain balances are the source of truth for custody and
withdrawals. Reconciliation between the two is performed by the deposit/withdraw
paths and recorded in the ledger tables defined in `backend/migrations`.

**Rejected alternatives.**
- Treating on-chain balances as the sole source of truth for matchmaking
  (rejected: latency and cost of per-match chain reads).
- Treating the internal ledger as authoritative for custody (rejected: it would
  claim a custody guarantee the system does not provide).

**Consequences.** Ledger and chain state must be reconciled; divergence is a
first-class failure mode handled by the deposit/withdraw flows. Matchmaking does
not depend on chain availability.

**Revisit trigger.** Revisit if matchmaking begins to depend on live on-chain
balances, or if custody moves fully on-chain.

## ADR 0002 — Authoritative match result

**Context.** Match outcomes are produced off-chain and may be settled on-chain.
We need to name the single authority for a match result.

**Decision.** The backend match authority is the source of truth for match
results. On-chain settlement consumes the result produced by the backend; the
chain does not independently determine the winner.

**Rejected alternatives.**
- On-chain adjudication of every match (rejected: cost and latency).
- Client-reported results (rejected: not trustworthy).

**Consequences.** Match integrity depends on the backend match authority and its
persistence. Settlement must be idempotent with respect to a given match result
(see the idempotency framework in `backend/IDEMPOTENCY_FRAMEWORK.md`).

**Revisit trigger.** Revisit if matches are adjudicated on-chain or if a
dispute mechanism requires on-chain verification of results.

## ADR 0003 — Payment finality

**Context.** Payments move through off-chain ledger updates and on-chain
transfers. We need to define when a payment is considered final.

**Decision.** A payment is final when it is recorded in the internal ledger and,
for on-chain movements, confirmed on-chain. Off-chain ledger entries are
provisional until the corresponding on-chain confirmation (where applicable) is
observed. Idempotency keys guard against duplicate application of a payment.

**Rejected alternatives.**
- Treating off-chain ledger writes as immediately final for on-chain movements
  (rejected: would claim finality the chain has not granted).
- Requiring on-chain confirmation for purely internal transfers (rejected:
  unnecessary latency).

**Consequences.** Payment state has a provisional phase; consumers must handle
pending payments. The idempotency framework is required to keep retries safe.

**Revisit trigger.** Revisit if a new payment rail is added or if finality
semantics change for an existing rail.

## ADR 0004 — Contract upgrade authority

**Context.** On-chain contracts may need upgrades. We must name who can upgrade
them and under what constraints.

**Decision.** Contract upgrade authority is held by the governance/admin path
defined in the contract deployment and governance configuration. Upgrades are
executed through that path; there is no unilateral upgrade from application
code.

**Rejected alternatives.**
- Immutable contracts with no upgrade path (rejected: blocks necessary fixes).
- Application-controlled upgrades (rejected: conflates app and governance
  authority).

**Consequences.** Upgrade operations are governance actions and must be reviewed
as such. Application code must not assume it can change contract behavior.

**Revisit trigger.** Revisit if upgrade authority moves, or if contracts become
immutable.

## ADR 0005 — Backend ownership

**Context.** Multiple backend components (match authority, ledger, payment
paths) exist. We need clear ownership so changes are reviewed by the right
owners.

**Decision.** The backend owns match authority, the internal ledger, and
payment orchestration. On-chain contracts own custody and settlement execution.
Ownership boundaries follow these responsibilities; changes crossing a boundary
require review from both sides.

**Rejected alternatives.**
- Splitting match authority across services (rejected: ambiguous source of
  truth).
- Moving ledger ownership on-chain (rejected: contradicts ADR 0001).

**Consequences.** Cross-boundary changes (e.g., new settlement flows) require
coordinated review. Ownership is documented here and referenced from new work.

**Revisit trigger.** Revisit if services are split or merged, or if ownership of
custody or settlement changes.
