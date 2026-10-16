# 🎮 ArenaX Documentation


<!-- START STATUS METER -->
### 📊 Live Bounty Status Meter & Metrics
> **System Status**: `ONLINE 🟢` · **Health**: `[██████████████████████░░] 97.4%` · **Bounty #1149**: Verified

| 🎯 Total Bounties | ⚡ Active Issues | 🏆 Resolved Bounties | 💰 Reward Pool Volume | 👥 Registered Hunters | 📈 Resolution Rate |
|:---:|:---:|:---:|:---:|:---:|:---:|
| **1,647** | **42 Open** | **1,605 Closed** | **$124,500 USD** | **128 Users** | **97.4%** |

```
Status Meter: [██████████████████████░░] 97.4%
================================================================================
All automated claim checks, balance transfers, and PR verification pipelines active.
================================================================================
```
<!-- END STATUS METER -->

## 1. 🏗️ Project Overview

ArenaX is a competitive gaming tournament platform tailored for **amateur gamers**, enabling them to join tournaments, compete, report scores with proof, and receive instant payouts via local payment methods (Stripe, Opay, PalmPay, Bank transfers) and **Stellar blockchain-based payouts**. The platform leverages Stellar’s low-cost, fast, and transparent blockchain to manage tournament prize pools, payouts, and reputation systems, ensuring trust and fairness. Advanced features like real-time matchmaking, AI-driven anti-cheat, and community-driven tournaments enhance scalability and engagement.

**Core Goals**:
- Make **esports accessible** to everyday mobile and console gamers in Nigeria.
- Provide a **secure, fair environment** with advanced anti-cheat, score verification, and Stellar-based transparency.
- Enable **fast, transparent payouts** using local payment systems and Stellar blockchain for verifiable, low-cost transactions.
- Scale to support large-scale tournaments with real-time updates, distributed systems, and Stellar-backed prize pools.

**Stellar Blockchain Focus**:
- Use Stellar for transparent management of tournament prize pools and payouts.
- Issue custom assets on Stellar for in-platform rewards (e.g., ArenaX Tokens).
- Leverage Stellar’s decentralized exchange (SDEX) for converting rewards to local currency (NGN).
- Implement Stellar smart contracts (Soroban) for automated prize distribution and reputation tracking.

---

## 2. 📐 System Architecture

The architecture leverages Rust’s performance and safety, integrated with the **Stellar blockchain** for transparent and secure financial operations, alongside real-time interactions and AI analysis for fairness.

**Components**:
- **Frontend (Next.js PWA)**: Mobile-first progressive web app for seamless user interaction, including Stellar wallet integration for payouts.
- **Backend (Rust + Actix/Axum + Tokio)**: API handling authentication, tournaments, matches, wallets, and real-time updates, with Stellar SDK integration for blockchain operations.
- **PostgreSQL**: Persistent storage for users, tournaments, matches, wallets, and transaction logs.
- **Redis**: Caching, OTP storage, leaderboards, and Pub/Sub for real-time match and tournament updates.
- **S3/MinIO**: Storage for screenshots, game logs, and telemetry data for anti-cheat analysis.
- **Payment Gateways**: Paystack and Flutterwave for fiat deposits/withdrawals, integrated with Stellar for blockchain-based payouts.
- **AI Service**: Lightweight machine learning models for anti-cheat detection, analyzing screenshots and gameplay telemetry.
- **Stellar Blockchain**: Stellar network for managing tournament prize pools, payouts, and custom assets (e.g., ArenaX Tokens), with Soroban smart contracts for automation.
- **Event Streaming (Optional)**: Kafka or Redis Streams for event-driven match updates and leaderboard synchronization.

**Architecture Design**:
- **Microservices**: Backend split into modular services (auth, tournaments, matches, anti-cheat, Stellar integration) communicating via Redis Pub/Sub or gRPC for scalability.
- **Event-Driven**: Real-time updates for match scores, tournament states, and leaderboards using event streams, with Stellar transaction updates for payouts.
- **Distributed Systems**: Tournament state managed across multiple backend instances with Redis for coordination.
- **Stellar Integration**: Backend services interact with Stellar via the Rust Stellar SDK for account management, asset issuance, and Soroban smart contract execution.

**Stellar-Specific Implementation Needs**:
- Integrate **Stellar Rust SDK** for creating and managing Stellar accounts for users and tournaments.
- Deploy **Soroban smart contracts** for automated prize distribution and reputation point tracking.
- Set up **Stellar anchors** to bridge fiat (NGN) deposits/withdrawals with Stellar-based assets.
- Implement **Stellar SDEX integration** for converting ArenaX Tokens to XLM or NGN.
- Ensure **Stellar account security** with multi-signature accounts for tournament prize pools.

---

## 3. ⚙️ Tech Stack

- **Frontend**: Next.js (PWA), TailwindCSS, shadcn/ui
- **Backend**: Rust (Actix for actor-based concurrency, Axum for HTTP, Tokio for async tasks, SQLx for database interactions, Stellar Rust SDK for blockchain operations)
- **Database**: PostgreSQL (with sharding for scalability)
- **Cache & Messaging**: Redis (caching, Pub/Sub, leaderboards)
- **Storage**: S3/MinIO
- **Payments**: Paystack, Flutterwave (fiat), Stellar blockchain (crypto payouts)
- **AI**: Lightweight ML models (e.g., TensorFlow Lite via Rust’s `tract` crate) for anti-cheat
- **Blockchain**: Stellar network with Soroban smart contracts for prize pools, payouts, and reputation tracking
- **Monitoring**: Prometheus and Grafana for performance metrics
- **Rate Limiting**: Configurable API rate limiting for security

---

## 4. 🚀 Setup Guide

