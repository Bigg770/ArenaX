# ArenaX Idempotency Framework

A comprehensive idempotency framework for ArenaX write APIs that prevents duplicate operations and ensures safe request retries.

## 🎯 Overview

The idempotency framework provides a standardized way to handle duplicate requests safely, preventing financial operations from being executed multiple times due to network retries, client bugs, or gateway issues.

## 🏗️ Architecture

### Core Components

1. **IdempotencyMiddleware** - Actix-web middleware that intercepts requests and handles idempotency logic
2. **IdempotencyService** - Service layer for idempotency key management and operations
3. **Database Models** - PostgreSQL schema for storing keys and cached responses
4. **Configuration System** - Per-route configuration for TTL, response size limits, etc.

### Key Features

- **SHA256 Request Hashing** - Ensures request integrity by hashing method, path, headers, and body
- **Response Caching** - Stores complete response (status, headers, body) for replay
- **Conflict Detection** - Rejects key reuse with different payloads deterministically
- **TTL Management** - Automatic cleanup of expired keys
- **Route-based Configuration** - Different settings per API endpoint
- **Performance Optimized** - Database indexes and efficient queries

## 🚀 Quick Start

### 1. Database Setup

```bash
# Run the idempotency migration
psql -d arenax -f idempotency_migration.sql
```

### 2. Basic Usage

```bash
# Generate an idempotency key
curl -X POST http://localhost:8080/api/idempotency/generate-key \
  -H "Content-Type: application/json" \
  -d '{"ttl_seconds": 3600}'

# Use the key in a request
curl -X POST http://localhost:8080/api/test/payment \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: idemp_abc123def456" \
  -d '{"amount": 100, "currency": "USD"}'

# Replay the same request (gets cached response)
curl -X POST http://localhost:8080/api/test/payment \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: idemp_abc123def456" \
  -d '{"amount": 100, "currency": "USD"}'
```

### 3. Conflict Detection

```bash
# Try to reuse the key with different payload (gets 409 Conflict)
curl -X POST http://localhost:8080/api/test/payment \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: idemp_abc123def456" \
  -d '{"amount": 200, "currency": "USD"}'
```

## 📋 API Reference

### Middleware Integration

The middleware automatically processes requests for configured routes:

```rust
// In main.rs
.wrap(IdempotencyMiddleware::default(db_pool.clone()))
```

### Required Headers

- **Idempotency-Key** - Unique key for the request (8-255 chars, alphanumeric + hyphens/underscores)

### Response Headers

- **X-Idempotency-Cached** - "true" if response is from cache
- **X-Idempotency-Timestamp** - When the original response was cached

### Management Endpoints

#### Generate Key
```http
POST /api/idempotency/generate-key?ttl_seconds=3600
```

#### Get Statistics
```http
GET /api/idempotency/stats
Authorization: Bearer <admin_token>
```

#### Get User Keys
```http
GET /api/idempotency/user-keys?limit=50&offset=0
Authorization: Bearer <user_token>
```

#### Invalidate Key
```http
DELETE /api/idempotency/invalidate/{key}
Authorization: Bearer <admin_token>
```

#### Cleanup Expired
```http
POST /api/idempotency/cleanup
Authorization: Bearer <admin_token>
```

## ⚙️ Configuration

### Default Policy

```rust
pub struct IdempotencyPolicy {
    pub enabled_routes: Vec<String>,
    pub default_ttl_seconds: i32,        // 86400 (24 hours)
    pub max_response_size_kb: i32,       // 1024 (1MB)
    pub key_header_name: String,         // "Idempotency-Key"
    pub conflict_status_code: i16,       // 409
}
```

### Per-Route Configuration

```sql
INSERT INTO idempotency_configs (
    route_pattern, enabled, ttl_seconds, max_response_size_kb
) VALUES 
('/api/payments/create', true, 86400, 1024),
('/api/matchmaking/join', true, 3600, 256);
```

### Environment Variables

```bash
# Optional: Override default TTL
IDEMPOTENCY_DEFAULT_TTL_SECONDS=86400

# Optional: Override max response size
IDEMPOTENCY_MAX_RESPONSE_SIZE_KB=1024
```

## 🔧 Implementation Details

### Request Hashing

The framework creates a SHA256 hash of:

1. HTTP Method (GET, POST, etc.)
2. Request Path
3. Query Parameters
4. All headers except Idempotency-Key
5. Request Body

