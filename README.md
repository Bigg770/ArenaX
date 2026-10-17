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

## 0. 🎯 Service SLOs, Alerts & Runbooks

Operational targets are tied to player-impacting workflows rather than generic health checks. Each SLO below has a measured signal, evaluation window, owner, and an error-budget response. Signals are emitted by the backend telemetry module (`backend/src/telemetry.rs`) and the frontend (`frontend/lib/telemetry.ts`); see `docs/OBSERVABILITY.md` for the full signal catalog.

### SLO Definitions

| Workflow | SLI (measured signal) | SLO target | Window | Owner |
|:---|:---|:---:|:---:|:---|
| **Login** | `http_request_duration_seconds{route="/auth/login"}` success ratio (non-5xx) + p95 latency | 99.5% success, p95 < 800ms | 30d rolling | Auth team |
| **Tournament join** | `tournament_join_total{result}` success ratio + p95 latency | 99.0% success, p95 < 1.5s | 30d rolling | Tournaments team |
| **Match updates** | `match_update_total{result}` success ratio + p95 latency | 99.5% success, p95 < 500ms | 30d rolling | Matches team |
| **Settlement** | `settlement_total{result}` success ratio + p95 latency | 99.9% success, p95 < 5s | 30d rolling | Payments team |

### Error-Budget Response

- **< 50% budget consumed**: normal operation; no action.
- **50–75% consumed**: owner reviews dashboards weekly; freeze non-critical changes to the affected workflow.
- **75–100% consumed**: feature freeze on the workflow; owner files a reliability ticket and prioritizes fixes.
- **Budget exhausted**: halt deploys to the affected service until the SLO is back in budget for 24h.

### Alert Thresholds

Alerts are burn-rate based over sustained windows so transient noise does not page.

| Alert | Condition | Severity |
|:---|:---|:---|
| `LoginSLOBurn` | 5xx ratio > 2% for 10m **and** burn rate > 2x over 1h | page |
| `TournamentJoinSLOBurn` | error ratio > 3% for 15m **and** burn rate > 2x over 1h | page |
| `MatchUpdateLatency` | p95 > 500ms for 10m sustained | page |
| `SettlementFailure` | any settlement failure ratio > 0.5% for 5m **or** single hard failure | page |
| `SettlementLatency` | p95 > 5s for 15m sustained | ticket |

Single-sample spikes and short (<5m) blips are suppressed; only sustained-window breaches page.

### Runbooks

Each alert links to a runbook covering **first checks → safe mitigations → escalation → recovery verification**.

**Login (`LoginSLOBurn`)**
1. First checks: auth service health, DB connection pool saturation, Redis OTP store reachability, recent deploys.
2. Safe mitigations: scale auth replicas, roll back last deploy, fail over read replicas.
3. Escalation: Auth team on-call → platform on-call if DB/Redis implicated.
4. Recovery verification: 5xx ratio < 0.5% and p95 < 800ms sustained for 15m; burn rate back under 1x.

**Tournament join (`TournamentJoinSLOBurn`)**
1. First checks: tournaments service health, DB write latency, Redis Pub/Sub lag, Stellar RPC reachability.
2. Safe mitigations: shed non-critical load, disable optional join validations, scale service.
3. Escalation: Tournaments team → Payments team if Stellar RPC is the cause.
4. Recovery verification: success ratio > 99% and p95 < 1.5s for 15m.

**Match updates (`MatchUpdateLatency`)**
1. First checks: matches service health, Redis Pub/Sub consumer lag, DB query latency.
2. Safe mitigations: scale consumers, increase Redis capacity, throttle non-critical broadcasts.
3. Escalation: Matches team → platform on-call for infra.
4. Recovery verification: p95 < 500ms sustained for 15m.

**Settlement (`SettlementFailure` / `SettlementLatency`)**
1. First checks: payment gateway status (Paystack/Flutterwave), Stellar network status, settlement worker queue depth, DB transaction errors.
2. Safe mitigations: pause new settlement jobs, retry idempotently, fail over to backup gateway, hold payouts pending manual review.
3. Escalation: Payments team → finance on-call → incident commander for fund-impacting outages.
4. Recovery verification: settlement success ratio > 99.9% and p95 < 5s for 30m; reconcile any held payouts.

### Staging Validation

To validate alerts and runbooks, simulate one dependency outage in staging:

1. Block egress to the Stellar RPC (or stop the payment gateway mock) in staging.
2. Confirm `SettlementFailure` fires within the 5m window and does **not** fire on a brief 30s blip.
3. Walk the Settlement runbook end-to-end: verify first checks identify the dependency, mitigations hold payouts safely, and recovery verification passes after restoring the dependency.
4. Record findings and update thresholds/runbooks as needed.

---

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

### Prerequisites
- Rust toolchain (`cargo`, `rustup`)
- Node.js (v18+)
- PostgreSQL (with sharding support)
- Redis (with Pub/Sub enabled)
- MinIO (or AWS S3)
- Docker (for local containers)
- **Stellar CLI and SDK**: For blockchain integration and testing on Stellar testnet/mainnet
- Optional: Kafka for event streaming

### Backend Setup
1. Clone the backend repository.
2. Install Rust dependencies, including Stellar Rust SDK.
3. Run database migrations for PostgreSQL.
4. Configure Redis, MinIO, Paystack/Flutterwave, and Stellar network credentials (testnet/mainnet).
5. Deploy Soroban smart contracts for prize distribution and reputation tracking.
6. Start the backend server with microservices for auth, tournaments, matches, anti-cheat, and Stellar integration.

### Backend Setup (Code)
```bash
# Clone repo
git clone https://github.com/arenax.git
cd backend

# Install dependencies
cargo build

# Run migrations
sqlx migrate run

# Start server
cargo run
```

### Frontend Setup
1. Clone the frontend repository.
2. Install Node.js dependencies.
3. Configure frontend to display Stellar wallet addresses and transaction statuses.
4. Start the development server for the Next.js PWA.

### Frontend Setup (Code)
```bash
git clone https://github.com/arenax/arenax.git
cd frontend

# Install dependencies
npm install

# Run dev server
npm run dev
```

### Environment Variables
Create `.env` files with additional variables for Stellar integration:
- Database connection URL
- Redis connection URL
- S3/MinIO endpoint, access key, and secret key
- Paystack/Flutterwave API secrets
- JWT secret for authentication
- **Stellar network URL** (testnet/mainnet)
- **Stellar secret key** for admin account
- **Soroban contract IDs** for prize distribution and reputation
- AI model path for anti-cheat analysis

### Environment Variables (Code)
```env
DATABASE_URL=postgres://user:pass@localhost:5432/arenax
REDIS_URL=redis://localhost:6379
S3_ENDPOINT=http://localhost:9000
S3_ACCESS_KEY=minio
# Secrets must be >= 32 chars and must not be a known placeholder — the
# backend refuses to start otherwise.
S3_SECRET_KEY=dev-only-s3-secret-replace-me-0123456789
PAYSTACK_SECRET=dev-only-paystack-secret-replace-me-0123456789
JW

/* … truncated 10589 chars — edit only what you need near the top … */
