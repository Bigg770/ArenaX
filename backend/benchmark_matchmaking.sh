#!/bin/bash

# ArenaX API Load & Saturation Benchmark Script
# Measures throughput, p50/p95/p99 latency, error rates, and dependency
# saturation across auth, tournament browse/join, match result, leaderboard,
# and wallet read endpoints under reproducible, seeded traffic profiles.
#
# Workload/data configuration is kept separate from production credentials:
# all inputs come from env vars with safe local defaults and no prod secrets.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (env-overridable; no production credentials)
# ---------------------------------------------------------------------------
API_BASE_URL="${API_BASE_URL:-http://localhost:8080}"

# Seeded, reproducible data volume
SEED="${BENCH_SEED:-117}"
SEEDED_USERS="${BENCH_SEEDED_USERS:-1000}"
SEEDED_TOURNAMENTS="${BENCH_SEEDED_TOURNAMENTS:-50}"

# Defined traffic profiles: name:concurrency:duration_seconds
TRAFFIC_PROFILES="${BENCH_PROFILES:-baseline:10:30,ramp:50:60,saturation:200:60}"
WARMUP_TIME="${BENCH_WARMUP:-5}"

# Dependency saturation thresholds (percent)
CPU_SAT_THRESHOLD="${BENCH_CPU_SAT:-85}"
MEM_SAT_THRESHOLD="${BENCH_MEM_SAT:-85}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="benchmark_${RUN_ID}.log"
RESULTS_FILE="benchmark_results_${RUN_ID}.json"

# Per-endpoint latency samples (nanoseconds), reset per profile
declare -A LATENCY_SAMPLES

# Endpoints under test: name|method|path|body
ENDPOINTS=(
  "auth|POST|/api/auth/login|{\"username\":\"bench_user_1\",\"password\":\"benchmark\"}"
  "tournament_browse|GET|/api/tournaments|-"
  "tournament_join|POST|/api/tournaments/1/join|-"
  "match_result|POST|/api/matches/1/result|{\"winner_id\":1,\"score\":\"2-1\"}"
  "leaderboard|GET|/api/leaderboard|-"
  "wallet_read|GET|/api/wallet|-"
)

echo -e "${BLUE}🚀 ArenaX API Load & Saturation Benchmark${NC}"
echo "=========================================="
echo "API Base URL:        $API_BASE_URL"
echo "Seed:                $SEED"
echo "Seeded users:        $SEEDED_USERS"
echo "Seeded tournaments:  $SEEDED_TOURNAMENTS"
echo "Traffic profiles:    $TRAFFIC_PROFILES"
echo "Log File:            $LOG_FILE"
echo "Results File:        $RESULTS_FILE"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
check_api_health() {
    echo -e "${YELLOW}🔍 Checking API health...${NC}"
    local max_attempts=30 attempt=1
    while [ $attempt -le $max_attempts ]; do
        if curl -s -f "$API_BASE_URL/api/health" > /dev/null; then
            echo -e "${GREEN}✅ API is healthy${NC}"
            return 0
        fi
        echo -e "${YELLOW}⏳ Waiting for API... ($attempt/$max_attempts)${NC}"
        sleep 2
        ((attempt++))
    done
    echo -e "${RED}❌ API is not available${NC}"
    return 1
}

# Seed reproducible data volume (idempotent; uses local benchmark creds only)
seed_data() {
    echo -e "${YELLOW}🌱 Seeding reproducible data (seed=$SEED)...${NC}"
    curl -s -X POST "$API_BASE_URL/api/benchmark/seed" \
        -H "Content-Type: application/json" \
        -d "{\"seed\":$SEED,\"users\":$SEEDED_USERS,\"tournaments\":$SEEDED_TOURNAMENTS}" \
        -o /dev/null -w "seed_http=%{http_code}\n" || true
}

# Issue a single request; emit "http_code latency_ns"
issue_request() {
    local method=$1 path=$2 body=$3
    local args=(-s -X "$method" "$API_BASE_URL$path" -o /dev/null -w "%{http_code} %{time_total}")
    if [ "$body" != "-" ]; then
        args+=(-H "Content-Type: application/json" -d "$body")
    fi
    curl "${args[@]}"
}

