#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL must be set before running migrations." >&2
  exit 1
fi

# Migration verification harness (#3): exercises up/down paths, staged
# expand/backfill/contract compatibility, and failure-injection recovery
# on a disposable database before we touch the real one.
#
# MIGRATION_VERIFY_MODE controls which verification modes run:
#   - "full"    (default): up/down, staged, and failure-injection checks
#   - "staged":  up/down plus expand/backfill/contract compatibility
#   - "basic":   up/down only
#   - "skip":    bypass verification (not recommended; for emergencies only)
VERIFY_MODE="${MIGRATION_VERIFY_MODE:-full}"

case "$VERIFY_MODE" in
  full|staged|basic)
    echo "Running migration verification (mode: $VERIFY_MODE)..."
    MIGRATION_VERIFY_MODE="$VERIFY_MODE" ./scripts/verify-migrations.sh ./migrations
    ;;
  skip)
    echo "WARNING: MIGRATION_VERIFY_MODE=skip — bypassing migration verification." >&2
    ;;
  *)
    echo "Unknown MIGRATION_VERIFY_MODE='$VERIFY_MODE' (expected: full|staged|basic|skip)." >&2
    exit 1
    ;;
esac

sqlx migrate run --source ./migrations

# Post-migration health check (#871): reuse the harness's helper so the
# reachability and dirty-migration checks stay consistent with the
# verification scripts.
if [ -x ./scripts/verify-migrations.sh ] && grep -q 'post_migration_health_check' ./scripts/verify-migrations.sh; then
  # shellcheck source=/dev/null
  source ./scripts/verify-migrations.sh --source-only 2>/dev/null || true
fi

if declare -F post_migration_health_check >/dev/null 2>&1; then
  post_migration_health_check "$DATABASE_URL"
else
  # Fallback: inline health check if the helper is unavailable.
  if ! psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null 2>&1; then
    echo "FAIL: database unreachable after applying migrations." >&2
    exit 1
  fi

  if psql "$DATABASE_URL" -t -A -c "SELECT to_regclass('public._sqlx_migrations');" | grep -q '_sqlx_migrations'; then
    dirty="$(psql "$DATABASE_URL" -t -A -c "SELECT count(*) FROM _sqlx_migrations WHERE success = false;")"
    if [ "$dirty" != "0" ]; then
      echo "FAIL: $dirty migration(s) recorded as dirty after applying." >&2
      exit 1
    fi
    applied="$(psql "$DATABASE_URL" -t -A -c "SELECT count(*) FROM _sqlx_migrations WHERE success = true;")"
    echo "Post-migration health check OK: db reachable, $applied migration(s) applied, none dirty."
  else
    echo "Post-migration health check OK: db reachable (no _sqlx_migrations table yet)."
  fi
fi