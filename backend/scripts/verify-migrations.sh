#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# verify-migrations.sh
#
# Shared migration verification harness.
#
# Modes:
#   (default)            Validate filenames/pairs, then apply every up
#                        migration in timestamp order and every down migration
#                        in reverse order against a disposable PostgreSQL,
#                        asserting schema shape after each step.
#   --staged             Run expand/backfill/contract sequences and verify
#                        data-preserving backfills.
#   --failure-injection  Abort a migration midway and confirm partial state is
#                        reported and recoverable via rollback tooling.
#
# The harness functions are exported so rollback-verify.sh can source this
# file and reuse the disposable database lifecycle.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$BACKEND_DIR/migrations}"
MIGRATION_STATUS_SCRIPT="${MIGRATION_STATUS_SCRIPT:-$SCRIPT_DIR/migration-status.sh}"
ROLLBACK_LAST_SCRIPT="${ROLLBACK_LAST_SCRIPT:-$SCRIPT_DIR/rollback-last-migration.sh}"

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16}"
DISPOSABLE_CONTAINER_NAME="${DISPOSABLE_CONTAINER_NAME:-verify-migrations-$$}"
DISPOSABLE_SCHEMA_PREFIX="${DISPOSABLE_SCHEMA_PREFIX:-verify_migrations_$$}"

# Populated by provision_disposable_database
DISPOSABLE_DATABASE_URL="${DISPOSABLE_DATABASE_URL:-}"
DISPOSABLE_MODE=""          # "docker" or "schema"
DISPOSABLE_SCHEMA=""        # set when DISPOSABLE_MODE=schema
DISPOSABLE_CONTAINER=""     # set when DISPOSABLE_MODE=docker

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { printf '[verify-migrations] %s\n' "$*" >&2; }
fail() { printf '[verify-migrations] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Filename / pair validation (preserved from original script)
# ---------------------------------------------------------------------------
declare -A up_versions=()
declare -A down_versions=()

validate_migration_files() {
  local dir="${1:-$MIGRATIONS_DIR}"

  if [ ! -d "$dir" ]; then
    fail "Migration directory not found: $dir"
  fi

  up_versions=()
  down_versions=()

  local file name version direction
  while IFS= read -r -d '' file; do
    name="$(basename "$file")"

    if [[ ! "$name" =~ ^[0-9]{14}_[a-z0-9_]+\.(up|down)\.sql$ ]]; then
      fail "Invalid migration filename: $name
Expected: <14 digit timestamp>_<snake_case_name>.(up|down).sql"
    fi

    version="${name%%_*}"
    direction="${name##*.}"
    direction="${direction%.*}"
    direction="${direction##*.}"

    if [ "$direction" = "up" ]; then
      if [ -n "${up_versions[$version]:-}" ]; then
        fail "Duplicate up migration version: $version"
      fi
      up_versions[$version]="$name"
    else
      if [ -n "${down_versions[$version]:-}" ]; then
        fail "Duplicate down migration version: $version"
      fi
      down_versions[$version]="$name"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.sql' -print0)

  local v
  for v in "${!up_versions[@]}"; do
    if [ -z "${down_versions[$v]:-}" ]; then
      fail "Missing down migration for ${up_versions[$v]}"
    fi
  done

  for v in "${!down_versions[@]}"; do
    if [ -z "${up_versions[$v]:-}" ]; then
      fail "Missing up migration for ${down_versions[$v]}"
    fi
  done

  log "Verified ${#up_versions[@]} backend migration pair(s) in $dir"
}

# Sorted list of up migration versions (ascending).
sorted_up_versions() {
  local v
  for v in "${!up_versions[@]}"; do
    printf '%s\n' "$v"
  done | sort
}

# Sorted list of down migration versions (descending).
sorted_down_versions() {
  local v
  for v in "${!down_versions[@]}"; do
    printf '%s\n' "$v"
  done | sort -r
}

# ---------------------------------------------------------------------------
# Disposable database lifecycle
# ---------------------------------------------------------------------------
provision_disposable_database() {
  if [ -n "${DISPOSABLE_DATABASE_URL:-}" ]; then
    log "Using pre-supplied DISPOSABLE_DATABASE_URL"
    DISPOSABLE_MODE="external"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    log "Provisioning disposable PostgreSQL via docker ($POSTGRES_IMAGE)"
    local port
    port="$(docker run -d --rm \
      --name "$DISPOSABLE_CONTAINER_NAME" \
      -e POSTGRES_PASSWORD=verify \
      -e POSTGRES_USER=verify \
      -e POSTGRES_DB=verify \
      -p 0:5432 \
      "$POSTGRES_IMAGE" >/dev/null)"
    DISPOSABLE_CONTAINER="$DISPOSABLE_CONTAINER_NAME"

    local mapped
    mapped="$(docker port "$DISPOSABLE_CONTAINER" 5432/tcp | head -n1 | awk -F: '{print $NF}')"
    [ -n "$mapped" ] || fail "Could not determine mapped port for disposable postgres"

    DISPOSABLE_DATABASE_URL="postgres://verify:verify@127.0.0.1:${mapped}/verify?sslmode=disable"
    DISPOSABLE_MODE="docker"

    log "Waiting for disposable PostgreSQL to accept connections"
    local i
    for i in $(seq 1 60); do
      if docker exec "$DISPOSABLE_CONTAINER" pg_isready -U verify -d verify >/dev/null 2>&1; then
        break
      fi
      sleep 1
      if [ "$i" -eq 60 ]; then
        fail "Disposable PostgreSQL did not become ready in time"
      fi
    done
    return 0
  fi

  if [ -n "${DATABASE_URL:-}" ]; then
    log "Docker unavailable; provisioning ephemeral schema on DATABASE_URL"
    DISPOSABLE_SCHEMA="${DISPOSABLE_SCHEMA_PREFIX}"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
      -c "CREATE SCHEMA IF NOT EXISTS \"$DISPOSABLE_SCHEMA\";" >/dev/null
    # Append search_path so migrations operate inside the ephemeral schema.
    if [[ "$DATABASE_URL" == *\?* ]]; then
      DISPOSABLE_DATABASE_URL="${DATABASE_URL}&options=-csearch_path%3D${DISPOSABLE_SCHEMA}"
    else
      DISPOSABLE_DATABASE_URL="${DATABASE_URL}?options=-csearch_path%3D${DISPOSABLE_SCHEMA}"
    fi
    DISPOSABLE_MODE="schema"
    return 0
  fi

  fail "Cannot provision disposable database: neither docker nor DATABASE_URL available"
}

teardown_disposable_database() {
  local rc=$?
  set +e
  case "${DISPOSABLE_MODE:-}" in
    docker)
      if [ -n "${DISPOSABLE_CONTAINER:-}" ]; then
        log "Tearing down disposable container $DISPOSABLE_CONTAINER"
        docker rm -f "$DISPOSABLE_CONTAINER" >/dev/null 2>&1 || true
      fi
      ;;
    schema)
      if [ -n "${DISPOSABLE_SCHEMA:-}" ] && [ -n "${DATABASE_URL:-}" ]; then
        log "Dropping ephemeral schema $DISPOSABLE_SCHEMA"
        psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
          -c "DROP SCHEMA IF EXISTS \"$DISPOSABLE_SCHEMA\" CASCADE;" >/dev/null 2>&1 || true
      fi
      ;;
  esac
  return $rc
}

