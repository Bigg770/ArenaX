# ADR 0001: Internal Ledger vs On-Chain Balances

- **Status:** Accepted
- **Date:** 2024-01-01
- **Deciders:** Backend, Contracts, Architecture Review
- **Related:** ADR 0002 (Authoritative Match Result), ADR 0003 (Payment Finality), ADR 0004 (Contract Upgrade Authority), ADR 0005 (Backend Ownership)

## Context

The platform tracks user balances in two places:

1. **Internal ledger** — the `balances` table maintained by the backend, mutated through the idempotency framework described in `backend/IDEMPOTENCY_FRAMEWORK.md` and guarded by the circuit breaker in `backend/CIRCUIT_BREAKER.md`.
2. **On-chain balances** — token/ETH balances held by the custody contracts and read via the chain indexer.

Both representations exist today. The question is which one is the source of truth for user-facing balance display, withdrawals, and settlement, and how the two are reconciled.

## Decision

The **internal ledger is the source of truth for user-facing balances and withdrawal eligibility**. On-chain balances are treated as a settlement layer that the ledger reconciles against, not as the primary record.

- All balance mutations flow through the backend ledger first, using the idempotency keys defined in `backend/IDEMPOTENCY_FRAMEWORK.md`.
- The chain indexer writes observed on-chain movements into reconciliation tables; discrepancies are surfaced as alerts rather than silently overwriting ledger state.
- Withdrawals debit the ledger and enqueue an on-chain transfer; the ledger entry is only marked final once the transfer is confirmed (see ADR 0003).

## Rejected Alternatives

- **On-chain balances as source of truth.** Rejected: read latency, reorg handling, and gas costs make it unsuitable for real-time UI and match settlement. It would also couple every read path to RPC availability.
- **Dual source of truth with last-writer-wins.** Rejected: produces non-deterministic balances under concurrent match settlement and withdrawal, and makes incident forensics ambiguous.
- **No internal ledger (pure on-chain).** Rejected: incompatible with the current match engine, which settles off-chain and only periodically anchors to chain.

## Consequences

- The ledger must be durable and auditable; migrations under `backend/migrations` are the canonical schema history.
- Reconciliation jobs are required and must be monitored; drift is an operational incident, not a silent correction.
- Backend availability directly affects balance correctness, so the circuit breaker and idempotency guarantees are load-bearing.
- On-chain state is authoritative only for what the contracts themselves enforce (custody, transfer finality), not for user-visible balances.

## Revisit Trigger

Revisit if any of the following occur:

- The match engine moves fully on-chain, removing the off-chain settlement assumption.
- Reconciliation drift exceeds the alerting threshold repeatedly, indicating the ledger cannot be kept consistent.
- Regulatory requirements mandate on-chain custody as the primary record.
