# Contributing to ArenaX

Thanks for helping improve ArenaX. This guide covers onboarding, subsystem ownership, required validation, and the definition of done for issues and pull requests.

## Getting started

1. Fork the repository and create a branch from `main`.
2. Run `make setup` to install dependencies and create local env files.
3. Make your change, run the relevant checks below, and open a pull request.

## Subsystem owners and workflows

ArenaX is split into four subsystems. Each has its own toolchain, owners, and validation commands.

| Subsystem | Location | Owners | Toolchain |
| --- | --- | --- | --- |
| Rust backend | `backend/` | @backend-owners | Rust / Cargo |
| TypeScript server | `server/` | @server-owners | Node / TypeScript |
| Frontend | `frontend/` | @frontend-owners | Next.js / Yarn |
| Soroban contracts | `contracts/` | @contracts-owners | Rust / Soroban |

### Rust backend (`backend/`)

- Build: `make build-backend` (`cargo build --release`)
- Test: `make test-backend` (`cargo test`)
- Lint/format: `make lint` and `make format` (`cargo clippy`, `cargo fmt`)

### TypeScript server (`server/`)

- Install: `yarn install` in `server/`
- Build: `yarn build`
- Test: `yarn test`
- Lint/format: `yarn lint` and `yarn format`

### Frontend (`frontend/`)

- Install: `make install-frontend` (`yarn install`)
- Dev server: `make dev-frontend` (`yarn dev`)
- Build: `make build-frontend` (`yarn build`)
- Test: `make test-frontend` (`yarn test`)
- Lint/format: `make lint` and `make format` (`yarn lint`, `yarn format`)

### Soroban contracts (`contracts/`)

- Build: `make build-contracts` (adds `wasm32-unknown-unknown` and builds the release WASM)
- Test: `make test-contracts` (`cargo test`)
- Lint/format: `make lint` and `make format` (`cargo clippy`, `cargo fmt`)

Run `make check-all` before opening a PR to run lint, format, and tests across subsystems.

## Migration and contract review requirements

- **Database migrations:** every migration must be reversible, include an up and down path, and be reviewed by a backend owner. Document the migration in the PR description and note any data backfill.
- **Soroban contract changes:** any change to `contracts/` requires review from a contracts owner. Include the updated interface, storage layout, and a migration/upgrade note. Contract changes must ship with tests covering the new behavior.
- **API contract changes:** changes to request/response shapes require review from the owning subsystem and an update to the generated API docs.

## Security-sensitive and financial changes

Changes touching authentication, authorization, key handling, payments, balances, or on-chain value transfer are security-sensitive.

- Required reviewers: at least one security reviewer and one owner of the affected subsystem.
- Validation evidence: include tests demonstrating the change, a description of the threat or failure mode addressed, and any manual verification steps.
- Never commit secrets, private keys, or credentials. Use the provided `env.example` files for local configuration.

## Branch and status-check policy

- Branch from `main` and keep branches focused on a single issue.
- All required CI status checks must pass before merge. Do not merge with failing or skipped required checks.
- Keep the branch up to date with `main`; resolve conflicts locally before requesting review.
- Squash-merge unless the change is intentionally split into reviewable commits.

## Definition of done

An issue is done when:

- The change is implemented and scoped to the issue.
- Relevant tests are added or updated and pass locally.
- `make check-all` passes for the affected subsystems.
- Documentation is updated when behavior, commands, or interfaces change.
- Security-sensitive and financial changes have the required reviewers and validation evidence.

A pull request is ready to merge when:

- It references the issue it resolves.
- All required status checks pass.
- It has approval from the owning subsystem and, where applicable, a security reviewer.
- The description explains what changed, why, and how it was validated.
