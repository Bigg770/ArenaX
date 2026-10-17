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
│   └── unit/             # Unit tests for individual modules
├── target/               # Rust build artifacts
├── Cargo.toml           # Rust dependencies and workspace configuration
├── Cargo.lock           # Locked dependency versions
├── Dockerfile           # Container configuration
├── test_ci_locally.sh   # Local CI testing script
└── README.md            # This documentation
```

## Setup & Development

### Prerequisites
- Rust toolchain (`cargo`, `rustup`) - latest stable version
- PostgreSQL (v13+) with sharding support
- Redis (v6+) with Pub/Sub enabled
- MinIO (or AWS S3) for file storage
- Docker and Docker Compose for local development
- Stellar CLI and SDK for blockchain integration
- Node.js (v18+) for testing scripts

### Installation

```bash
# Clone the repository
git clone https://github.com/arenax/arenax.git
cd backend

# Install Rust dependencies
cargo build

# Set up environment variables
cp .env.example .env
# Edit .env with your configuration

# Run database migrations
./scripts/migrate.sh

# Start the backend server
cargo run

# Or run with Docker Compose
docker-compose up -d
```

### Development Commands

```bash
# Run tests
cargo test

# Run tests with coverage
cargo test --coverage

# Run integration tests
cargo test --test integration

# Run specific test module
cargo test auth::tests

# Check code formatting
cargo fmt

# Run linter
cargo clippy

# Run local CI tests
./test_ci_locally.sh

# Database operations
sqlx migrate add -r <migration_name>
./scripts/verify-migrations.sh
./scripts/migrate.sh
./scripts/migration-status.sh
./scripts/backup-database.sh
./scripts/rollback-last-migration.sh

# Stellar integration testing
./scripts/test_stellar.sh
```

### Environment Variables

```env
# Database
DATABASE_URL=postgres://user:pass@localhost:5432/arenax
BACKEND_MIGRATION_MODE=run
REDIS_URL=redis://localhost:6379

# Storage
S3_ENDPOINT=http://localhost:9000
S3_ACCESS_KEY=minio

# ── Secrets ──────────────────────────────────────────────────────────────────
# Every secret must be at least 32 characters long and must not be a known
# placeholder (`supersecretkey`, `changeme`, ...). The backend refuses to start
# otherwise. Generate real values with `openssl rand -base64 48`.
S3_SECRET_KEY=dev-only-s3-secret-replace-me-0123456789

# Payments
PAYSTACK_SECRET=dev-only-paystack-secret-replace-me-0123456789
FLUTTERWAVE_SECRET=dev-only-flutterwave-secret-replace-me-0123456789

# Authentication
JWT_SECRET=dev-only-jwt-secret-replace-me-0123456789abcdef
# Optional: dedicated refresh-token secret (falls back to JWT_SECRET when unset)
JWT_REFRESH_SECRET=

# Stellar Configuration
STELLAR_NETWORK_URL=https://horizon-testnet.stellar.org
STELLAR_ADMIN_SECRET=dev-only-stellar-admin-secret-replace-me
SOROBAN_CONTRACT_PRIZE=CAXXX...
SOROBAN_CONTRACT_REPUTATION=CBXXX...

# AI
AI_MODEL_PATH=./models/anti_cheat.tflite
```

`BACKEND_MIGRATION_MODE` defaults to `run`, which applies and validates SQLx migrations during backend startup. Use `disabled` only when migrations are applied by a separate deployment step. See [MIGRATIONS.md](MIGRATIONS.md) for the full migration workflow, rollback process, and CI expectations.

## Code Organization & Architecture

### Module Structure
The backend follows a clean architecture pattern with clear separation of concerns:

- **`api_error.rs`**: Centralized error handling with custom error types and HTTP status mapping
- **`config.rs`**: Environment configuration management with validation and defaults
- **`db.rs`**: Database connection pooling, transaction management, and connection health checks
- **`lib.rs`**: Public API exports and library initialization
- **`main.rs`**: Application entry point, server startup, and graceful shutdown
- **`middleware.rs`**: Custom middleware for authentication, logging, CORS, and rate limiting
- **`telemetry.rs`**: Structured logging, tracing, metrics, and observability setup
