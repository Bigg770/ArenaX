#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL must be set before rolling back migrations." >&2
  exit 1
fi

assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --yes|--force)
      assume_yes=1
      ;;
    -h|--help)
      echo "Usage: $0 [--yes|--force]"
      echo
      echo "Reverts the latest applied backend migration."
      echo "By default an interactive confirmation is required."
      echo "Pass --yes or --force to skip the prompt (non-interactive use)."
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--yes|--force]" >&2
      exit 1
      ;;
  esac
done

echo "About to revert the latest applied backend migration."
echo "Create a database backup first for shared, staging, or production databases."

if [ "$assume_yes" -eq 1 ]; then
  echo "Non-interactive mode enabled (--yes/--force); skipping confirmation."
else
  read -r -p "Type 'revert latest' to continue: " confirmation

  if [ "$confirmation" != "revert latest" ]; then
    echo "Rollback cancelled."
    exit 1
  fi
fi

sqlx migrate revert --source ./migrations