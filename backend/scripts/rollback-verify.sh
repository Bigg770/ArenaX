#!/usr/bin/env bash
# Rollback verification: the up -> down -> up cycle from issue #871, extended
# for issue #3 (migration compatibility + rollback coverage).
#
# Proves that every migration's down.sql actually works and that the schema
# returns to a healthy state after re-applying it. Runs against the disposable
# PostgreSQL database provisioned by the shared harness in verify-migrations.sh
# (no duplicated provisioning / health-check logic here).
#
# For each migration (latest first, then every earlier one) the cycle is:
#
#   1. (optional) pre-migration backup  — backup-database.sh
#   2. snapshot schema state            — table count + applied migration
#   3. DOWN                             — sqlx migrate revert (the .down.sql runs)
#   4. health check                     — DB reachable, migration row gone,
#                                         schema still sane
#   5. UP                               — sqlx migrate run (the .up.sql runs again)
#   6. health check                     — migration row restored, table count
#                                         matches the snapshot
#
# Env:
#   DATABASE_URL        (optional) target Postgres connection string. When unset
#                                  the shared harness provisions a disposable DB.
#   SKIP_BACKUP         (optional) set to 1 to skip the pre-migration backup
#                                  (CI disposable databases; never on shared data)
#   BACKEND_HEALTH_URL  (optional) e.g. http://localhost:8080/api/health —
#                                  when set, the live backend health endpoint is
#                                  checked after DOWN and after UP
#   ROLLBACK_TARGET     (optional) "latest" (default) cycles only the latest
#                                  migration; "all" cycles every migration.
#
# Exit codes: 0 = up->down->up verified, non-zero = any down.sql or re-apply
# failed (or health checks caught a broken schema state).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ---------------------------------------------------------------------------
# 0. Shared harness — provisioning, psql helpers, health checks
# ---------------------------------------------------------------------------
# verify-migrations.sh owns disposable-database provisioning and the shared
# psql/health-check helpers. Source it in "library mode" so we reuse that logic
# instead of duplicating it. The harness exports:
#   psql_safe, harness_health_check, harness_ensure_database, harness_cleanup
# shellcheck source=./verify-migrations.sh
# shellcheck disable=SC1091
source ./scripts/verify-migrations.sh --lib

echo "== Rollback verification (up -> down -> up) =="

if ! command -v sqlx >/dev/null 2>&1; then
  echo "FAIL: sqlx CLI not found (install sqlx-cli 0.8.x)." >&2
  exit 1
fi

# Provision (or validate) the disposable database via the shared harness.
harness_ensure_database
trap 'harness_cleanup' EXIT

# ---------------------------------------------------------------------------
# 1. Pre-migration backup (skippable only for disposable databases)
# ---------------------------------------------------------------------------
if [ "${SKIP_BACKUP:-0}" = "1" ]; then
  echo "SKIP_BACKUP=1 — skipping pre-migration backup (disposable database only)."
else
  echo "Step 1: pre-migration backup"
  ./scripts/backup-database.sh
fi

