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

## Secret Rotation Runbook

This runbook defines how every credential class is rotated, how compromise response works without downtime, and who owns each step. It is the operator-facing companion to the automated rotation tests in `tests/integration/secret_rotation.rs`.

### Secret inventory

| Class | Env var(s) | Consumer service | Overlap required? |
|-------|-----------|------------------|-------------------|
| JWT signing | `JWT_SECRET`, `JWT_REFRESH_SECRET` | Auth Service | Yes (dual-key verify) |
| Database | `DATABASE_URL` (password component) | All services | Yes (dual-role) |
| Redis | `REDIS_URL` (password component) | Match / Leaderboard | Yes (dual-ACL user) |
| Object store | `S3_ACCESS_KEY`, `S3_SECRET_KEY` | Tournament / Wallet | Yes (two access keys) |
| Payment | `PAYSTACK_SECRET`, `FLUTTERWAVE_SECRET` | Wallet Service | Yes (provider dual-key) |
| Stellar signing | `STELLAR_ADMIN_SECRET` | Wallet / Stellar Service | Yes (two signers on account) |
| Email | `EMAIL_API_KEY` | Auth Service (OTP) | No (single active key) |
| Observability | `OTEL_EXPORTER_OTLP_HEADERS`, `SENTRY_DSN` | All services | No (single active token) |

### General rules

- **Never log credential material.** Secrets are only ever read through `config.rs`; log lines reference the *class* (e.g. `jwt.rotation`) and never the value. The rotation tests assert that no secret value appears in captured logs.
- **Overlap only where required.** Classes marked "Yes" accept an old and a new credential simultaneously for a bounded window; classes marked "No" are cut over atomically during a maintenance window.
- **Operator** is the on-call security engineer for the class owner team. **Validation** is the smoke check that proves the new credential works before the old one is retired. **Rollback** restores the previous credential from the secret manager. **Retirement** removes the old credential after the overlap window.

### JWT signing (`JWT_SECRET`, `JWT_REFRESH_SECRET`)

1. **Operator**: Auth Service on-call.
2. **Overlap**: Set `JWT_SECRET_PREVIOUS` to the current value and `JWT_SECRET` to the new value. The verifier accepts both; the signer only issues with the new key. Overlap window: 2× access-token TTL (default 30 min).
3. **Validation**: `cargo test --test integration secret_rotation::jwt` plus a login smoke test confirming tokens signed by the new key verify.
4. **Rollback**: swap `JWT_SECRET` and `JWT_SECRET_PREVIOUS` back and redeploy; no user re-login required.
5. **Retirement**: after the overlap window, unset `JWT_SECRET_PREVIOUS` and redeploy. Refresh tokens follow the same procedure with `JWT_REFRESH_SECRET`.

### Database (`DATABASE_URL`)

1. **Operator**: Platform DBA.
2. **Overlap**: Create a new role with the same grants, deploy the new `DATABASE_URL`, keep the old role active. Overlap window: one full deploy cycle.
3. **Validation**: `./scripts/migration-status.sh` and a health check against `/health`.
4. **Rollback**: redeploy the previous `DATABASE_URL`; the old role is still active.
5. **Retirement**: `REVOKE` and `DROP ROLE` the old role once no connection uses it (`pg_stat_activity`).

### Redis (`REDIS_URL`)

1. **Operator**: Platform on-call.
2. **Overlap**: Create a second ACL user with identical permissions; deploy the new `REDIS_URL`. Overlap window: one deploy cycle.
3. **Validation**: leaderboard read/write smoke test.
4. **Rollback**: redeploy the previous `REDIS_URL`.
5. **Retirement**: `ACL DELUSER` the old user after `CLIENT LIST` shows no connections.

### Object store (`S3_ACCESS_KEY`, `S3_SECRET_KEY`)

1. **Operator**: Platform on-call.
2. **Overlap**: Issue a second access key for the same IAM user; deploy the new pair. Overlap window: one deploy cycle.
3. **Validation**: upload/download smoke test through the Tournament Service.
4. **Rollback**: redeploy the previous key pair.
5. **Retirement**: deactivate and delete the old access key.

### Payment (`PAYSTACK_SECRET`, `FLUTTERWAVE_SECRET`)

1. **Operator**: Wallet Service on-call + finance approver.
2. **Overlap**: Providers support two active secret keys; add the new key in the provider dashboard, deploy it, keep the old key active. Overlap window: 24 h.
3. **Validation**: `cargo test --test integration secret_rotation::payment` and a sandbox charge + webhook verification.
4. **Rollback**: redeploy the previous secret; the old key is still active in the provider dashboard.
5. **Retirement**: revoke the old key in the provider dashboard after the overlap window.

### Stellar signing (`STELLAR_ADMIN_SECRET`)

1. **Operator**: Wallet Service on-call + treasury approver.
2. **Overlap**: Add the new key as a second signer on the Stellar account (`set_options`), deploy the new `STELLAR_ADMIN_SECRET`. Overlap window: until the next ledger close plus one deploy cycle.
3. **Validation**: `cargo test --test integration secret_rotation::stellar` and a testnet payout.
4. **Rollback**: redeploy the previous secret; the old signer is still on the account.
5. **Retirement**: remove the old signer with `set_options` and confirm the account threshold still passes.

### Email (`EMAIL_API_KEY`)

1. **Operator**: Auth Service on-call.
2. **Overlap**: None. Issue the new key, deploy, and revoke the old key in the same window.
3. **Validation**: send a test OTP to an internal address.
4. **Rollback**: redeploy the previous key (kept in the secret manager until validation passes).
5. **Retirement**: revoke the old key immediately after validation.

### Observability (`OTEL_EXPORTER_OTLP_HEADERS`, `SENTRY_DSN`)

1. **Operator**: Platform on-call.
2. **Overlap**: None. Rotate the ingest token, deploy, and revoke the old token.
3. **Validation**: confirm spans/metrics arrive in the backend within 5 min.
4. **Rollback**: redeploy the previous token.
5. **Retirement**: revoke the old token after validation.

### Compromise response

On suspected compromise of any class: rotate immediately using the procedure above, then revoke the old credential **without waiting for the overlap window** (overlap exists for planned rotation, not for incidents). Record the incident, the class, the operator, and the validation evidence in the rehearsal log.

### Staging rehearsal record

Before this runbook is considered proven, staging must rehearse at least one **payment** and one **signing** credential:

- **Payment rehearsal**: rotate `PAYSTACK_SECRET` in staging using the overlap procedure; capture the sandbox charge and webhook verification output.
- **Signing rehearsal**: rotate `STELLAR_ADMIN_SECRET` on the staging Stellar account using the dual-signer procedure; capture the testnet payout transaction hash.

Both rehearsals are reviewed by the Wallet Service operator and linked from the PR that introduces this runbook. Automated coverage lives in `tests/integration/secret_rotation.rs`.

## Code Organization & Architecture

### Module Structure
The backend follows a clean architecture pattern with clear separation of concerns:

- **`api_error.rs`**: Centralized error handling with custom error types and HTTP status mapping
- **`config.rs`**: Environment configuration management with validation and defaults
- **`db.rs`**: Database connection pooling, transaction management, and connection health checks
- **`lib.rs`**: Public API exports and library initialization
- **`main.rs`**: Application entry point, server startup, and graceful shutdown
- **`middleware.rs`**: Custom middleware for authentication, logging, CORS, and rate limiting
- **`telemetry.rs`**: Structured logging, tracing, me

/* … truncated 8025 chars — edit only what you need near the top … */
