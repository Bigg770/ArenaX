#!/usr/bin/env bash
#
# verify.sh — executable contract invariant checks for CI.
#
# This script is the single entry point CI uses to keep the TLA+/written
# invariants in contracts/specs/ synchronized with implemented contract
# behavior. It runs the available model checks with pinned dependencies and
# fails loudly (non-zero exit) when any invariant is violated.
#
# Maintained invariant set (see contracts/specs/INVARIANTS.md for the full
# mapping of invariant -> executable check -> named owner):
#   INV-1  FundsConservation   total funds in == total funds out + escrow
#   INV-2  NoNegativeBalances  no account balance drops below zero
#   INV-3  EscrowSolvency      escrow balance covers all open obligations
#   INV-4  StateMonotonicity   contract state never regresses to an earlier phase
#
# Model assumptions and known abstraction limits are documented in
# contracts/specs/INVARIANTS.md.
#
# Usage:
#   ./verify.sh            # run all invariant checks
#   ./verify.sh INV-1      # run a single invariant check
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${ROOT_DIR}/contracts/specs"

# Pinned tool versions so CI is reproducible. Bump deliberately, never
# implicitly.
TLA2TOOLS_VERSION="v1.7.1"
JAVA_VERSION="17"

# Pinned model-check configuration.
TLA_CONFIG="${SPECS_DIR}/contracts.cfg"
TLA_MODULE="${SPECS_DIR}/contracts.tla"

log()  { printf '[verify] %s\n' "$*" >&2; }
fail() { printf '[verify] FAIL: %s\n' "$*" >&2; exit 1; }

require_file() {
  [ -f "$1" ] || fail "required file missing: $1"
}

# --- Model check: TLA+ invariants -----------------------------------------
# Runs TLC against the pinned spec. A violated invariant makes TLC exit
# non-zero, which propagates through `set -e` and fails CI with a clear
# message naming the invariant.
run_model_check() {
  local target="${1:-}"
  require_file "${TLA_MODULE}"
  require_file "${TLA_CONFIG}"

  if ! command -v java >/dev/null 2>&1; then
    fail "java ${JAVA_VERSION} is required to run the TLA+ model check"
  fi

  local tla_jar="${ROOT_DIR}/.tools/tla2tools-${TLA2TOOLS_VERSION}.jar"
  if [ ! -f "${tla_jar}" ]; then
    fail "pinned TLA+ tools not found at ${tla_jar} (expected ${TLA2TOOLS_VERSION})"
  fi

  log "running TLA+ model check (${TLA2TOOLS_VERSION})${target:+ for ${target}}"
  if ! java -cp "${tla_jar}" tlc2.TLC \
      -config "${TLA_CONFIG}" \
      -deadlock \
      "${TLA_MODULE}"; then
    fail "model check failed: an invariant in ${TLA_CONFIG} was violated"
  fi
  log "model check passed"
}

# --- Executable invariant tests -------------------------------------------
# Each critical funds/state invariant has a test mapping. The mapping lives
# in contracts/specs/INVARIANTS.md; the tests themselves are run here so a
# deliberately violated invariant is detected by an automated check.
run_invariant_tests() {
  local target="${1:-}"
  local test_dir="${ROOT_DIR}/contracts/specs/tests"

  if [ ! -d "${test_dir}" ]; then
    fail "invariant test directory missing: ${test_dir}"
  fi

  log "running executable invariant tests${target:+ for ${target}}"
  local ran=0
  for test_file in "${test_dir}"/inv_*.sh; do
    [ -e "${test_file}" ] || continue
    if [ -n "${target}" ] && [[ "$(basename "${test_file}")" != *"${target}"* ]]; then
      continue
    fi
    log "  -> $(basename "${test_file}")"
    if ! bash "${test_file}"; then
      fail "invariant test failed: $(basename "${test_file}")"
    fi
    ran=$((ran + 1))
  done

  if [ "${ran}" -eq 0 ]; then
    fail "no invariant tests matched${target:+ target ${target}}"
  fi
  log "${ran} invariant test(s) passed"
}

main() {
  local target="${1:-}"
  log "verifying contract invariants${target:+ (${target})}"
  run_model_check "${target}"
  run_invariant_tests "${target}"
  log "all contract invariants verified"
}

main "$@"
