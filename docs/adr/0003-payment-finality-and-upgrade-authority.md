# ADR 0003: Payment Finality and Contract Upgrade Authority

- **Status:** Accepted
- **Date:** 2024-06-01
- **Deciders:** Backend, Contracts, and Platform maintainers
- **Related:** ADR 0001 (internal ledger vs on-chain balances), ADR 0002 (authoritative match result), ADR 0004 (backend ownership)

## Context

Payments move between an internal ledger and on-chain balances, and the
contracts that hold custody can be upgraded. Two questions must be answered
explicitly so that reviewers and operators can reason about risk:

1. **When is a payment final?** i.e. at what point may downstream code treat a
   transfer as irreversible and release the corresponding internal credit?
2. **Who can upgrade the custody contracts, and under what constraints?**

Current code paths relevant to this decision:

- Internal ledger writes and balance mutations live in the backend ledger
  module and its migrations under `backend/migrations/`.
- On-chain custody and settlement logic is exercised by the contract test
  suite and the deployment scripts referenced from the repository root.
- Idempotency and retry semantics for payment operations are described in
  `backend/IDEMPOTENCY_FRAMEWORK.md`; circuit-breaker behavior is described in
  `backend/CIRCUIT_BREAKER.md`.
- CI (`.github/workflows/ci.yml`) runs the backend and contract test suites
  that gate any change to these paths.

This ADR records the decisions as they exist today. It does not claim
finality or upgrade guarantees that are not implemented in the cited code.

## Decision 1: Payment finality

**Chosen option.** A payment is considered final only after the on-chain
transaction has reached the confirmation depth enforced by the settlement
path, and the corresponding internal ledger entry has been committed with an
idempotency key. Until both conditions hold, the payment is *pending* and may
be retried or reversed.

**Rejected alternatives.**

- *Treat submission as final.* Rejected: a submitted transaction can be
  dropped or reorged, which would create internal credit without matching
  on-chain custody.
- *Treat internal ledger commit as final.* Rejected: the ledger is the
  source of truth for accounting, not for custody; committing before on-chain
  confirmation would let the ledger diverge from actual balances.
- *Rely on a single global confirmation constant.* Rejected: confirmation
  depth is chain- and asset-dependent and must be configurable per settlement
  path.

**Consequences.**

- Downstream consumers must handle a `pending` state and must not release
  irreversible value on submission alone.
- Retries are safe because they are keyed by the idempotency framework; see
  `backend/IDEMPOTENCY_FRAMEWORK.md`.
- Operators can pause settlement via the circuit breaker without corrupting
  finality accounting; see `backend/CIRCUIT_BREAKER.md`.

**Revisit trigger.** Revisit if confirmation-depth policy changes, if a new
chain or asset is added with different finality characteristics, or if the
idempotency framework is replaced.

## Decision 2: Contract upgrade authority

**Chosen option.** Custody contracts are upgradeable only through the
governance-controlled upgrade path. Upgrade authority is held by the
governance account, not by an individual operator key, and every upgrade must
pass the contract test suite in CI before deployment.

**Rejected alternatives.**

- *Single operator key with upgrade rights.* Rejected: concentrates custody
  risk in one credential and bypasses review.
- *Immutable contracts with no upgrade path.* Rejected: prevents fixing
  critical bugs in custody logic without a full migration, which is riskier
  than a governed upgrade.
- *Multisig without governance review.* Rejected: still lacks the recorded
  review and test gate that governance provides.

**Consequences.**

- Upgrades require governance approval and a passing CI run
  (`.github/workflows/ci.yml`), which slows emergency changes but keeps them
  reviewable.
- The governance account becomes a critical dependency; its key management is
  out of scope for this ADR and must be covered by a separate decision.
- Any change to upgrade authority must update this ADR and the deployment
  scripts together.

**Revisit trigger.** Revisit if the governance model changes, if upgrade
frequency or emergency-response requirements change, or if the custody
contracts are migrated to a new deployment model.

## Cross-cutting work

New work that touches payment finality or contract upgrade authority must
link to this ADR in its PR description, or propose an update to this ADR if
the decision changes. Changes to the internal ledger, settlement path, or
governance tables must reference the relevant decision above.
