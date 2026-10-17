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

## Evidence Object Store: Backup, Recovery & Deletion

Evidence objects (match replays, anti-cheat captures, dispute attachments) live in the S3/MinIO object store. Their availability, disaster recovery, and privacy deletion must be consistent across the primary bucket, replicas, and backups.

### Bucket versioning

- Versioning is **enabled** on the primary evidence bucket and every replica bucket. Overwrites and deletes never destroy prior object versions, so an accidental or malicious delete is recoverable.
- Each evidence object is written once and treated as immutable; corrections are written as a new version, never an in-place overwrite.
- Version IDs are recorded alongside the evidence hash in the database so a specific version can be restored and verified.
- Lifecycle rules expire non-current versions only after the retention window (see below); current versions are never auto-expired while under legal hold.

### Encryption

- **At rest**: evidence objects and all backups/replicas use server-side encryption (SSE-S3 or SSE-KMS). KMS keys are scoped per environment and rotated on the documented schedule; backups are encrypted with the same key policy as the primary bucket.
- **In transit**: all access to the object store (uploads, downloads, replication, backup/restore) uses TLS. Plaintext HTTP access is rejected.
- Encryption keys and bucket policies are part of the disaster-recovery runbook so a restore reproduces the same access controls.

### Retention & legal hold

- Evidence objects are retained for the documented retention window; retention applies identically to the primary bucket, replicas, and backups.
- A **legal hold** on an evidence object blocks deletion and version expiration on the primary, all replicas, and all backups until the hold is released. Backup expiration policies must honor active legal holds and never expire held objects.
- Releasing a hold re-enables normal retention/expiration; the release is audited.

### Deletion propagation

- A privacy/erasure deletion removes the object (all versions) from the primary bucket and is propagated to every replica and backup within the documented propagation window.
- Deletion is blocked while a legal hold is active; once released, the deletion resumes and propagates.
- Deletion events are recorded in an audit log with object key, version IDs, and target stores so propagation can be verified.

### Recovery point & object consistency

- Backups capture a consistent point-in-time snapshot of the evidence bucket (including version metadata). The documented RPO bounds how much recent evidence a restore may lose; the RTO bounds restore time.
- After a restore, object count and per-object **evidence hashes** are verified against the recorded hashes; any mismatch fails the restore validation.
- Restores reproduce the original access policy (bucket policy, encryption, legal holds) so restored evidence is neither over- nor under-exposed.

### Validation

Perform a staging restore of a representative evidence object and confirm: the restored object's hash matches the recorded evidence hash, the access policy matches the primary bucket, and any active legal hold is preserved. Verify that a test deletion propagates to replicas and backups within the propagation window.

## PostgreSQL Capacity & Connection-Pool Budgets

Connection exhaustion and unpredictable latency are the main scaling risks once service replicas and background workers multiply. Every process that talks to PostgreSQL must fit inside a shared, documented connection budget.

### Per-process pool sizing

Each backend process owns a single SQLx pool (`db.rs`). Size it explicitly rather than relying on defaults:

| Process | Pool max (`DATABASE_MAX_CONNECTIONS`) | Notes |
| --- | --- | --- |
| API replica | 10 | One pool per replica; requests borrow for the duration of a transaction only |
| Background worker | 5 | Worker concurrency is capped at the pool size so jobs never queue on acquisition |

- `DATABASE_MIN_CONNECTIONS` (default `2`) keeps warm connections ready to absorb bursts.
- `DATABASE_ACQUIRE_TIMEOUT_SECS` (default `5`) bounds how long a request waits for a connection before failing fast.
- `DATABASE_IDLE_TIMEOUT_SECS` (default `600`) and `DATABASE_MAX_LIFETIME_SECS` (default `1800`) recycle idle/stale connections so they do not accumulate against `max_connections`.

### Worker concurrency

Background workers must never open more concurrent transactions than their pool allows. Cap worker concurrency at the worker pool size (5) so a burst of jobs cannot starve the API pool or exhaust the database.

### Transaction duration

Keep transactions short and scoped: acquire a connection, run the transaction, commit or roll back, and release. Never hold a connection across an `.await` on external I/O (Stellar, payments, S3). Long-running transactions inflate pool occupancy and acquisition latency; treat any transaction approaching the acquire timeout as a defect.

### Connection budget & replica envelope

PostgreSQL `max_connections` must cover the sum of all pools plus operational headroom for migrations, admin sessions, and failover:

```
max_connections >= (api_replicas × api_pool_max)
                 + (worker_replicas × worker_pool_max)
                 + headroom
```

Documented deployment envelope (leaves ~30% headroom on a `max_connections = 200` instance):

| Component | Replicas | Pool max | Connections |
| --- | --- | --- | --- |
| API | 8 | 10 | 80 |
| Workers | 4 | 5 | 20 |
| Migrations / admin / failover headroom | — | — | 40 |
| **Total** | | | **140 / 200** |

Scaling replicas beyond this envelope requires raising `max_connections` (or adding a pooler such as PgBouncer) first. Update this table whenever replica counts or pool sizes change.

### Observability

Pool saturation and acquisition latency must be observable so overload is caught before it becomes an outage:

- **Saturation**: track in-use vs. idle vs. max connections per process; alert when in-use stays above ~80% of pool max.
- **Acquisition latency**: measure time spent waiting for a connection; alert when p95 approaches `DATABASE_ACQUIRE_TIMEOUT_SECS`.
- **Transaction duration**: record per-transaction timing to spot slow queries holding connections.

### Failing safely

When the pool is saturated, acquisition times out after `DATABASE_ACQUIRE_TIMEOUT_SECS` and the request fails with a `503 Service Unavailable` (overload) response instead of hanging. Transactions are always committed or rolled back via RAII guards so a timeout or error never leaks a connection or leaves an open transaction. Clients should treat `503` as retryable with backoff.

### Validation

Load-test the API plus workers at the documented replica envelope (8 API + 4 worker replicas) and confirm PostgreSQL stays stable: connection count below `max_connections`, acquisition latency within budget, and no leaked or idle-in-transaction connections.

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
│   └── unit/             # Unit tests for individual modules
├── target/               # Rust build artifacts
├── Cargo.toml           # Rust dependencies and workspace configuration
├── Cargo.lock           # Locked dependency

/* … truncated 3893 chars — edit only what you need near the top … */
