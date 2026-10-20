# ADR 0002: Authoritative Match Result

## Status

Accepted

## Context

Match outcomes can be derived in more than one place: the backend match
engine, the on-chain settlement contract, and any client that observes both.
When these disagree, users and downstream services have no single source of
truth for "who won" and "what is owed".

The current code paths that produce or persist match results are:

- `backend/src/matching/` — the off-chain matching engine that pairs orders
  and computes fills.
- `backend/migrations/` — the schema that persists matches, fills, and their
  settlement status.
- The settlement contract invoked by the backend after a match is finalized.

Today the backend computes the result first and the chain is asked to settle
it. There is no documented rule for what happens when the two disagree, and no
recorded decision about which one is authoritative.

## Decision

**The backend match engine is the authoritative source of truth for match
results.** The on-chain settlement contract is a settlement and custody layer,
not a matching authority.

Concretely:

- The match record written by the backend (see `backend/migrations/`) is the
  canonical result. Its identifier is what other services reference.
- On-chain state records settlement of a backend-produced result. It does not
  independently decide the winner of a match.
- If on-chain settlement fails or reverts, the backend match record remains the
  canonical result and the settlement status is marked as failed/pending; the
  match is not re-derived from chain state.

## Rejected Alternatives

- **On-chain result is authoritative.** Rejected: matching currently happens
  off-chain for latency and cost reasons, and the chain does not have the order
  book state needed to re-derive results. Making the chain authoritative would
  require moving matching on-chain, which is out of scope and not implemented.
- **Dual authority with reconciliation.** Rejected: without a documented
  tie-breaker this produces exactly the ambiguity this ADR exists to remove.
- **Client-derived result.** Rejected: clients do not have full order book
  visibility and cannot be trusted as a source of truth.

## Consequences

- Backend match records must be durable and immutable once finalized; any
  correction is a new record, not an in-place edit.
- Settlement failures are surfaced as settlement status, not as a different
  match result.
- Auditors and downstream services read match results from the backend store,
  and read custody/settlement state from the chain.
- This ADR does not claim that on-chain and off-chain state are always
  consistent; it defines which one wins when they are not.

## Revisit Trigger

Revisit this decision if any of the following occur:

- Matching is moved on-chain, in whole or in part.
- A second independent producer of match results is introduced.
- Settlement failures become common enough that a reconciliation process is
  required.

## Related Decisions

- ADR 0001: Internal Ledger vs On-Chain Balances
- ADR 0003: Payment Finality
- ADR 0004: Contract Upgrade Authority
- ADR 0005: Backend Ownership

New cross-cutting work that touches match results, settlement, or custody must
link to this ADR or propose an update to it.