This ensures that any change to the request results in a different hash.

### Conflict Detection

When a key is reused:

1. **Same Hash** → Returns cached response
2. **Different Hash** → Returns 409 Conflict with details

### Response Caching

Complete responses are cached including:

- HTTP Status Code
- Response Headers
- Response Body (JSON, up to size limit)
- Timestamp

### TTL Strategy

- **Financial Operations**: 24 hours
- **Matchmaking**: 1 hour
- **Tournament Operations**: 24 hours
- **Custom**: Per-route configuration

## 📊 Performance

### Benchmarks

- **Key Generation**: ~1000 ops/sec
- **Cache Lookup**: ~5000 ops/sec
- **Conflict Detection**: ~3000 ops/sec
- **Storage**: ~800 ops/sec

### Database Optimization

- Indexed on key, expires_at, created_at
- Composite indexes for common queries
- Partitioned views for analytics
- Automatic cleanup of expired keys

### Memory Usage

- **Cached Response**: ~1KB average
- **Key Metadata**: ~500 bytes
- **Total Overhead**: <2MB per 1000 active keys

## 🧪 Testing

### Unit Tests

```bash
# Run idempotency tests
cargo test idempotency

# Run specific test categories
cargo test idempotency::middleware
cargo test idempotency::service
cargo test idempotency::models
```

### Integration Tests

```bash
# Run API integration tests
cargo test idempotency_integration

# Test with real database
TEST_DATABASE_URL=postgresql://test:test@localhost/arenax_test \
cargo test idempotency_integration
```

### Sandboxed Deposit & Payout End-to-End Tests

The end-to-end suite exercises the full deposit/payout lifecycle against a fake
provider so that provider callbacks and ledger settlement are verified together
rather than in isolation. It runs in CI with no real credentials and no network
dependency.

#### Fake provider orchestration

A `SandboxProvider` stands in for the real payment provider and drives every
stage of the lifecycle:

- **Initiation** - returns a deterministic provider reference for a deposit or
  withdrawal request.
- **Webhook** - emits signed callbacks (success, failure, replay, tampered
  signature, mismatched amount) that are fed through the real webhook handler.
- **Reconciliation** - exposes a queryable provider state so the reconciler can
  settle pending transactions.
- **Withdrawal** - simulates payout submission and terminal outcomes.
- **Ambiguous outcome recovery** - can return a timeout/unknown result so the
  recovery path is exercised before any retry.

```bash
# Run the sandboxed end-to-end suite
cargo test sandbox_e2e

# Run a single scenario
cargo test sandbox_e2e::deposit_success_credits_ledger_once
```

#### Scenarios and assertions

| Scenario | Assertion |
| --- | --- |
| Successful deposit | Exactly one ledger credit is created for the payment. |
| Replayed callback | No additional ledger entry; response is idempotent. |
| Invalid signature callback | Rejected; no financial side effect. |
| Mismatched amount callback | Rejected; no financial side effect. |
| Payout timeout | Reconciled before retry; transaction reaches a user-visible terminal state. |

Each scenario asserts on the ledger (entry count and balance) as well as the
provider-facing status, so a passing test proves the callback and the ledger
agree.

#### CI execution

The suite is wired into CI and requires no secrets:

```bash
# No provider credentials or network access required
cargo test sandbox_e2e -- --nocapture
```

### Performance Tests

```bash
# Run performance benchmarks
cargo test --release idempotency_performance

# Load testing
curl -X GET http://localhost:8080/api/test/performance?count=1000
```

### Stress & Race Boundary Tests

Idempotency and transaction race boundaries are exercised across every write surface that
mutates durable state. Each scenario runs repeatedly against PostgreSQL and Redis to prove
that duplicate requests and worker contention cannot produce double side effects.

#### Covered surfaces

| Surface | Duplicate-request invariant | Race invariant |
| --- | --- | --- |
| Wallet mutations | Exactly one ledger entry per key | Final balance equals sum of committed entries |
| Provider events | Exactly one provider event row per key | No duplicate settlement for one provider event |
| Match finalization | Exactly one finalized match per key | Final match state is terminal and consistent |
| Tournament transitions | Exactly one transition per key | Tournament state advances monotonically |
| Settlement workers | Exactly one settlement per key | Ledger totals match settled amounts |

#### Assertions