This guide is the single source of truth for local development. It is written so a new contributor can go from a clean checkout to running services and one meaningful test without tribal knowledge. Commands below are verified on **Linux (Ubuntu 22.04+) and macOS (13+)** with Docker Desktop or Docker Engine + Compose v2.

### 4.1 Prerequisites

| Tool | Version | Required? | Notes |
| --- | --- | --- | --- |
| Git | 2.30+ | Required | |
| Docker + Compose v2 | 24+ / v2.20+ | Required | Runs Postgres, Redis, MinIO |
| Rust toolchain (`rustup`, `cargo`) | stable | Required | Backend + contracts |
| Node.js | 18+ (LTS) | Required | Frontend |
| `sqlx-cli` | 0.7+ | Required | Migrations (`cargo install sqlx-cli --no-default-features --features postgres`) |
| Stellar CLI | latest | Optional | Only for Soroban contract work |
| Kafka | any | Optional | Only for event-streaming mode |

> **Required vs optional:** Postgres, Redis, and MinIO are required for the default local stack. Kafka, Stellar testnet credentials, and Paystack/Flutterwave keys are **optional** — the backend runs without them in local/test mode (see §4.5).

### 4.2 Repository layout

```
.
├── backend/     # Rust API (Axum + SQLx)
├── server/      # Service orchestration / deployment configs
├── frontend/    # Next.js PWA
├── contracts/   # Soroban smart contracts
└── docker-compose.yml
```

### 4.3 Start dependencies with Docker Compose

From the repository root:

```bash
# Clone
git clone https://github.com/arenax/arenax.git
cd arenax

# Start required infrastructure (Postgres, Redis, MinIO)
docker compose up -d postgres redis minio

# Wait for healthchecks to pass before running migrations
docker compose ps
```

**Compose dependency graph & startup order:**

| Service | Depends on | Healthcheck | Port(s) |
| --- | --- | --- | --- |
| `postgres` | — | `pg_isready` | `5432` |
| `redis` | — | `redis-cli ping` | `6379` |
| `minio` | — | HTTP `/minio/health/live` | `9000` (API), `9001` (console) |
| `backend` | `postgres`, `redis`, `minio` (all healthy) | HTTP `/health` | `8080` |
| `frontend` | `backend` | HTTP `/` | `3000` |

Compose waits for each dependency’s healthcheck before starting dependents, so `docker compose up -d` alone brings the stack up in the correct order. If you start services individually, always start `postgres`, `redis`, and `minio` first and confirm they are `healthy` in `docker compose ps`.

### 4.4 Environment setup (no real secrets required)

Copy the committed **example** files — never commit or copy real secrets:

```bash
cp backend/.env.example backend/.env
cp frontend/.env.example frontend/.env
```

The example files contain development-only placeholder values that satisfy the backend’s minimum secret length (≥ 32 chars) and are rejected in production. Replace them with your own local values if you like; do not commit `.env` files (they are git-ignored).

Key variables (see `backend/.env.example` for the full list):

```env
DATABASE_URL=postgres://user:pass@localhost:5432/arenax
REDIS_URL=redis://localhost:6379
S3_ENDPOINT=http://localhost:9000
S3_ACCESS_KEY=minio
# Secrets must be >= 32 chars and must not be a known placeholder — the
# backend refuses to start otherwise.
S3_SECRET_KEY=dev-only-s3-secret-replace-me-0123456789
PAYSTACK_SECRET=dev-only-paystack-secret-replace-me-0123456789
JWT_SECRET=dev-only-jwt-secret-replace-me-0123456789
# Optional integrations — leave unset to run in local/test mode
STELLAR_NETWORK_URL=https://horizon-testnet.stellar.org
STELLAR_SECRET_KEY=
SOROBAN_PRIZE_CONTRACT_ID=
SOROBAN_REPUTATION_CONTRACT_ID=
AI_MODEL_PATH=./models/anti_cheat.tflite
```

### 4.5 Test modes

- **Default (local/test):** Postgres + Redis + MinIO only. Optional integrations (Stellar, Paystack/Flutterwave, Kafka, AI model) are disabled and stubbed. This is the mode used by CI.
- **Integration:** Set the optional integration variables above to testnet/sandbox credentials. Never use mainnet or live payment keys locally.

### 4.6 Database migrations

Migrations live in `backend/migrations/` and are managed with `sqlx-cli`. Run them **after** Postgres is healthy and **before** starting the backend:

```bash
cd backend
sqlx database create   # first run only
sqlx migrate run       # apply all pending migrations
```

Re-run `sqlx migrate run` whenever you pull changes that add migrations. To reset locally: `sqlx database drop && sqlx database create && sqlx migrate run`.

### 4.7 Backend

```bash
cd backend
cargo build
cargo run          # serves on http://localhost:8080
```

### 4.8 Frontend

```bash
cd frontend
npm install
npm run dev        # serves on http://localhost:3000
```

### 4.9 Contracts (optional)

Only needed for Soroban contract work:

```bash
cd contracts
cargo build --target wasm32-unknown-unknown --release
```

### 4.10 Run one meaningful test

With dependencies up and migrations applied, run the backend test suite (or a single test):

```bash
cd backend
cargo test                 # full suite
cargo test <test_name>     # one test
```

If this passes from a clean checkout, your local setup is reproducible. Record any blocker you hit as an acceptance failure on issue #122.

### 4.11 Service ports (summary)

| Service | URL |
| --- | --- |
| Frontend | http://localhost:3000 |
| Backend API | http://localhost:8080 |
| Postgres | localhost:5432 |
| Redis | localhost:6379 |
| MinIO API / console | http://localhost:9000 / http://localhost:9001 |
