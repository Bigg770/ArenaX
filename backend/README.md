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
| Object store | `S3_ACCESS_KEY`, `S3_SECRET_KEY` | Uploads / Wallet | Yes (dual-key) |
| Payments | `PAYSTACK_SECRET`, `FLUTTERWAVE_SECRET` | Wallet Service | Yes (dual-key) |
| Stellar admin | `STELLAR_ADMIN_SECRET` | Wallet / Stellar Service | Yes (dual-signer) |

### Rotation procedure (per class)

1. Generate the new value with `openssl rand -base64 48`.
2. Stage the new value alongside the old one (dual-key / dual-role / dual-signer) so both verify during the overlap window.
3. Roll the consumer service(s) so they load both values.
4. Flip the primary to the new value and confirm traffic is healthy.
5. Revoke the old value after the overlap window (default 24h) and remove it from config.

### Compromise response

If a secret is suspected exposed, treat it as compromised immediately: rotate per the procedure above, invalidate any tokens/roles/signers derived from it, audit access logs for the exposure window, and record the incident. See the exposure response section below.

## Least-Privilege API Threat Model

This threat model makes trust boundaries and abuse cases explicit for the gaming, financial, and blockchain flows. It is a living document: **update it whenever an API or custody boundary changes** (new endpoint, new trust transition, new signer, new payment provider). Security review signs off against the misuse-case checklist at the end.

### Assets

| Asset | Where it lives | Impact if compromised |
|-------|----------------|-----------------------|
| User credentials / sessions | Auth Service, `JWT_SECRET` | Account takeover |
| Match results & scores | Match Service, PostgreSQL | Fraudulent payouts, ranking manipulation |
| Prize pool funds | Stellar escrow / Soroban contracts | Direct financial loss |
| Payment records | Wallet Service, Paystack/Flutterwave | Double-spend, refund fraud |
| Uploaded files | S3/MinIO | Malware distribution, data exfiltration |
| Contract admin keys | `STELLAR_ADMIN_SECRET` | Full custody compromise |
| Reputation tokens | Soroban reputation contract | Sybil / reputation gaming |

### Actors

| Actor | Trust level | Notes |
|-------|-------------|-------|
| Anonymous client | Untrusted | Public endpoints only |
| Authenticated player | Low | Own resources only |
| Tournament organizer | Medium | Manages own tournaments |
| Match reporter (player) | Low | Reports own match outcome |
| Dispute adjudicator | Medium | Resolves disputes |
| Platform admin | High | Contract administration |
| Payment provider (webhook) | External | Authenticated via signature |
| Stellar network | External | Source of on-chain truth |

### Entry points & trust transitions

| Flow | Entry point | Trust transition | Mitigations (code) | Tests |
|------|-------------|------------------|--------------------|-------|
| Auth | `http/auth.rs` | Anonymous → authenticated | JWT signing/verify (`auth/jwt.rs`), OTP (`auth/otp.rs`), input validation (`utils/validation.rs`) | `tests/integration/`, `auth::tests` |
| Match reporting | `http/matches.rs` | Player → match result | Server-side scoring in `service/match_service.rs`, anti-cheat (`service/anti_cheat_service.rs`) | `tests/integration/` |
| Disputes | `http/matches.rs` | Player claim → adjudicator decision | Role check on adjudicator, audit trail in `match_service.rs` | `tests/integration/` |
| Payments | `http/wallet.rs` | External provider → credited balance | Webhook signature verify, idempotency in `service/wallet_service.rs` | `tests/integration/` |
| Uploads | `http/wallet.rs` / storage | Untrusted file → stored object | Type/size validation (`utils/validation.rs`), scoped S3 creds | `tests/integration/` |
| Contract admin | `service/stellar_service.rs` | Admin → on-chain action | Dual-signer, `STELLAR_ADMIN_SECRET` isolation, `utils/stellar_utils.rs` | `scripts/test_stellar.sh` |

### Accepted residual risks

| Risk | Decision | Owner |
|------|----------|-------|
| Client-reported match data trusted before anti-cheat scoring | Accepted; anti-cheat is best-effort, disputes are the backstop | Match Service owner |
| Webhook replay within idempotency window | Accepted; idempotency keys bound the window | Wallet Service owner |
| Uploaded files not fully sandboxed at rest | Accepted; served via signed URLs only | Platform owner |
| Stellar admin key held in env | Accepted pending HSM/KMS migration (tracked separately) | Platform owner |

### High-risk findings

High-risk findings must have a linked issue or an explicit owner/decision recorded here before merge. Current open items are tracked as linked issues in the repository issue tracker; each entry above names an owner so nothing is orphaned.

### Misuse-case checklist (security review sign-off)

- [ ] Every new endpoint is mapped to an actor and a trust transition above.
- [ ] Every mitigation row links to the enforcing code and at least one test.
- [ ] New custody/signer boundaries are documented and reviewed.
- [ ] Residual risks are explicitly accepted with an owner.
- [ ] High-risk findings have a linked issue or explicit owner/decision.
- [ ] This model was updated for any API or custody boundary change in the PR.