- **Single durable side effect** - After N identical requests sharing one idempotency key, the
  ledger/match tables contain exactly one row for that operation. Assertions query the database
  (ledger entries, balances, match status, tournament state), not just the HTTP status code.
- **Conflicting payloads rejected** - Reusing an idempotency key with a different payload returns
  `409 Conflict` and leaves the original durable side effect untouched.
- **Race invariants** - Concurrent workers/requests are launched in parallel; after they settle,
  the final ledger and match invariants are asserted (no lost updates, no double spends, no
  partially applied transitions).

#### Running the stress scenarios

```bash
# Parallel integration scenarios against PostgreSQL + Redis
TEST_DATABASE_URL=postgresql://test:test@localhost/arenax_test \
TEST_REDIS_URL=redis://localhost:6379 \
cargo test --release idempotency_race -- --test-threads=1

# Repeat each scenario to surface flakiness
for i in $(seq 1 20); do
  TEST_DATABASE_URL=postgresql://test:test@localhost/arenax_test \
  TEST_REDIS_URL=redis://localhost:6379 \
  cargo test --release idempotency_race || exit 1
done
```

## 🔍 Monitoring & Debugging

### Health Checks

```bash
# Check idempotency system health
curl http://localhost:8080/api/test/health
```

### Statistics

```bash
# Get usage statistics
curl http://localhost:8080/api/idempotency/stats
```

### Analytics Views

The database provides several views for monitoring:

- `active_idempotency_keys` - Current active keys
- `idempotency_usage_stats` - Hourly usage metrics
- `idempotency_conflicts` - Conflict detection
- `route_idempotency_stats` - Per-route statistics

### Logging

```rust
// Enable debug logging
RUST_LOG=debug cargo run

// Log levels
INFO: idempotency::middleware - Request processed
WARN: idempotency::middleware - Conflict detected
ERROR: idempotency::service - Database error
```

## 🛡️ Security Considerations

### Key Generation

- Keys are cryptographically random (UUID-based)
- No sequential patterns
- Sufficient entropy to prevent guessing

### Data Privacy

- Request bodies are hashed, not stored in plaintext
- Personal data in cached responses follows existing privacy policies
- Automatic expiration prevents data accumulation

### Rate Limiting

- Consider implementing rate limiting on key generation
- Monitor for abuse patterns
- Implement per-user key limits if needed

## 🔮 Future Enhancements

### Planned Features

1. **Distributed Caching** - Redis support for multi-instance deployments
2. **Machine Learning** - Predictive conflict detection
3. **Advanced Analytics** - Real-time dashboards
4. **Client SDKs** - Helper libraries for common languages
5. **Batch Operations** - Bulk key management

### Performance Improvements

1. **Memory Caching** - L1 cache for frequently accessed keys
2. **Connection Pooling** - Optimized database connections
3. **Async Processing** - Background key cleanup
4. **Compression** - Response body compression

## 📚 Examples

### Payment Processing

```rust
#[post("/payments/create")]
pub async fn create_payment(
    db_pool: web::Data<DbPool>,
    body: web::Json<CreatePaymentRequest>,
) -> Result<HttpResponse, Error> {
    // Idempotency handled by middleware
    // Business logic here
}
```

## 🔐 Least-Privilege API Threat Model

This section makes trust boundaries and abuse cases explicit for ArenaX's gaming, financial, and blockchain flows. It is a living document: **update it whenever an API or custody boundary changes** (new endpoint, new signer, new payment rail, new upload sink).

### Assets

| Asset | Sensitivity | Where it lives |
|-------|-------------|----------------|
| User credentials / sessions | High | Auth service, session store |
| Player identity & PII | High | `users` tables, profile APIs |
| Match results & rankings | Medium | Match reporting APIs, DB |
| Dispute records & evidence | High | Dispute APIs, object storage |
| Payment intents & ledger entries | Critical | Payments service, ledger DB |
| Custody keys / signer material | Critical | KMS / HSM, never in app DB |
| On-chain contract admin authority | Critical | Multisig / timelock, admin keys |
| Uploaded files (evidence, avatars) | Medium | Object storage, CDN |
| Idempotency keys & cached responses | Medium | `idempotency_keys` table |

### Actors

