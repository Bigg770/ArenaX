# Contributing to ArenaX

## Branches

| Pattern | Purpose |
|---|---|
| `main` | Production-ready code |
| `dev` | Integration branch |
| `feat/<name>` | New features |
| `fix/<name>` | Bug fixes |
| `chore/<name>` | Tooling, deps, config |
| `contract/<name>` | Smart contract changes |
| `migration/<name>` | DB schema changes |

All PRs target `dev`. Only `dev` → `main` merges go to production.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(contracts): add match escrow vault dispute resolution
fix(backend): correct varchar/integer comparison in tournament view
chore(deps): bump next to 14.2.25
migration: add governance tables
```

Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `migration`, `contract`

## Development setup

### Backend (Rust)
```bash
cd backend
cp env.example .env          # fill in DATABASE_URL, JWT_SECRET, etc.
cargo sqlx migrate run
cargo build
cargo test
```

### Contracts (Soroban)
```bash
cd contracts
rustup target add wasm32-unknown-unknown
cargo test
cargo build --target wasm32-unknown-unknown --release
```

### Server (TypeScript)
```bash
cd server
npm ci
npm run prisma:generate
npm run build
```

### Frontend (Next.js)
```bash
cd frontend
npm ci
npm run build
```

## Pull requests

- Keep PRs focused — one concern per PR.
- All CI checks must pass before merge
- Smart contract changes require two approvals
- DB migrations must include a `.down.sql`
- Never force-push to `main` or `dev`

## Smart contract guidelines

- All public functions must have tests in `test.rs`
- Use `#[contracttype]` for all storage keys
- Bump the contract version constant on any interface change
- Document breaking changes in the PR description

## Database migrations

- Migrations are append-only — never edit an existing migration file
- Test both `up` and `down` migrations locally before opening a PR
- Column/type changes require a multi-step migration (add → backfill → drop)

## Data classification and retention

All persisted data must be classified before it is stored. The inventory below
is the source of truth for purpose, sensitivity, ownership, retention, and
deletion behavior across every storage system.

### Data inventory

| Data class | Purpose | Sensitivity | Owner | Retention | Deletion / hold rules | Systems of record |
|---|---|---|---|---|---|---|
| Account (profile, email, auth identifiers, KYC refs) | Identity, login, eligibility | Confidential / PII | Identity team | Active account + 30 days after closure | Hard-deleted on account closure after 30-day grace; KYC refs purged with account | PostgreSQL (`users`), Redis (session cache), logs (redacted) |
| Match (results, participants, brackets, replays) | Gameplay integrity, dispute resolution | Internal | Gameplay team | 24 months from match end | Anonymized after retention; replay blobs deleted; retained under legal hold if disputed | PostgreSQL (`matches`), object storage (replays), analytics |
| Financial (ledger entries, payouts, escrow, invoices) | Accounting, payouts, tax | Restricted | Finance team | 7 years (accounting exception) | Never hard-deleted within 7 years; soft-deleted/archived; access restricted to Finance + Auditors | PostgreSQL (`ledger`), object storage (invoices), analytics (aggregated only) |
| Evidence (dispute artifacts, screenshots, reports) | Dispute and fraud resolution | Restricted | Trust & Safety | 12 months after case closure | Deleted after closure unless under legal hold; access logged and restricted to T&S | Object storage (evidence bucket), PostgreSQL (case metadata) |
| Telemetry (events, metrics, traces, access logs) | Observability, security | Internal / Confidential | Platform team | 90 days raw; 13 months aggregated | Raw logs auto-expire; aggregates retained without identifiers; security logs 13 months | Logs, analytics, Redis (ephemeral counters) |

### Retention and deletion behavior

- **Account:** purged 30 days after closure; cached sessions in Redis expire within 24h.
- **Match:** anonymized at 24 months; replay objects removed from object storage.
- **Financial:** retained 7 years for accounting/tax; archived, never hard-deleted.
- **Evidence:** deleted 12 months after case closure unless a legal hold applies.
- **Telemetry:** raw data expires at 90 days; aggregates kept 13 months with identifiers stripped.

### Legal hold and accounting exceptions

- **Legal hold** suspends all deletion for the affected records until released.
  Only the Legal team (and designated Trust & Safety leads) may place or release
  a hold; every action is recorded in an immutable audit log.
- **Accounting retention** keeps financial records for 7 years regardless of
  account closure. Access is limited to Finance and Auditors via role-based
  access control; no bulk export without approval.
- Holds and exceptions are access-controlled: only authorized roles can view or
  modify held records, and all access is audited.

### Review guidance for new storage fields

Any PR that adds or changes a persisted field (PostgreSQL column, Redis key,
object-storage object, log field, or analytics event) **must** classify it in the
PR description before merge:

- **Sensitivity:** Public / Internal / Confidential / Restricted
- **Retention:** period and deletion behavior
- **Owner:** responsible team
- **System of record:** where the authoritative copy lives

PRs missing this classification must not be merged. When in doubt, treat the
field as Restricted and consult the owning team.
