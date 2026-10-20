#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL must be set before checking migration status." >&2
  exit 1
fi

JSON_MODE=0
for arg in "$@"; do
  case "$arg" in
    --json)
      JSON_MODE=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: migration-status.sh [--json]

Checks the status of database migrations.

Options:
  --json    Emit a machine-readable JSON summary of applied, pending and
            dirty migrations by querying _sqlx_migrations.
  -h, --help
            Show this help message.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [ "$JSON_MODE" -eq 0 ]; then
  sqlx migrate info --source ./migrations
  exit 0
fi

# Machine-readable summary. We query _sqlx_migrations directly so that the
# failure-injection mode in verify-migrations.sh can assert that a partially
# applied migration is reported as dirty and diagnosable.
#
# A migration is considered "dirty" when it has been recorded in
# _sqlx_migrations but its success flag is false (i.e. it started but did not
# complete). Applied migrations are those with success = true. Pending
# migrations are those present on disk but not yet recorded in the table.
#
# The query emits a single JSON object. We rely on psql's -tA (tuples only,
# unaligned) output so that the result is a single line of JSON.

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required for --json mode." >&2
  exit 1
fi

# Collect the set of migration versions present on disk. sqlx names files as
# <version>_<description>.sql; we extract the numeric version prefix.
disk_versions=""
if [ -d ./migrations ]; then
  disk_versions="$(
    find ./migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' 2>/dev/null \
      | sed -E 's/^([0-9]+)_.*/\1/' \
      | grep -E '^[0-9]+$' \
      | sort -n \
      | paste -sd, - || true
  )"
fi

# Build a JSON array of disk versions for use in the SQL below.
if [ -z "$disk_versions" ]; then
  disk_versions_json='[]'
else
  disk_versions_json="[$(echo "$disk_versions" | sed 's/,/,/g')]"
fi

read -r -d '' STATUS_SQL <<SQL || true
WITH disk(version) AS (
  SELECT (v)::bigint
  FROM jsonb_array_elements_text('${disk_versions_json}'::jsonb) AS t(v)
),
recorded AS (
  SELECT
    version,
    description,
    success,
    installed_on
  FROM _sqlx_migrations
)
SELECT jsonb_build_object(
  'applied', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'version', r.version,
      'description', r.description,
      'installed_on', r.installed_on
    ) ORDER BY r.version)
    FROM recorded r
    WHERE r.success = true
  ), '[]'::jsonb),
  'pending', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'version', d.version
    ) ORDER BY d.version)
    FROM disk d
    WHERE NOT EXISTS (
      SELECT 1 FROM recorded r WHERE r.version = d.version
    )
  ), '[]'::jsonb),
  'dirty', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'version', r.version,
      'description', r.description,
      'installed_on', r.installed_on
    ) ORDER BY r.version)
    FROM recorded r
    WHERE r.success = false
  ), '[]'::jsonb),
  'dirty_count', (
    SELECT count(*) FROM recorded r WHERE r.success = false
  ),
  'applied_count', (
    SELECT count(*) FROM recorded r WHERE r.success = true
  ),
  'pending_count', (
    SELECT count(*) FROM disk d
    WHERE NOT EXISTS (
      SELECT 1 FROM recorded r WHERE r.version = d.version
    )
  )
)::text;
SQL

# If _sqlx_migrations does not exist yet, report everything on disk as pending
# and nothing as applied or dirty, rather than failing.
table_exists="$(
  psql "$DATABASE_URL" -tA -v ON_ERROR_STOP=1 -c \
    "SELECT to_regclass('public._sqlx_migrations') IS NOT NULL;" 2>/dev/null || echo "f"
)"

if [ "$table_exists" != "t" ]; then
  if [ -z "$disk_versions" ]; then
    pending_json='[]'
    pending_count=0
  else
    pending_json="$(
      echo "$disk_versions" \
        | tr ',' '\n' \
        | awk 'NF {printf "%s{\"version\": %s}", (n++ ? "," : ""), $1}'
    )"
    pending_json="[${pending_json}]"
    pending_count="$(echo "$disk_versions" | tr ',' '\n' | grep -cE '^[0-9]+$' || true)"
  fi
  printf '{"applied": [], "pending": %s, "dirty": [], "dirty_count": 0, "applied_count": 0, "pending_count": %s}\n' \
    "$pending_json" "$pending_count"
  exit 0
fi

result="$(
  psql "$DATABASE_URL" -tA -v ON_ERROR_STOP=1 -c "$STATUS_SQL"
)"

if [ -z "$result" ]; then
  echo "Failed to query migration status." >&2
  exit 1
fi

printf '%s\n' "$result"

# Exit non-zero when dirty migrations are detected so callers can gate on it.
dirty_count="$(
  printf '%s' "$result" \
    | sed -E 's/.*"dirty_count": *([0-9]+).*/\1/' 2>/dev/null || echo "0"
)"
if [ -n "$dirty_count" ] && [ "$dirty_count" -gt 0 ] 2>/dev/null; then
  echo "Detected ${dirty_count} dirty migration(s); manual intervention required." >&2
  exit 3
fi