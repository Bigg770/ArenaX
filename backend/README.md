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

## Backup & Recovery Objectives

PostgreSQL is the single source of truth for financial, match, session, and wallet state (see the Redis policy below). Backups therefore cover **PostgreSQL plus the required metadata and secrets** needed to bring the service back: database credentials, JWT signing keys, Stellar signing keys, and payment provider keys.

### Recovery objectives

| Data set | RPO (max data loss) | RTO (max downtime) |
| --- | --- | --- |
| PostgreSQL (all schemas) | **15 minutes** (continuous WAL archiving + 15-min base backups) | **60 minutes** |
| Required metadata (migrations, config) | 0 (versioned in git) | 15 minutes |
| Required secrets (JWT, Stellar, payment keys) | 0 (stored in the secrets manager with versioning) | 15 minutes |

These objectives are the contract the backup and restore-drill procedures below are measured against. A drill that misses either objective is a failed drill and must be fixed before the next release.

### Backup workflow

- **Encrypted at rest:** every PostgreSQL dump and WAL segment is encrypted with `age` (or `gpg`) using a public recipient key before leaving the host. Plaintext backups are never written to shared storage.
- **Access-limited:** backups are written to a dedicated bucket/prefix with least-privilege IAM — the backup writer can only `PutObject`, and only the restore role can `GetObject`. Bucket versioning and object lock are enabled so backups cannot be silently deleted or overwritten.
- **Retention:** 35 days of daily base backups plus 7 days of WAL, matching the RPO above. Retention is enforced by lifecycle policy, not by the backup job.
- **Independently verified:** a separate verification job (not the backup job) downloads each new backup, recomputes its SHA-256 checksum, compares it against the checksum recorded at creation time, and performs a `pg_restore --list` / `pg_verifybackup` integrity check. Verification failures page on-call and mark the backup as untrusted.

### Restore-drill procedure

Run this drill at least monthly and before any release that changes the schema. Retain the resulting report.

