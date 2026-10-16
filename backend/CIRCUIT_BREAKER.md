# External Service Circuit Breaker (Issue #944)

## Overview
The External Service Circuit Breaker protects the ArenaX backend from cascading failures caused by outages, network timeouts, or degraded performance in third-party services (e.g. Stellar Horizon, Soroban RPC, external payment providers, webhooks).

## States & State Transitions

```mermaid
stateDiagram-v2
    [*] --> Closed
    Closed --> Open: Failures >= threshold
    Open --> HalfOpen: Cooldown period elapsed
    HalfOpen --> Closed: Consecutive successes >= success_threshold
    HalfOpen --> Open: Trial request fails (exponential backoff scaled)
```

1. **Closed**: Normal state. All requests are allowed through. Consecutive failures are tracked. When failures reach `failure_threshold` (default: 5), the circuit trips to `Open`.
2. **Open**: Outage state. Incoming calls fail fast immediately with `503 Service Unavailable` and a `Retry-After` header without making any network calls to the external service.
3. **HalfOpen**: Recovery state. Once the exponential backoff cooldown has elapsed, the circuit admits a limited number of trial probe requests (`half_open_probe_limit`, default: 1).
   - If the trial request succeeds and reaches `success_threshold` (default: 2), the circuit transitions back to `Closed` and resets the backoff exponent.
   - If the trial request fails, the circuit immediately returns to `Open` and scales the cooldown duration exponentially.

## Exponential Backoff Calculation

The cooldown period before transitioning from `Open` to `HalfOpen` grows exponentially with consecutive trip cycles:

$$\text{cooldown} = \min\left(\text{max\_backoff}, \; \text{initial\_backoff} \times \text{backoff\_multiplier}^{(\text{trip\_count} - 1)}\right)$$

### Default Settings
- `failure_threshold`: 5 consecutive failures
- `success_threshold`: 2 consecutive successes
- `initial_backoff`: 5 seconds
- `max_backoff`: 60 seconds
- `backoff_multiplier`: 2.0
- `half_open_probe_limit`: 1 concurrent probe
- `request_timeout`: 10 seconds

## Usage

### 1. Service Registry Wrapper
```rust
use arenax_backend::middleware::circuit_breaker::CircuitBreakerRegistry;

let registry = CircuitBreakerRegistry::default();

// Execute outbound calls under the "stellar" circuit breaker
let result = registry.call("stellar", || async {
    // Outbound HTTP request to Stellar Horizon
    reqwest::get("https://horizon.stellar.org/accounts/XYZ").await
}).await;

match result {
    Ok(data) => println!("Success: {:?}", data),
    Err(CircuitBreakerError::CircuitOpen { service, retry_after_secs }) => {
        eprintln!("Fast failed: {} circuit is open, retry in {}s", service, retry_after_secs);
    }
    Err(CircuitBreakerError::Timeout(dur)) => {
        eprintln!("Call timed out after {:?}", dur);
    }
    Err(CircuitBreakerError::Inner(e)) => {
        eprintln!("External call failed: {:?}", e);
    }
}
```

### 2. Actix-Web Route Middleware
```rust
use actix_web::{web, App};
use arenax_backend::middleware::circuit_breaker::{
    CircuitBreaker, CircuitBreakerConfig, ExternalCircuitBreakerMiddleware,
};

let breaker = Arc::new(CircuitBreaker::new(
    CircuitBreakerConfig::new("proxy_service")
        .with_failure_threshold(3)
        .with_initial_backoff(Duration::from_secs(10)),
));

App::new()
    .service(
        web::scope("/api/external")
            .wrap(ExternalCircuitBreakerMiddleware::new(breaker.clone()))
            .route("/proxy", web::get().to(proxy_handler))
    );
```

## Metrics Export
The circuit breaker publishes Prometheus metrics via the `/metrics` endpoint:

| Metric Name | Type | Labels | Description |
|-------------|------|--------|-------------|
| `circuit_breaker_state` | Gauge | `service` | Current state (0 = Closed, 1 = HalfOpen, 2 = Open) |
| `circuit_breaker_requests_total` | Counter | `service`, `status` | Total requests (`success`, `failure`, `rejected`) |
| `circuit_breaker_trips_total` | Counter | `service` | Total times circuit tripped Open |

## Dependency-Failure Chaos Tests (Issue #119)

This section documents the bounded chaos scenarios that verify the backend fails safely when a dependency degrades. The scenarios are exercised in integration/staging tests and are driven by the circuit breaker plus the fault-injection hooks below.

### Fault Injection Controls

Each dependency is wrapped so tests can inject controlled faults without touching production code paths:

| Dependency | Fault Modes | Injection Mechanism |
|------------|-------------|---------------------|
| PostgreSQL | connection timeout, connection reset, slow query | pool `acquire_timeout` + test proxy that delays/drops connections |
| Redis | timeout, restart, malformed RESP reply | `redis` client `connection_timeout` + fault proxy |
| Object storage | throttling (`429`), truncated body, timeout | S3-compatible client retry/timeout config + fault proxy |
| Payment APIs | `5xx`, `429` throttling, malformed JSON, timeout | `reqwest` client timeout + mock server returning crafted responses |
| Stellar RPC | timeout, `503`, malformed JSON-RPC envelope | `reqwest` client timeout + mock Horizon/Soroban endpoint |

All injected faults are bounded: each scenario runs for a fixed duration (default 30s) and then the fault is removed so recovery can be observed.

### Scenario Matrix

| # | Scenario | Injected Fault | Expected Safe Behavior |
|---|----------|----------------|------------------------|
| 1 | PostgreSQL outage | drop connections for 30s | requests fail with `503`; no partial match state committed; pool recovers |
| 2 | Redis restart | kill + restart Redis | sessions/cache degrade gracefully; no duplicate payout enqueued |
| 3 | Object storage throttling | return `429` for uploads | uploads retried with backoff; no orphaned records |
| 4 | Payment API malformed response | return invalid JSON | payout marked `pending`, not `paid`; reconciliation retries |
| 5 | Payment API timeout | delay beyond `request_timeout` | circuit opens; no duplicate payout created |
| 6 | Stellar RPC `503` | return `503` | circuit opens; match settlement deferred, not lost |
| 7 | Stellar RPC malformed JSON-RPC | return bad envelope | treated as failure; no state mutation |

### Acceptance Checks

- **No duplicate payouts**: each scenario asserts the payout ledger contains exactly one entry per intended payout, even when the payment API is retried or the circuit reopens.
- **No lost committed match state**: after each fault is removed, the match state read back from PostgreSQL equals the last committed state; uncommitted writes are rolled back.
- **Health/readiness distinguishes degradation**: `/health` returns `200` while dependencies are degraded but the process is alive; `/ready` returns `503` with a body naming the degraded dependency. User-facing errors use `503` + `Retry-After` for recoverable degradation and `500` for unrecoverable faults.
- **Recovery drains pending work**: once the fault is removed, the circuit transitions `Open -> HalfOpen -> Closed`, the pending-work reconciler drains queued payouts/settlements, and `/ready` returns `200`.

### Running a Bounded Scenario

```bash
# Example: payment API timeout scenario, 30s bounded run
CHAOS_SCENARIO=payment_timeout CHAOS_DURATION=30s \
  cargo test --test chaos_dependency_failures -- --nocapture
```

Record expected versus observed behavior for each scenario in the staging run log, including the circuit breaker state transitions and the reconciliation drain count.
