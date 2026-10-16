# Project

## Cross-service contract tests (Rust & TypeScript)

The versioned API contract is the source of truth for cross-service behavior.
Contract tests run the same shared fixtures against every supported server
implementation (Rust and TypeScript) and assert compatible status codes and
response schemas, or explicitly document intentional differences.

### Layout

- `contracts/` — versioned API contract (routes, auth, serialization, errors).
- `contracts/fixtures/valid/` — shared valid request/response fixtures.
- `contracts/fixtures/invalid/` — shared invalid request/response fixtures.
- `contracts/expected-differences.md` — documented, reviewed intentional
differences between implementations.

### Running the contract tests

Run the contract suite against each supported service in CI:

```sh
# Rust implementation
cargo test --test contract

# TypeScript implementation
npm run test:contract
```

Both suites consume the same fixtures from `contracts/fixtures/` and validate
responses against the versioned contract schemas.

### Compatibility rules

- Shared valid fixtures must produce compatible status codes and response
  schemas across all supported implementations.
- Shared invalid fixtures must produce compatible error status codes and error
  schemas across all supported implementations.
- Any intentional difference must be recorded in
  `contracts/expected-differences.md` with a rationale and reviewer sign-off.
- Contract tests fail on unreviewed breaking field or enum changes: adding,
  removing, renaming, or retyping a field or enum variant without updating the
  versioned contract and fixtures is a test failure.

### Supported matrix

Which implementations remain in the contract matrix is determined by backend
ownership decisions. When an implementation is retired, remove it from the
matrix and update `contracts/expected-differences.md` accordingly.