- **Anonymous client** – unauthenticated caller.
- **Authenticated player** – holds a session/token, owns their own resources.
- **Match reporter / oracle** – submits match results (player or trusted service).
- **Dispute participant** – player filing or responding to a dispute.
- **Support / moderator** – elevated read + limited write on disputes.
- **Finance operator** – initiates refunds/payouts, no direct key access.
- **Contract admin** – holds multisig/timelock authority over on-chain contracts.
- **Internal service** – service-to-service caller with scoped credentials.
- **Attacker** – external or compromised low-privilege account.

### Entry Points & Trust Transitions

| Flow | Entry point | Trust transition |
|------|-------------|------------------|
| Auth | `POST /auth/login`, `/auth/refresh` | anonymous → authenticated session |
| Match reporting | `POST /matches/{id}/report` | player/oracle → authoritative match result |
| Disputes | `POST /disputes`, `POST /disputes/{id}/evidence` | participant → adjudicated outcome |
| Payments | `POST /payments/create`, webhooks | client intent → ledger debit/credit |
| Uploads | `POST /uploads` (presigned) | untrusted bytes → served content |
| Contract admin | admin tx submission | operator intent → on-chain state change |

### Mitigations Mapped to Code & Tests

| Threat | Mitigation | Code | Tests |
|--------|-----------|------|-------|
| Credential stuffing / brute force | Rate limit + lockout on login | auth handlers | `auth` integration tests |
| Session forgery / replay | Signed tokens, short TTL, refresh rotation | auth middleware | `auth` token tests |
| Forged match reports | Authorize reporter role; server-side validation of result payload | match reporting handler | `matches` tests |
| Duplicate match submission | Idempotency-Key required on report | `IdempotencyMiddleware` | `idempotency_integration` |
| Dispute evidence tampering | Immutable evidence records + hash on upload | dispute handler, upload service | `disputes` tests |
| Unauthorized dispute access | Object-level authz (owner/moderator only) | dispute handler | `disputes` authz tests |
| Payment double-spend / replay | Idempotency + ledger uniqueness constraint | payments handler, ledger schema | `idempotency_integration`, ledger tests |
| Webhook spoofing | Signature verification + timestamp window | webhook handler | webhook signature tests |
| Malicious uploads (XSS, malware) | Content-type allowlist, size cap, served from isolated origin | upload service | upload validation tests |
| Path traversal on upload keys | Server-generated object keys only | upload service | upload key tests |
| Contract admin key compromise | Multisig + timelock; no single-key admin | on-chain contracts | contract admin tests |
| Privilege escalation via admin APIs | Role checks on every admin route | admin middleware | admin authz tests |
| Key/secret leakage | Secrets from env/KMS only; rotation runbook | config, `.env.example` | CI secret scan |

### Accepted Residual Risks

- **Idempotency cache stores response bodies** for up to TTL (24h). Accepted: bodies are hashed for integrity and expire automatically; no plaintext request bodies stored.
- **Match reporting trusts the reporter's role** once authorized; collusion between reporter and player is out of scope for API-layer controls and handled by dispute process.
- **Uploads are scanned best-effort**; zero-day malware in evidence files is an accepted risk mitigated by isolated serving origin.
- **Contract admin relies on external multisig**; API cannot enforce signer policy beyond submitting transactions.

### High-Risk Findings & Owners

| Finding | Risk | Owner / Decision |
|---------|------|------------------|
| Webhook signature verification coverage | High | Payments owner — tracked, must be enforced before mainnet |
| Admin route authz completeness | High | Platform security owner — audit each admin route |
| Upload malware scanning depth | Medium | Infra owner — accepted with isolated origin |

Each high-risk finding must have a linked issue or an explicit owner/decision recorded above before sign-off.

### Maintenance & Review

- Update this model in the same PR whenever an API endpoint, auth boundary, payment rail, upload sink, or custody/signer path changes.
- Security review signs off against the misuse-case checklist below.

### Misuse-Case Checklist (Security Review Sign-off)

- [ ] Every new endpoint has an actor + trust transition documented.
- [ ] Object-level authorization verified for player-owned resources.
- [ ] Idempotency enforced on all financial and match-reporting writes.
- [ ] Webhook signatures verified with replay window.
- [ ] Uploads: allowlist, size cap, server-generated keys, isolated origin.
- [ ] Admin/contract-admin actions require multisig/timelock or role check.
- [ ] Residual risks reviewed and accepted explicitly.
- [ ] High-risk findings have linked issues or named owners.