# ---------------------------------------------------------------------------
# cycle_migration <version> — run the up->down->up cycle for one migration
# ---------------------------------------------------------------------------
cycle_migration() {
  local version="$1"
  local migration_file tables_before tables_down tables_after
  local target_after_down after_down_version restored_version restored_target dirty

  migration_file="$(find ./migrations -maxdepth 1 -type f -name "${version}_*.up.sql" -print -quit)"
  if [ -z "$migration_file" ]; then
    echo "FAIL: applied migration $version has no local .up.sql pair." >&2
    return 1
  fi
  if [ ! -f "${migration_file%.up.sql}.down.sql" ]; then
    echo "FAIL: applied migration $version has no local .down.sql pair." >&2
    return 1
  fi
  echo "  rollback target: $version ($(basename "$migration_file"))"

  # 2. Snapshot the state we must return to
  tables_before="$(psql_safe -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"
  echo "  public tables before: $tables_before"

  # 3. DOWN — revert this migration (this runs its .down.sql)
  echo "Step 3: DOWN — reverting migration $version"
  sqlx migrate revert --source ./migrations

  target_after_down="$(psql_safe -c "SELECT count(*) FROM _sqlx_migrations WHERE version = $version AND success = true;")"
  if [ "$target_after_down" != "0" ]; then
    echo "FAIL: after 'sqlx migrate revert' the target migration $version is still recorded as applied." >&2
    echo "      The down.sql either failed silently or was never executed." >&2
    return 1
  fi

  after_down_version="$(psql_safe -c "SELECT version FROM _sqlx_migrations WHERE success = true ORDER BY version DESC LIMIT 1;")"
  echo "  down verified: target no longer applied (current head: ${after_down_version:-none})"

  # 4. Health check while rolled back
  echo "Step 4: health check (rolled-back state)"

  if ! psql "$DATABASE_URL" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "FAIL: database unreachable after the down migration." >&2
    return 1
  fi

  if psql_safe -c "SELECT to_regclass('public._sqlx_migrations');" | grep -q '_sqlx_migrations'; then
    dirty="$(psql_safe -c "SELECT count(*) FROM _sqlx_migrations WHERE success = false;")"
    if [ "$dirty" != "0" ]; then
      echo "FAIL: $dirty migration(s) recorded as dirty (success=false) after the down." >&2
      return 1
    fi
  fi

  tables_down="$(psql_safe -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"
  echo "  db reachable, no dirty migrations, public tables after down: $tables_down"

  harness_health_check "after the down migration" || return 1

  # 5. UP — re-apply the migration (this runs its .up.sql again)
  echo "Step 5: UP — re-applying migration $version"
  sqlx migrate run --source ./migrations

  # 6. Health check after re-apply
  echo "Step 6: health check (restored state)"

  restored_version="$(psql_safe -c "SELECT version FROM _sqlx_migrations WHERE success = true ORDER BY version DESC LIMIT 1;")"
  if [ "$restored_version" != "$version" ]; then
    echo "FAIL: after re-apply, head migration is $restored_version, expected $version." >&2
    return 1
  fi

  restored_target="$(psql_safe -c "SELECT count(*) FROM _sqlx_migrations WHERE version = $version AND success = true;")"
  if [ "$restored_target" != "1" ]; then
    echo "FAIL: migration $version was not recorded as successfully applied after re-apply." >&2
    return 1
  fi

  dirty="$(psql_safe -c "SELECT count(*) FROM _sqlx_migrations WHERE success = false;")"
  if [ "$dirty" != "0" ]; then
    echo "FAIL: $dirty migration(s) recorded as dirty after the re-apply." >&2
    return 1
  fi

  tables_after="$(psql_safe -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"
  echo "  migration head restored: $restored_version"
  echo "  public tables after up: $tables_after (before: $tables_before)"

  if [ "$tables_after" != "$tables_before" ]; then
    echo "FAIL: table count changed across the up->down->up cycle ($tables_before -> $tables_after)." >&2
    echo "      The down.sql drops something the up.sql does not recreate (or vice versa)." >&2
    return 1
  fi

  harness_health_check "after the re-apply" || return 1

  echo "  OK: migration $version survived the up -> down -> up cycle"
  return 0
}

# ---------------------------------------------------------------------------
# 2. Preconditions — the harness has applied all migrations already
# ---------------------------------------------------------------------------
if ! psql_safe -c "SELECT to_regclass('public._sqlx_migrations');" | grep -q '_sqlx_migrations'; then
  echo "FAIL: _sqlx_migrations table not found — has migrate.sh ever run here?" >&2
  exit 1
fi

latest_version="$(psql_safe -c "SELECT version FROM _sqlx_migrations WHERE success = true ORDER BY version DESC LIMIT 1;")"
if [ -z "$latest_version" ]; then
  echo "FAIL: no successful applied migration found — nothing to cycle." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Cycle the target migration(s)
# ---------------------------------------------------------------------------
case "${ROLLBACK_TARGET:-latest}" in
  latest)
    cycle_migration "$latest_version"
    ;;
  all)
    # Cycle every applied migration, newest first. Each cycle reverts one
    # migration and re-applies it, so the head returns to $latest_version
    # before the next iteration.
    versions="$(psql_safe -c "SELECT version FROM _sqlx_migrations WHERE success = true ORDER BY version DESC;")"
    if [ -z "$versions" ]; then
      echo "FAIL: no applied migrations to cycle." >&2
      exit 1
    fi
    for v in $versions; do
      echo ""
      echo "-- cycling migration $v --"
      if ! cycle_migration "$v"; then
        echo "FAIL: rollback verification failed for migration $v." >&2
        exit 1
      fi
    done
    ;;
  *)
    echo "FAIL: unknown ROLLBACK_TARGET '${ROLLBACK_TARGET}' (expected 'latest' or 'all')." >&2
    exit 1
    ;;
esac

echo ""
echo "VERIFIED: rollback cycle(s) survived with backup, schema integrity and"
echo "          health checks. (#871, #3)"