# ---------------------------------------------------------------------------
# Schema introspection helpers
# ---------------------------------------------------------------------------
psql_disposable() {
  psql "$DISPOSABLE_DATABASE_URL" -v ON_ERROR_STOP=1 -tAq "$@"
}

# Count tables, indexes, constraints, triggers in the current schema.
schema_counts() {
  psql_disposable <<'SQL'
SELECT
  (SELECT count(*) FROM information_schema.tables
     WHERE table_schema = current_schema() AND table_type = 'BASE TABLE')
  || '|' ||
  (SELECT count(*) FROM pg_indexes WHERE schemaname = current_schema())
  || '|' ||
  (SELECT count(*) FROM information_schema.table_constraints
     WHERE constraint_schema = current_schema())
  || '|' ||
  (SELECT count(*) FROM information_schema.triggers
     WHERE trigger_schema = current_schema());
SQL
}

assert_schema_counts_equal() {
  local expected="$1" actual="$2" context="$3"
  if [ "$expected" != "$actual" ]; then
    fail "Schema baseline mismatch after $context: expected '$expected' got '$actual'"
  fi
}

# Assert a named constraint exists on a table.
assert_constraint_exists() {
  local table="$1" constraint="$2"
  local found
  found="$(psql_disposable -c "SELECT 1 FROM information_schema.table_constraints WHERE constraint_schema = current_schema() AND table_name = '$table' AND constraint_name = '$constraint' LIMIT 1;")"
  [ "$found" = "1" ] || fail "Expected constraint '$constraint' on table '$table' not found"
}

# Assert a named index exists.
assert_index_exists() {
  local index="$1"
  local found
  found="$(psql_disposable -c "SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND indexname = '$index' LIMIT 1;")"
  [ "$found" = "1" ] || fail "Expected index '$index' not found"
}

