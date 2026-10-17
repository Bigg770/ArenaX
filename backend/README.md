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

# Connection pool budget (see "PostgreSQL Capacity & Connection-Pool Budgets")
DATABASE_MAX_CONNECTIONS=10
DATABASE_MIN_CONNECTIONS=2
DATABASE_ACQUIRE_TIMEOUT_SECS=5
DATABASE_IDLE_TIMEOUT_SECS=600
DATABASE_MAX_LIFETIME_SECS=1800

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
- **`telemetry.rs`**: Structured logging, tracing, me