1. **Provision an isolated staging target.** Use a throwaway database instance and a separate secrets scope; never restore over production.
2. **Restore PostgreSQL.** Fetch the latest verified base backup and the WAL needed to reach the target point in time, decrypt, and restore. Record the wall-clock start and end.
3. **Restore metadata and secrets.** Apply migrations to the restored database and load the required secrets into the staging scope from the secrets manager.
4. **Verify integrity.** Confirm the restored database passes `pg_verifybackup`/checksum validation and that row counts for critical tables (`wallets`, `transactions`, `matches`, `tournaments`, `sessions`) match the source snapshot.
5. **Validate the application.** Start the backend against the restored database and secrets, then check `GET /health` and `GET /ready`, run the smoke test suite, and confirm a representative read (leaderboard) and a representative write (a test match result) succeed.
6. **Measure against objectives.** Record the measured RTO (time from drill start to a passing application validation) and the measured data loss (difference between the source's latest committed transaction and the restored point). Both must be within the objectives table above.
7. **Safe traffic cutover (production only).** If this drill is being used for an actual recovery: put the service in maintenance mode, drain in-flight requests, point the application at the restored database, verify `/ready`, then shift traffic gradually (canary → full) while watching error rates. Roll back by repointing to the previous database if validation fails.
8. **Retain the report.** Store the drill report (date, operator, measured RTO, measured data loss, pass/fail, and any remediation) alongside the backup records.

## Redis Failure Semantics & Recovery Policy

Redis is used for **derived, rebuildable state only**. PostgreSQL (and the Stellar ledger for on-chain effects) is the single source of truth for all financial, match, session, and wallet state. No authoritative state may exist only in Redis.

### Redis usage inventory

| Redis-backed operation | Classification | Durable backing |
| --- | --- | --- |
| Leaderboard / ranking sorted sets | Cache (derived) | `matches`, `tournaments`, reputation rows in Postgres |
| Matchmaking queue | Ephemeral coordination | Match records in Postgres; queue is re-derivable from open matches |
| Pub/Sub event fan-out (match/session/wallet events) | Transport (at-most-once) | Event rows in Postgres; consumers reconcile from durable records |
| Session / auth token cache | Cache (derived) | `sessions` table in Postgres; JWT is authoritative |
| Wallet balance / payout cache | Cache (derived) | `wallets`, `transactions` tables + Stellar ledger |
| Rate-limit counters | Ephemeral | None required; loss only loosens limits temporarily |

**Invariant:** financial and final match state are always committed to Postgres (and, where applicable, confirmed on-chain) *before* any Redis write. Redis is never the commit point.

### Degraded behavior per operation

- **Leaderboard reads/writes:** on Redis error, serve rankings computed directly from Postgres (slower path). Writes are best-effort; a failed write is logged and the entry is rebuilt on next read. No duplicate scoring — scores are recomputed from durable match results, not incremented blindly.
- **Matchmaking queue:** if Redis is unavailable, new matchmaking requests are rejected with `503` and a `Retry-After` header rather than silently queued in memory (avoids split-brain duplicate matches). Existing matches continue from Postgres.
- **Pub/Sub:** publishers treat delivery as best-effort; on publish failure the event is already persisted in Postgres and consumers pick it up via the durable event log. Consumers are idempotent (keyed by event id) so replays never create duplicate work.
- **Session cache:** cache miss or Redis outage falls back to validating against the `sessions` table. Auth never fails open.
- **Wallet cache:** reads fall back to Postgres/Stellar; writes go to Postgres first and invalidate the cache. A stale cache is never trusted for balance checks.
- **Rate limiting:** on Redis outage, fall back to a conservative in-process limiter; counters reset on recovery.

### Recovery policy

After a Redis restart or partial connectivity:

1. **Reconnect** with bounded exponential backoff; the process stays up and serves degraded paths meanwhile.
2. **Rebuild derived state** from durable records: leaderboards are recomputed from Postgres match results, session and wallet caches are lazily repopulated on read, and the matchmaking queue is reconstructed from open matches.
3. **Replay** any Pub/Sub events missed during the outage by draining the durable event log; consumers dedupe by event id so replay is idempotent.
4. **No data loss for authoritative state** — because it was never only in Redis, recovery never needs to reconstruct financial or final match state from the cache.

### Health & readiness signals

- `GET /health` reports process liveness.
- `GET /ready` reports readiness and includes a `redis` component status (`ok` / `degraded` / `down`). Redis being `degraded` does **not** fail readiness for operations that have a durable fallback; it is surfaced so operators can act. Operations with no safe fallback (matchmaking enqueue) return `503` while Redis is down.

### Validation

Integration tests exercise Redis restart, timeout, and partial-connectivity scenarios to confirm: no authoritative state is lost, degraded paths behave as documented, and recovery rebuilds derived state without duplicate work.

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
│   │   ├── leaderboard.rs # Rankings and reputation endpoints
│   │   └── health.rs      # Health check and monitoring endpoints
│   ├── service/           # Business logic and service layer
│   │   ├── mod.rs         # Service module exports
│   │   ├── auth_service.rs    # Authentication business logic
│   │   ├── tournament_service.rs # Tournament management logic
│   │   ├── match_service.rs     # Match and matchmaking logic
│   │   ├── wallet_service.rs    # Payment processing logic
│   │   ├── anti_cheat_service.rs # AI-powered cheating detection
│   │   ├── leaderboard_service.rs # Rankings and reputation logic
│   │   └── stellar_service.rs   # Stellar blockchain integration
│   └── utils/             # Shared utilities and helper functions
│       ├── mod.rs         # Utils module exports
│       ├── crypto.rs      # Cryptographic utilities
│       ├── validation.rs  # Input validation helpers
│       ├── stellar_utils.rs # Stellar-specific utilities
│       └── constants.rs   # Application constants
├── migrations/            # Database migrations (SQLx)
├── scripts/              # Deployment and utility scripts
│   ├── deploy.sh         # Production deployment script
│   ├── migrate.sh        # Database migration script
│   └── test_stellar.sh   # Stellar integration testing
├── tests/                # Integration and unit tests
│   ├── common/           # Shared test utilities
│   ├── integration/      # End-to-end integration tests
│   └── unit/             # Unit