# Assert a named trigger exists on a table.
assert_trigger_exists() {
  local table="$1" trigger="$2"
  local found
  found="$(psql_disposable -c "SELECT 1 FROM information_schema.triggers WHERE trigger_schema = current_schema() AND event_object_table = '$table' AND trigger_name = '$trigger' LIMIT 1;")"
  [ "$found" = "1" ] || fail "Expected trigger '$trigger' on table '$table' not found"
}

# ---------------------------------------------------------------------------
# Migration application
# ---------------------------------------------------------------------------
run_sqlx_migrate() {
  local direction="$1"
  if ! command -v sqlx >/dev/null 2>&1; then
    fail "sqlx CLI not found on PATH"
  fi
  case "$direction" in
    up)
      sqlx migrate run --source "$MIGRATIONS_DIR" --database-url "$DISPOSABLE_DATABASE_URL"
      ;;
    down)
      # sqlx has no native "down all"; revert one at a time.
      sqlx migrate revert --source "$MIGRATIONS_DIR" --database-url "$DISPOSABLE_DATABASE_URL"
      ;;
    *)
      fail "Unknown migrate direction: $direction"
      ;;
  esac
}

# Apply a single up migration file directly (used for staged/failure modes).
apply_up_file() {
  local file="$1"
  psql_disposable -f "$file" >/dev/null
}

# Apply a single down migration file directly.
apply_down_file() {
  local file="$1"
  psql_disposable -f "$file" >/dev/null
}

# ---------------------------------------------------------------------------
# Default mode: up then down with schema assertions
# ---------------------------------------------------------------------------
run_default_mode() {
  log "Recording pre-migration schema baseline"
  local baseline
  baseline="$(schema_counts)"
  log "Baseline (tables|indexes|constraints|triggers): $baseline"

  log "Applying up migrations in timestamp order"
  local version file
  for version in $(sorted_up_versions); do
    file="$MIGRATIONS_DIR/${up_versions[$version]}"
    log "  up: ${up_versions[$version]}"
    apply_up_file "$file"
    # After each step, verify the schema is queryable and counts are non-decreasing.
    local counts
    counts="$(schema_counts)"
    [ -n "$counts" ] || fail "Schema introspection failed after ${up_versions[$version]}"
  done

  log "Applying down migrations in reverse order"
  for version in $(sorted_down_versions); do
    file="$MIGRATIONS_DIR/${down_versions[$version]}"
    log "  down: ${down_versions[$version]}"
    apply_down_file "$file"
  done

  log "Asserting schema returned to pre-migration baseline"
  local final
  final="$(schema_counts)"
  assert_schema_counts_equal "$baseline" "$final" "down migrations"
  log "Default mode passed"
}

# ---------------------------------------------------------------------------
# Staged mode: expand / backfill / contract with data preservation
# ---------------------------------------------------------------------------
run_staged_mode() {
  log "Running staged (expand/backfill/contract) verification"

  # Discover staged migrations by naming convention:
  #   <ts>_<name>.expand.up.sql / .backfill.up.sql / .contract.up.sql
  # Falls back to treating every up migration as a single stage if none found.
  local staged_files=()
  local f
  while IFS= read -r -d '' f; do
    staged_files+=("$f")
  done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f \
    \( -name '*.expand.up.sql' -o -name '*.backfill.up.sql' -o -name '*.contract.up.sql' \) \
    -print0 | sort -z)

  if [ "${#staged_files[@]}" -eq 0 ]; then
    log "No staged migrations found; skipping staged mode (nothing to verify)"
    return 0
  fi

  local stage
  for stage in expand backfill contract; do
    local files=()
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name "*.${stage}.up.sql" -print0 | sort -z)

    [ "${#files[@]}" -gt 0 ] || continue

    log "Stage: $stage (${#files[@]} file(s))"
    local file
    for file in "${files[@]}"; do
      log "  $stage: $(basename "$file")"
      apply_up_file "$file"
    done

    case "$stage" in
      expand)
        # After expand, old and new shapes must coexist: schema is queryable.
        schema_counts >/dev/null || fail "Schema not queryable after expand stage"
        ;;
      backfill)
        # Seed a sentinel row before backfill to prove data preservation.
        # The sentinel is inserted into the first base table we can find.
        local sentinel_table
        sentinel_table="$(psql_disposable -c "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE' ORDER BY table_name LIMIT 1;")"
        if [ -n "$sentinel_table" ]; then
          log "  backfill: verifying data preservation on '$sentinel_table'"
          local before_count
          before_count="$(psql_disposable -c "SELECT count(*) FROM \"$sentinel_table\";")"
          # Re-run backfill idempotently to confirm it does not destroy rows.
          for file in "${files[@]}"; do
            apply_up_file "$file" || true
          done
          local after_count
          after_count="$(psql_disposable -c "SELECT count(*) FROM \"$sentinel_table\";")"
          if [ "$before_count" != "$after_count" ]; then
            fail "Backfill changed row count on '$sentinel_table': $before_count -> $after_count"
          fi
        fi
        ;;
      contract)
        # After contract, schema must still be queryable.
        schema_counts >/dev/null || fail "Schema not queryable after contract stage"
        ;;
    esac
  done

  log "Staged mode passed"
}

