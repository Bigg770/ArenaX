# WebSocket Fanout & Reconnect Load Testing

This document defines the reproducible load profile used to verify that realtime
match updates stay bounded during tournament peaks and mass reconnections, and
records the measured capacity envelope for the realtime service.

## Goals

- Verify real-time match updates remain bounded during tournament peaks and mass reconnections.
- Confirm slow consumers cannot grow unbounded per-connection buffers.
- Confirm reconnect synchronization converges without duplicate state mutations.

## Harness Overview

The load harness drives the realtime service as an authenticated client would:

1. **Authenticated connect** — each simulated client obtains a session token and
   opens a WebSocket connection with that credential, so fanout authorization and
   per-connection accounting are exercised exactly as in production.
2. **Room fanout** — clients join tournament rooms and the harness publishes match
   updates at a configurable rate, measuring fanout to every subscriber.
3. **Slow consumers** — a configurable subset of clients deliberately stop reading
   (or read at a throttled rate) to force backpressure on their per-connection
   send buffers.
4. **Disconnect/reconnect storm** — a large fraction of clients drop and reconnect
   simultaneously, then resynchronize room state.
5. **Server restart** — the realtime service is restarted mid-run to verify clients
   reconnect and converge on the authoritative room state.

## Load Profile

| Parameter | Value |
| --- | --- |
| Authenticated clients | 10,000 |
| Tournament rooms | 200 |
| Clients per room | 50 |
| Match update rate | 20 updates/s per room |
| Slow consumers | 5% of clients (throttled reads) |
| Reconnect storm | 50% of clients disconnect/reconnect within 5s |
| Server restart | 1 restart at T+120s |
| Run duration | 300s |

Run the profile against a staging deployment sized like production. Repeat each
scenario at least three times and report the median.

## Measurements

Collect the following for every run:

- **Memory** — process RSS and heap for the realtime service, sampled every second.
- **Queue depth** — per-connection outbound queue depth, reported as max and p99.
- **Delivery latency** — publish-to-receive latency, reported as p50/p95/p99.
- **Dropped clients** — count of connections closed by the server due to
  backpressure or policy, with the reason.

## Acceptance Criteria

- Memory, queue depth, delivery latency, and dropped-client behavior are measured
  and reported for each scenario.
- Slow consumers cannot grow unbounded per-connection buffers: per-connection
  queue depth stays under the configured cap and excess clients are dropped
  rather than buffered indefinitely.
- Reconnect synchronization converges without duplicate state mutations: after a
  reconnect storm or server restart, each client's room state matches the
  authoritative state and no update is applied twice.

## Capacity Envelope

Document the measured envelope alongside the results:

| Metric | Envelope |
| --- | --- |
| Concurrent authenticated clients | TBD (measured) |
| Sustained fanout updates/s | TBD (measured) |
| Per-connection queue depth cap | TBD (configured) |
| p99 delivery latency | TBD (measured) |
| Server RSS at peak | TBD (measured) |

Fill in the TBD values from the staging runs and compare each run against this
envelope. A run that exceeds the envelope is a regression and must be
investigated before release.

## Reproducibility

- Pin the harness version and the realtime service commit under test.
- Record the deployment size, region, and instance type.
- Store raw metrics with the run so results can be re-derived.
