# Backend

This directory contains the backend services for the tournament platform.

## Testing

### End-to-end tournament lifecycle integration suite

Issue #112 adds deterministic end-to-end coverage of the full tournament
lifecycle. The suite seeds a fixed participant set and exercises create, join,
bracket generation, match play, result reporting, the dispute/cancel
alternative, and tournament closure. It then asserts that the final bracket,
leaderboard, wallet ledger, and notifications all reconcile to a single
authoritative result.

Key properties of the suite:

- **Deterministic:** participants, seeds, and match outcomes are fixed, so the
  suite produces the same authoritative result on every run.
- **Failure/recovery coverage:** at least one failure/recovery path (dispute or
  cancel alternative) is exercised within the lifecycle.
- **No persistent test data:** the suite performs full teardown/cleanup so no
  test data is left behind after it runs.
- **CI-friendly:** it runs with fake providers and has no live blockchain
  dependency, so it can execute in CI.

### Running the suite

The lifecycle suite is tagged as an integration suite and is intended to run on
every relevant pull request:

```sh
go test -tags=integration ./... -run TestTournamentLifecycle
```

Because the suite uses fake providers, no external services or live blockchain
nodes are required.