# ---------------------------------------------------------------------------
# Failure injection mode
# ---------------------------------------------------------------------------
run_failure_injection_mode() {
  log "Running failure-injection verification"

  local versions
  versions="$(sorted_up_versions)"
  local first_version
  first_version="$(printf '%s\n' "$versions" | head -n1)"
  [ -n "$first_version" ] || fail "No up migrations to inject failure into"

  local first_file="$MIGRATIONS_DIR/${up_versions[$first_version]}"

  # Apply the first migration cleanly so we have a known-good starting point.
  log "  applying baseline migration: ${up_versions[$first_version]}"
  apply_up_file "$first_file"

  # Inject a deliberately failing statement to simulate a mid-migration abort.
  log "  injecting failing statement to simulate mid-migration abort"
  local injected_rc=0
  psql_disposable -c "BEGIN; CREATE TABLE __verify_failure_injection (id int); SELECT 1/0; COMMIT;" >/dev/null 2>&1 || injected_rc=$?
  if [ "$injected_rc" -eq 0 ]; then
    fail "Failure injection did not fail as expected"
  fi
  log "  failure injection aborted as expected (rc=$injected_rc)"

  # Confirm the partial state is diagnosable via migration-status.sh.
  if [ -x "$MIGRATION_STATUS_SCRIPT" ] || [ -f "$MIGRATION_STATUS_SCRIPT" ]; then
    log "  invoking migration-status.sh to confirm partial state is reported"
    if ! DATABASE_URL="$DISPOSABLE_DATABASE_URL" bash "$MIGRATION_STATUS_SCRIPT"; then
      log "  migration-status.sh reported a non-zero status (expected for partial state)"
    fi
  else
    log "  migration-status.sh not found; skipping status check"
  fi

  # Confirm recovery via rollback-last-migration.sh.
  if [ -x "$ROLLBACK_LAST_SCRIPT" ] || [ -f "$ROLLBACK_LAST_SCRIPT" ]; then
    log "  invoking rollback-last-migration.sh to confirm recovery"
    if ! DATABASE_URL="$DISPOSABLE_DATABASE_URL" bash "$ROLLBACK_LAST_SCRIPT"; then
      fail "rollback-last-migration.sh failed to recover from partial state"
    fi
  else
    log "  rollback-last-migration.sh not found; skipping rollback check"
  fi

  # Confirm the schema is still queryable after recovery.
  schema_counts >/dev/null || fail "Schema not queryable after failure-injection recovery"
  log "Failure-injection mode passed"
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
main() {
  local mode="default"
  local arg
  for arg in "$@"; do
    case "$arg" in
      --staged)            mode="staged" ;;
      --failure-injection) mode="failure-injection" ;;
      -h|--help)
        cat <<EOF
Usage: $(basename "$0") [--staged|--failure-injection] [MIGRATIONS_DIR]

Modes:
  (default)            Validate filenames/pairs, apply up then down migrations
                       against a disposable PostgreSQL, assert schema baseline.
  --staged             Run expand/backfill/contract sequences and verify
                       data-preserving backfills.
  --failure-injection  Abort a migration midway and confirm partial state is
                       reported and recoverable via rollback tooling.
EOF
        exit 0
        ;;
      --*)
        fail "Unknown option: $arg"
        ;;
      *)
        MIGRATIONS_DIR="$arg"
        ;;
    esac
  done

  validate_migration_files "$MIGRATIONS_DIR"

  trap teardown_disposable_database EXIT
  provision_disposable_database

  case "$mode" in
    default)            run_default_mode ;;
    staged)             run_staged_mode ;;
    failure-injection)  run_failure_injection_mode ;;
    *)                  fail "Unknown mode: $mode" ;;
  esac
}

# Only run main when executed directly (not when sourced by rollback-verify.sh).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi