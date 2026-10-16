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

## API Reference

The API reference is **generated from the API contract**, not hand-written, so the
documented routes stay in sync with the handlers. The contract is the single
source of truth: every public endpoint is declared there with its method, path,
request/response schema, authorization requirements, and error behavior, and the
generator renders the reference from it.

### Generating the reference

```bash
# Regenerate the committed reference from the contract
cargo run --bin gen-api-docs

# Output (committed, do not edit by hand):
#   docs/api-reference.md
```

Do not edit `docs/api-reference.md` manually — it is generated output. Change the
contract and regenerate instead.

### Stale-doc detection in CI

CI regenerates the reference from a clean checkout and fails if the committed
output differs, so a contract change that is not accompanied by a regenerated
reference breaks the build:

```bash
# What CI runs (fails on any diff)
cargo run --bin gen-api-docs -- --check
```

### Endpoint coverage

Every supported public endpoint is documented with:

- **Method** and **path**
- **Request schema** (path/query/body parameters and their types)
- **Response schema** (success payload shape)
- **Authorization** (whether a bearer token is required and which scopes/roles apply)
- **Error behavior** (status codes and error payloads)

| Service | Base path | Auth |
| --- | --- | --- |
| Auth | `/api/v1/auth` | Public (login/register/OTP); bearer token for session endpoints |
| Tournaments | `/api/v1/tournaments` | Bearer token; organizer role for mutations |
| Matches | `/api/v1/matches` | Bearer token |
| Wallet | `/api/v1/wallet` | Bearer token |
| Leaderboard | `/api/v1/leaderboard` | Public read; bearer token for reputation writes |
| Health | `/health` | Public |

### Example requests

Examples use clearly fake placeholders. Replace `<YOUR_API_TOKEN>` with a real
token from your own environment — the values below are **not** live credentials
and will never authenticate against any deployment.

```bash
# Public: list tournaments (paginated)
curl -s 'https://<YOUR_API_HOST>/api/v1/tournaments?page=1&per_page=20'

# Authenticated: create a tournament (organizer role)
curl -s -X POST 'https://<YOUR_API_HOST>/api/v1/tournaments' \
  -H 'Authorization: Bearer <YOUR_API_TOKEN>' \
  -H 'Content-Type: application/json' \
  -d '{"name": "<TOURNAMENT_NAME>", "game": "<GAME_ID>", "entry_fee": 0}'

# Authenticated: fetch the current user's wallet balance
curl -s 'https://<YOUR_API_HOST>/api/v1/wallet/balance' \
  -H 'Authorization: Bearer <YOUR_API_TOKEN>'

# Public: read the leaderboard (paginated)
curl -s 'https://<YOUR_API_HOST>/api/v1/leaderboard?page=1&per_page=50'
```

### Pagination

List endpoints accept `page` (1-based, default `1`) and `per_page` (default `20`,
max `100`) and return a paginated envelope:

```json
{
  "data": [],
  "page": 1,
  "per_page": 20,
  "total": 0
}
```

### Error behavior

Errors use a consistent envelope with a machine-readable `code` and a
human-readable `message`:

```json
{
  "error": {
    "code": "<ERROR_CODE>",
    "message": "<human readable message>"
  }
}
```

| Status | Meaning |
| --- | --- |
| `400` | Invalid request (validation failure) |
| `401` | Missing or invalid bearer token |
| `403` | Authenticated but not authorized for this action |
| `404` | Resource not found |
| `409` | Conflict (e.g. duplicate resource) |
| `429` | Rate limited |
| `500` | Internal server error |

## Realtime WebSocket Load Testing

The realtime service (match updates, room fanout, presence) is load-tested with a
reproducible harness that simulates authenticated clients, tournament-peak fanout,
slow consumers, and reconnect storms. The harness lives in
`tests/load/websocket_fanout.rs` and is driven by the `ws-load` binary.

### Running the load profile

```bash
# Start the realtime service against a disposable database/Redis
cargo run --bin arenax-backend &

# Run the default tournament-peak profile (see below)
cargo run --bin ws-load -- --profile tournament-peak

# Reconnect-storm profile
cargo run --bin ws-load -- --profile reconnect-storm

# Slow-consumer profile (clients that stop reading)
cargo run --bin ws-load -- --profile slow-consumer
```
