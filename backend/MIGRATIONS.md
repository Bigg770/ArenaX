# Database Migrations

This document describes how schema migrations are authored, gated, and released
alongside application deploys. It is the contract that makes rollout and
rollback transactional: traffic is only shifted after migrations and readiness
checks pass, and rollback restores the prior application artifact without
reversing schema destructively.

## Principles

1. **Migrations are backward compatible.** Every migration must be safe to run
   while the previous application version is still serving traffic. Deploy the
   schema change first, then the code that depends on it.
2. **Expand / contract, never in one step.** Add new columns/tables/indexes in
   one release (expand), migrate data, then remove the old shape in a later
   release (contract) once no running version references it.
3. **Rollback is application-only.** Rolling back restores the previous
   application artifact (image/release identity). Schema is *not* reversed by
   rollback; destructive down-migrations are not run automatically.
4. **Migrations are gated.** A failed migration stops the deploy before any
   traffic shift.

## Authoring rules

- Additive changes only in a single release: `ADD COLUMN` (nullable or with a
  default), `CREATE TABLE`, `CREATE INDEX CONCURRENTLY`.
- Never `DROP COLUMN`, `DROP TABLE`, or rename in the same release that stops
  using them. Do the drop in a follow-up release after the old code is gone.
- Never make a column `NOT NULL` without a default in the same release that
  introduces it; backfill first, then tighten in a later release.
- Keep each migration idempotent where the engine allows it, and small enough
  to complete within the deploy gate timeout.
- Down-migrations must be non-destructive: they may drop objects the same
  release created, but must never drop or rewrite data that predates the
  release.

## Deploy gate (rollout)

The deploy workflow runs in this order and **stops before traffic shift** on any
failure:

1. **Artifact identity** — build and tag the release artifact; record the
   release id (image digest / commit SHA) used for this rollout.
2. **Migration gate** — run pending migrations. If any migration fails, abort
   the deploy; no traffic is shifted and the previous version keeps serving.
3. **Readiness gate** — start the new version and wait for health/readiness
   checks. If readiness does not pass within the timeout, abort before traffic
   shift and leave the previous version serving.
4. **Traffic shift** — only after steps 1–3 succeed is traffic staged to the
   new version.

Operator output at each step must identify:

- the **release** being deployed (artifact id / commit),
- the **migration state** (applied / pending / failed, with the failing
  migration name),
- the **gate decision** (proceed or stop) and, on stop, the reason.

## Rollback

Rollback is triggered when a rollout fails after traffic shift or when a
post-deploy check regresses.

1. **Restore the prior application artifact** by release id — redeploy the
   previously recorded image digest / commit, not a rebuild.
2. **Do not reverse schema destructively.** Because migrations are backward
   compatible (expand/contract), the prior application version runs against the
   current schema. No down-migration is executed automatically.
3. **Readiness gate on rollback** — wait for the restored version to pass
   health/readiness checks before shifting traffic back.
4. **Operator output** must identify the release being restored, the current
   migration state (schema is left as-is), and the rollback decision point
   (why rollback was chosen and whether it succeeded).

If a schema change is genuinely incompatible and must be undone, that is a
manual, reviewed operation — never an automatic rollback step.

## Validation

Exercise both failure paths in staging before relying on them in production:

- **Failed health check:** deploy a version whose readiness check fails and
  confirm traffic is never shifted and the previous version keeps serving.
- **Rollback path:** deploy a bad release, trigger rollback, and confirm the
  prior artifact is restored, readiness passes, and no destructive schema
  reversal occurred.
