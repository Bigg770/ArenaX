# Idempotency Framework

This document describes how the backend guarantees that retries, dependency
failures, and concurrent requests never produce duplicate side effects (for
example duplicate payouts) or lose committed match state.

## Goals

- **No duplicate payouts.** A payout is executed at most once per logical
  operation, even across retries, restarts, and dependency outages.
- **No lost committed match state.** Once a match transition is committed it is
  durable and will be reconciled, even if a downstream dependency is degraded.
- **Safe degradation.** Dependency outages surface as recoverable degradation
  where possible, and as hard failures only when correctness would be at risk.

## Idempotency keys

Every mutating operation that can trigger an external side effect (payouts,
settlements, Stellar submissions) carries an **idempotency key** derived from the
logical operation, not from the transport attempt. The key is persisted together
with the operation result so that a retry returns the original outcome instead of
re-executing the side effect.

- Keys are scoped per operation type and per tenant/account.
- The first writer wins; concurrent attempts with the same key observe the stored
  result rather than racing the external call.
- Results are stored transactionally with the state transition they belong to, so
  a crash between the external call and the state write is recoverable.

## Dependency failure behavior

| Dependency | Failure mode | Expected behavior |
| --- | --- | --- |
| PostgreSQL | timeout / restart | Writes fail closed; no partial commit; retries reuse the idempotency key. |
| Redis | timeout / restart | Treated as a cache/lock miss; correctness falls back to the durable store. |
| Object storage | timeout / throttling | Uploads are retried with backoff; no state transition is committed until the artifact is durable. |
| Payment APIs | timeout / malformed response | Payout is not marked complete; reconciliation re-checks status before any retry. |
| Stellar RPC | timeout / malformed response | Submission is retried idempotently; duplicate submissions are rejected by the stored key. |

## Health and readiness

- **Liveness** reflects only the process itself.
- **Readiness** reflects whether the service can safely serve traffic. Recoverable
degradation (for example a throttled object store) is reported as degraded rather
than down, so the service keeps draining work instead of flapping.
- User-facing errors distinguish **recoverable degradation** (retryable, safe to
retry) from **hard failures** (not retryable without operator action).

## Recovery and reconciliation

- Pending work is drained from the durable queue after a dependency recovers.
- Reconciliation re-checks external status (payment APIs, Stellar RPC) before
re-issuing any side effect, so a retry after an ambiguous timeout cannot create a
duplicate payout.
- Once pending work is drained and dependencies are healthy, readiness returns to
healthy without manual intervention.

## Chaos testing

Dependency-failure chaos tests exercise the guarantees above by injecting
controlled faults in integration/staging environments:

- **Timeouts** on PostgreSQL, Redis, object storage, payment APIs, and Stellar RPC.
- **Restarts** of stateful dependencies mid-operation.
- **Throttling** responses from object storage and external APIs.
- **Malformed responses** from payment APIs and Stellar RPC.

Each scenario asserts the acceptance criteria:

1. No dependency outage creates duplicate payouts or loses committed match state.
2. Health/readiness and user-facing errors distinguish recoverable degradation.
3. Recovery drains/reconciles pending work and returns the system to a healthy
   state.

Scenarios are bounded and run in staging, recording expected versus observed
behavior for each injected fault.
