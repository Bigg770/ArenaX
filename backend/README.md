# 🎮 ArenaX Backend

## Overview

The ArenaX backend is a high-performance **Rust-based microservices architecture** that powers the competitive gaming tournament platform. It integrates with the **Stellar blockchain** for transparent prize pool management, payouts, and reputation tracking, while providing real-time matchmaking and AI-driven anti-cheat capabilities.

## Tech Stack

- **Language**: Rust
- **Web Framework**: Actix-web + Axum
- **Async Runtime**: Tokio
- **Database**: PostgreSQL (with sharding)
- **Cache & Messaging**: Redis (Pub/Sub, leaderboards)
- **Storage**: S3/MinIO
- **Blockchain**: Stellar Rust SDK + Soroban smart contracts
- **Payments**: Paystack, Flutterwave
- **AI**: TensorFlow Lite (via `tract` crate)

## Architecture

### Microservices Design
- **Auth Service**: User authentication and Stellar account management
- **Tournament Service**: Tournament lifecycle and prize pool management
- **Match Service**: Matchmaking, scoring, and dispute handling
- **Wallet Service**: Payment processing and Stellar integration
- **Anti-Cheat Service**: AI-powered cheating detection
- **Leaderboard Service**: Real-time rankings and reputation tracking

### Stellar Integration
- **Account Management**: Create and manage user Stellar accounts
- **Asset Issuance**: ArenaX Tokens and Reputation Tokens
- **Smart Contracts**: Soroban contracts for automated operations
- **Transaction Processing**: Prize pool management and payouts

## Hermetic Integration Tests

Backend integration tests are **hermetic**: they never depend on a developer-local
database, Redis instance, or live provider. Every test provisions its own isolated
state and tears it down even when it fails, so the suite is reproducible on a clean CI
worker and safe to run in parallel.

### Shared fixtures

Shared fixtures live in `backend/tests/common/` and are pulled in with
`mod common;`. They provide:

- **`TestDb`** — a real PostgreSQL database (via `sqlx`/`testcontainers`) with a
  **unique schema per test** (`test_<uuid>`). The schema is dropped on `Drop`, so
  cleanup runs on success, panic, or early return. Database semantics stay real —
  the DB is never mocked.
- **`TestRedis`** — a real Redis container with a **unique key namespace per test**
  (`test:<uuid>:`). Keys are flushed on `Drop`; no fixed keys or shared DB index.
- **`TestStorage`** — an S3/MinIO container with a **unique bucket per test**
  (`test-<uuid>`), removed on `Drop`.
- **`MockProviders`** — external providers (Stellar Horizon, Paystack, Flutterwave)
  are mocked at the HTTP boundary with `wiremock`, so no network egress occurs while
  the service code under test runs unmodified.

### Rules for hermetic tests

1. **Unique state per test.** Never reuse a schema, bucket, Redis key, or fixed ID.
   Derive identifiers from the fixture's per-test UUID.
2. **Clean up on failure.** Use the RAII fixtures (`TestDb`, `TestRedis`,
   `TestStorage`) rather than manual setup/teardown so cleanup runs on panic.
3. **No shared global state.** Do not mutate process-wide statics, environment
   variables, or a shared connection pool between tests. Pass fixtures explicitly.
4. **Mock only at the boundary.** Mock external providers (Horizon, payment
   gateways) with `MockProviders`; keep PostgreSQL, Redis, and object storage real.
5. **Order independence.** Tests must pass in any order and under
   `cargo test -- --test-threads=<n>`; if a test needs ordering, it is a bug.

### Running the suite

```bash
# Requires a Docker daemon for testcontainers.
cargo test --all-features -- --test-threads=8
```

Run the suite repeatedly on a clean CI worker to confirm hermeticity; a passing run
must not leave schemas, buckets, or Redis keys behind.

## Service SLOs, Alerts & Runbooks

Operational targets are tied to player-impacting workflows rather than generic health
indicators. Each SLO below has a measured signal, evaluation window, owner, and an
error-budget response. Signals are emitted by `src/telemetry.rs` (structured request
metrics) and surfaced in the dashboards described in [docs/OBSERVABILITY.md](../docs/OBSERVABILITY.md).

### SLO Definitions

| Workflow | SLI (measured signal) | SLO target | Window | Owner |
| --- | --- | --- | --- | --- |
| **Login** | Ratio of `POST /auth/login` responses with status < 500 and p95 latency | 99.9% success, p95 < 400 ms | 30 days (rolling) | Auth team |
| **Tournament join** | Ratio of `POST /tournaments/{id}/join` responses with status < 500 and p95 latency | 99.5% success, p95 < 800 ms | 30 days (rolling) | Tournament team |
| **Match updates** | Ratio of `PATCH /matches/{id}` (score/state) responses with status < 500 and p95 latency | 99.5% success, p95 < 500 ms | 30 days (rolling) | Match team |
| **Settlement** | Ratio of settlement jobs completing without error and p95 job duration | 99.0% success, p95 < 5 s | 30 days (rolling) | Wallet team |

### Error-Budget Response

Each SLO carries a 30-day error budget (`1 - SLO target`). Response is burn-rate driven:

