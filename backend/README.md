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

### Profiles

| Profile | Clients | Rooms | Fanout msg/s | Slow consumers | Reconnect rate |
| --- | --- | --- | --- | --- | --- |
| `tournament-peak` | 5,000 | 250 | 20,000 | 1% | 0 |
| `slow-consumer` | 1,000 | 50 | 5,000 | 20% | 0 |
| `reconnect-storm` | 5,000 | 250 | 20,000 | 1% | 50%/min |

Each simulated client authenticates with a short-lived JWT issued by the auth
service, joins its assigned room, and then either reads at full speed, reads
slowly, or disconnects and reconnects on a schedule.

### Measured signals

The harness records, per run:

- **Memory**: RSS of the realtime process, sampled every second.
- **Queue depth**: per-connection outbound buffer length and the room broadcast
  queue length, sampled every 100 ms.
- **Delivery latency**: p50/p95/p99 from publish timestamp to client receipt.
- **Dropped clients**: count and reason (slow-consumer eviction, backpressure,
  server restart).

### Capacity envelope

The documented envelope for a single realtime node is:

| Metric | Envelope |
| --- | --- |
| Concurrent connections | 10,000 |
| Room fanout | 40,000 msg/s |
| p99 delivery latency | < 250 ms |
| Per-connection outbound buffer | < 256 KiB |
| RSS | < 2 GiB |

A run passes when every measured signal stays inside the envelope. Slow
consumers must be evicted once their per-connection buffer reaches the cap
rather than growing unbounded, and reconnect synchronization must converge
without duplicate state mutations (verified by comparing the room state hash
before the storm and after all clients have resynced).

### Interpreting results

- If **queue depth** grows without bound, the fanout path is not applying
  backpressure — check the per-connection buffer cap.
- If **p99 latency** exceeds the envelope while queue depth is flat, the
  bottleneck is downstream (Redis Pub/Sub or the DB), not the WebSocket layer.
- If **reconnect synchronization** produces duplicate mutations, the resync
  path is replaying events instead of reconciling to a snapshot.

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