# Compute a percentile (ms) from the LATENCY_SAMPLES array for an endpoint
percentile() {
    local endpoint=$1 pct=$2
    local samples=(${LATENCY_SAMPLES[$endpoint]:-})
    local n=${#samples[@]}
    [ "$n" -eq 0 ] && { echo "0"; return; }
    local sorted=($(printf '%s\n' "${samples[@]}" | sort -n))
    local idx=$(( (pct * n + 99) / 100 - 1 ))
    [ $idx -lt 0 ] && idx=0
    [ $idx -ge $n ] && idx=$((n - 1))
    # ns -> ms with 2 decimals
    awk -v v="${sorted[$idx]}" 'BEGIN { printf "%.2f", v / 1000000 }'
}

# Sample dependency saturation (CPU/mem) for the API process, if available
sample_saturation() {
    local cpu mem
    cpu=$(ps -o %cpu= -C "${API_PROCESS_NAME:-arenax-api}" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    mem=$(ps -o %mem= -C "${API_PROCESS_NAME:-arenax-api}" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    echo "${cpu:-0} ${mem:-0}"
}

# ---------------------------------------------------------------------------
# Benchmark a single traffic profile across all endpoints
# ---------------------------------------------------------------------------
benchmark_profile() {
    local name=$1 concurrency=$2 duration=$3
    echo -e "${BLUE}📊 Profile '$name' (concurrency=$concurrency, duration=${duration}s)${NC}"

    # Reset per-profile counters
    local -A errors
    local -A counts
    for ep in "${ENDPOINTS[@]}"; do
        local ename="${ep%%|*}"
        LATENCY_SAMPLES[$ename]=""
        errors[$ename]=0
        counts[$ename]=0
    done

    # Warmup
    echo -e "${YELLOW}⏳ Warmup ${WARMUP_TIME}s...${NC}"
    sleep "$WARMUP_TIME"

    local start_time end_time total_requests=0 total_errors=0
    start_time=$(date +%s)
    end_time=$((start_time + duration))

    while [ "$(date +%s)" -lt "$end_time" ]; do
        for ep in "${ENDPOINTS[@]}"; do
            IFS='|' read -r ename method path body <<< "$ep"
            local result http latency_s
            result=$(issue_request "$method" "$path" "$body")
            http=$(echo "$result" | awk '{print $1}')
            latency_s=$(echo "$result" | awk '{print $2}')
            local latency_ns
            latency_ns=$(awk -v s="$latency_s" 'BEGIN { printf "%d", s * 1000000000 }')

            LATENCY_SAMPLES[$ename]+=" $latency_ns"
            counts[$ename]=$(( ${counts[$ename]} + 1 ))
            total_requests=$((total_requests + 1))

            if [ "$http" -lt 200 ] || [ "$http" -ge 400 ]; then
                errors[$ename]=$(( ${errors[$ename]} + 1 ))
                total_errors=$((total_errors + 1))
            fi
        done
        # Pace to approximate the target concurrency
        sleep "$(awk -v c="$concurrency" 'BEGIN { printf "%.3f", 1 / c }')"
    done

    local elapsed=$(( $(date +%s) - start_time ))
    [ "$elapsed" -eq 0 ] && elapsed=1
    local throughput
    throughput=$(awk -v r="$total_requests" -v t="$elapsed" 'BEGIN { printf "%.2f", r / t }')
    local error_rate
    error_rate=$(awk -v e="$total_errors" -v r="$total_requests" 'BEGIN { printf "%.4f", (r>0 ? e/r : 0) }')

    read -r cpu mem <<< "$(sample_saturation)"
    local cpu_sat mem_sat
    cpu_sat=$(awk -v c="$cpu" -v t="$CPU_SAT_THRESHOLD" 'BEGIN { print (c >= t) ? "true" : "false" }')
    mem_sat=$(awk -v m="$mem" -v t="$MEM_SAT_THRESHOLD" 'BEGIN { print (m >= t) ? "true" : "false" }')

    # Emit per-endpoint JSON
    local endpoints_json="{"
    local first=1
    for ep in "${ENDPOINTS[@]}"; do
        local ename="${ep%%|*}"
        local p50 p95 p99
        p50=$(percentile "$ename" 50)
        p95=$(percentile "$ename" 95)
        p99=$(percentile "$ename" 99)
        [ $first -eq 0 ] && endpoints_json+=","
        first=0
        endpoints_json+="\"$ename\":{\"requests\":${counts[$ename]},\"errors\":${errors[$ename]},\"p50_ms\":$p50,\"p95_ms\":$p95,\"p99_ms\":$p99}"
    done
    endpoints_json+="}"

    cat >> "$RESULTS_FILE" << EOF
{
  "profile": "$name",
  "concurrency": $concurrency,
  "duration_s": $elapsed,
  "throughput_rps": $throughput,
  "total_requests": $total_requests,
  "total_errors": $total_errors,
  "error_rate": $error_rate,
  "dependency_saturation": {
    "cpu_percent": $cpu,
    "mem_percent": $mem,
    "cpu_saturated": $cpu_sat,
    "mem_saturated": $mem_sat
  },
  "endpoints": $endpoints_json
}
EOF

    echo -e "${GREEN}  throughput=${throughput} rps  errors=${total_errors} (${error_rate})  cpu=${cpu}%  mem=${mem}%${NC}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_api_health
seed_data

# Initialize results file as a JSON array
echo "[" > "$RESULTS_FILE"

first_profile=1
IFS=',' read -ra PROFILES <<< "$TRAFFIC_PROFILES"
for profile in "${PROFILES[@]}"; do
    IFS=':' read -r pname pconc pdur <<< "$profile"
    [ $first_profile -eq 0 ] && echo "," >> "$RESULTS_FILE"
    first_profile=0
    benchmark_profile "$pname" "$pconc" "$pdur"
done

echo "]" >> "$RESULTS_FILE"

echo ""
echo -e "${GREEN}📋 Benchmark complete${NC}"
echo "Results: $RESULTS_FILE"
echo "Log:     $LOG_FILE"
echo ""
echo "Note: results identify bottlenecks (per-endpoint p95/p99 and dependency"
echo "saturation) rather than asserting unsupported performance targets."