- **< 50% budget consumed**: normal operation, no action.
- **50–75% consumed**: owner reviews recent error sources weekly; file follow-ups for top contributors.
- **75–100% consumed**: freeze non-critical changes to the affected workflow; owner prioritizes reliability fixes.
- **Budget exhausted**: feature work on the workflow pauses until the budget recovers; incident review required.

### Alert Thresholds

Alerts are derived from the SLOs and use multi-window burn rates so transient noise does
not page. A page fires only when **both** a fast (5 min) and slow (1 h) window exceed the
threshold; single-window spikes route to the team channel instead of paging.

| Alert | Condition | Severity |
| --- | --- | --- |
| `LoginErrorBudgetFastBurn` | 5 min error rate > 14.4x budget **and** 1 h error rate > 14.4x budget | Page |
| `LoginLatencyDegraded` | p95 > 400 ms sustained for 10 min | Ticket |
| `TournamentJoinFastBurn` | 5 min error rate > 14.4x budget **and** 1 h error rate > 14.4x budget | Page |
| `MatchUpdateFastBurn` | 5 min error rate > 14.4x budget **and** 1 h error rate > 14.4x budget | Page |
| `SettlementFastBurn` | 5 min failure rate > 14.4x budget **and** 1 h failure rate > 14.4x budget | Page |
| `SettlementBacklog` | pending settlements > 100 for 15 min | Ticket |

Transient single-request failures, brief latency blips, and deploy-window noise are
excluded via the sustained-window requirement and a 5-minute deploy suppression.

### Runbooks

Each alert links to a runbook covering first checks, safe mitigations, escalation, and
recovery verification.

**Login (`LoginErrorBudgetFastBurn` / `LoginLatencyDegraded`)**
1. *First checks*: confirm auth service health, DB connection pool saturation, and recent deploys in the last 30 min.
2. *Safe mitigations*: roll back the last auth deploy if correlated; scale auth replicas; verify Redis session store reachable.
3. *Escalation*: page Auth on-call; escalate to platform on-call if DB or Redis is the root cause.
4. *Recovery verification*: error rate back under budget for 30 min and p95 < 400 ms on the dashboard.

**Tournament join (`TournamentJoinFastBurn`)**
1. *First checks*: tournament service health, DB write latency, and lock contention on tournament rows.
2. *Safe mitigations*: shed load via rate limiting; disable non-essential join side effects; roll back recent tournament deploy.
3. *Escalation*: Tournament on-call; platform on-call for DB issues.
4. *Recovery verification*: join success rate ≥ 99.5% over 30 min and p95 < 800 ms.

**Match updates (`MatchUpdateFastBurn`)**
1. *First checks*: match service health, Redis Pub/Sub lag, and downstream anti-cheat latency.
2. *Safe mitigations*: decouple anti-cheat scoring to async if blocking; roll back recent match deploy; scale match replicas.
3. *Escalation*: Match on-call; anti-cheat owner if AI service is the bottleneck.
4. *Recovery verification*: update success rate ≥ 99.5% over 30 min and p95 < 500 ms.

**Settlement (`SettlementFastBurn` / `SettlementBacklog`)**
1. *First checks*: Stellar Horizon reachability, wallet service health, and settlement job queue depth.
2. *Safe mitigations*: pause new settlement submissions; retry failed jobs idempotently; fail over to backup Horizon endpoint.
3. *Escalation*: Wallet on-call; escalate to Stellar integration owner for chain-side failures.
4. *Recovery verification*: settlement success rate ≥ 99.0% over 30 min, backlog drained, and p95 job duration < 5 s.

### Staging Validation

To validate alerts and runbooks, simulate one dependency outage in staging:

1. Block egress to Stellar Horizon (or stop Redis) in the staging environment.
2. Confirm the corresponding burn-rate alert fires within the fast window and pages the correct owner.
3. Walk the runbook end-to-end: perform first checks, apply a safe mitigation, and verify escalation routing.
4. Restore the dependency and confirm recovery verification steps pass (error rate and latency back within SLO).
5. Record gaps found in the runbook and update it before the next drill.

## Project Structure

```
backend/
├── src/
│   ├── api_error.rs       # Centralized error handling and API error types
│   ├── config.rs          # Configuration management and environment variables
│   ├── db.rs              # Database connection and connection pooling
│   ├── lib.rs             # Library root and public API exports
│   ├── main.rs            # Application entry point and server startup
│   ├── middleware.rs      # Custom middleware implementations
│   ├── telemetry.rs       # Logging, tracing, and observability setup
│   ├── auth/              # Authentication and authorization modules
│   │   ├── mod.rs         # Auth module exports
│   │   ├── jwt.rs         # JWT token handling
│   │   ├── stellar.rs     # Stellar account management
│   │   └── otp.rs         # OTP verification system
│   ├── http/              # HTTP handlers and route definitions
│   │   ├── mod.rs         # HTTP module exports
│   │   ├── auth.rs        # Authentication endpoints
│   │   ├── tournaments.rs # Tournament management endpoints
│   │   ├── matches.rs     # Match and matchmaking endpoints
│   │   ├── wallet.rs      # Payment and Stellar integration endpoints
│   │   ├── lead

/* … truncated 5375 chars — edit only what you need near the top … */
