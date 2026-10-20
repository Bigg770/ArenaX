#!/bin/bash

# ArenaX Matchmaking System Benchmark Script
# Tests performance under various load conditions

set -e

# Configuration
API_BASE_URL="http://localhost:8080"
WS_BASE_URL="ws://localhost:8080"
TEST_GAME="benchmark-game"
TEST_MODE="ranked"
CONCURRENT_USERS=1000
TEST_DURATION=60  # seconds
WARMUP_TIME=10    # seconds

# WebSocket fanout / reconnect storm configuration
WS_CLIENTS=500          # authenticated realtime clients
WS_ROOMS=25             # tournament rooms to fan out across
WS_SLOW_CONSUMERS=25    # clients that deliberately read slowly
WS_RECONNECT_STORM=200  # clients that disconnect/reconnect at once
WS_RESTART_AT=30        # seconds into the run to restart the realtime service
WS_MAX_BUFFER_BYTES=262144  # per-connection buffer ceiling (256 KiB)
WS_MAX_QUEUE_DEPTH=1000     # per-connection outbound queue ceiling
WS_MAX_LATENCY_MS=500       # p95 delivery latency ceiling

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="matchmaking_benchmark_$(date +%Y%m%d_%H%M%S).log"
RESULTS_FILE="benchmark_results_$(date +%Y%m%d_%H%M%S).json"
WS_LOG_FILE="ws_fanout_$(date +%Y%m%d_%H%M%S).log"
WS_RESULTS_FILE="ws_fanout_results_$(date +%Y%m%d_%H%M%S).json"

echo -e "${BLUE}🚀 ArenaX Matchmaking Benchmark${NC}"
echo "=========================================="
echo "API Base URL: $API_BASE_URL"
echo "WS Base URL: $WS_BASE_URL"
echo "Test Game: $TEST_GAME"
echo "Test Mode: $TEST_MODE"
echo "Concurrent Users: $CONCURRENT_USERS"
echo "Test Duration: ${TEST_DURATION}s"
echo "Log File: $LOG_FILE"
echo "Results File: $RESULTS_FILE"
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

# Function to fetch realtime service metrics (memory, queue depth, latency)
get_realtime_metrics() {
    local token=$1
    
    curl -s -X GET "$API_BASE_URL/api/realtime/metrics" \
        -H "Authorization: Bearer $token"
}

# Function to benchmark queue operations
benchmark_queue_operations() {
    echo -e "${BLUE}📊 Benchmarking Queue Operations${NC}"
    
    local token=$(get_auth_token)
    local successful_joins=0
    local failed_joins=0
    local start_time=$(date +%s)
    
    echo "Testing join operations..."
    
    # Test concurrent joins
    for i in $(seq 1 $CONCURRENT_USERS); do
        local user_id="benchmark_user_$i"
        
        if [ "$(join_queue $user_id $token)" = "200" ]; then
            ((successful_joins++))
        else
            ((failed_joins++))
        fi
        
        # Progress indicator
        if [ $((i % 100)) -eq 0 ]; then
            echo -n "."
        fi
    done
    
    echo ""
    echo "Join Operations: $successful_joins successful, $failed_joins failed"
    
    # Wait for warmup
    echo -e "${YELLOW}⏳ Warming up for ${WARMUP_TIME}s...${NC}"
    sleep $WARMUP_TIME
    
    # Get initial stats
    local initial_stats=$(get_matchmaking_stats $token)
    echo "Initial queue size: $(echo $initial_stats | jq -r '.total_players_in_queue // 0')"
    
    # Monitor queue during test duration
    echo -e "${BLUE}📈 Monitoring queue for ${TEST_DURATION}s...${NC}"
    
    local end_time=$((start_time + TEST_DURATION))
    local sample_count=0
    
    while [ $(date +%s) -lt $end_time ]; do
        local current_stats=$(get_matchmaking_stats $token)
        local queue_size=$(echo $current_stats | jq -r '.total_players_in_queue // 0')
        local timestamp=$(date +%s)
        
        echo "$timestamp,$queue_size" >> "$LOG_FILE"
        ((sample_count++))
        
        sleep 5
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

# Function to simulate authenticated WebSocket clients joining rooms
ws_connect_clients() {
    local token=$1
    local count=$2
    local slow=$3
    
    echo -e "${BLUE}🔌 Connecting $count authenticated WebSocket clients (slow=$slow)...${NC}"
    
    for i in $(seq 1 $count); do
        local room=$((i % WS_ROOMS))
        local user_id="ws_user_$i"
        local slow_flag=""
        [ "$slow" = "true" ] && slow_flag="--slow"
        
        # Each client authenticates, joins a tournament room, and records
        # per-connection buffer growth, queue depth, and delivery latency.
        node scripts/ws_client.js \
            --url "$WS_BASE_URL/ws" \
            --token "$token" \
            --user "$user_id" \
            --room "room_$room" \
            --duration "$TEST_DURATION" \
            $slow_flag \
            --out "$WS_LOG_FILE" &
        
        if [ $((i % 50)) -eq 0 ]; then
            echo -n "."
        fi
    done
    
    echo ""
}

# Function to exercise room fanout at tournament-peak client counts
ws_fanout_peak() {
    echo -e "${BLUE}📡 Exercising room fanout across $WS_ROOMS rooms at peak${NC}"
    
    local token=$(get_auth_token)
    
    # Peak fanout: broadcast match updates to every room and measure
    # delivery latency and queue depth per connection.
    curl -s -X POST "$API_BASE_URL/api/realtime/broadcast" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "{\"rooms\":$WS_ROOMS,\"clients\":$WS_CLIENTS,\"payload\":\"match_update\"}" \
        -o /dev/null
    
    echo "Fanout broadcast dispatched to $WS_ROOMS rooms"
}

# Function to verify slow consumers keep bounded per-connection buffers
ws_check_slow_consumers() {
    echo -e "${BLUE}🐌 Verifying slow-consumer buffer bounds${NC}"
    
    local token=$(get_auth_token)
    local metrics=$(get_realtime_metrics $token)
    local max_buffer=$(echo "$metrics" | jq -r '.max_connection_buffer_bytes // 0')
    local max_queue=$(echo "$metrics" | jq -r '.max_queue_depth // 0')
    local dropped=$(echo "$metrics" | jq -r '.dropped_clients // 0')
    
    echo "Max per-connection buffer: ${max_buffer} bytes (ceiling ${WS_MAX_BUFFER_BYTES})"
    echo "Max queue depth: ${max_queue} (ceiling ${WS_MAX_QUEUE_DEPTH})"
    echo "Dropped clients: ${dropped}"
    
    if [ "$max_buffer" -gt "$WS_MAX_BUFFER_BYTES" ]; then
        echo -e "${RED}❌ Slow-consumer buffer exceeded ceiling${NC}"
        return 1
    fi
    if [ "$max_queue" -gt "$WS_MAX_QUEUE_DEPTH" ]; then
        echo -e "${RED}❌ Slow-consumer queue depth exceeded ceiling${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Slow-consumer buffers stayed bounded${NC}"
    return 0
}

# Function to simulate a disconnect/reconnect storm and verify convergence
ws_reconnect_storm() {
    echo -e "${BLUE}🌩️  Simulating reconnect storm ($WS_RECONNECT_STORM clients)${NC}"
    
    local token=$(get_auth_token)
    
    # Drop all storm clients at once, then reconnect them concurrently.
    curl -s -X POST "$API_BASE_URL/api/realtime/disconnect" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "{\"clients\":$WS_RECONNECT_STORM}" \
        -o /dev/null
    
    ws_connect_clients "$token" "$WS_RECONNECT_STORM" "false"
    
    # After reconnect, verify state converged without duplicate mutations.
    local metrics=$(get_realtime_metrics $token)
    local dup_mutations=$(echo "$metrics" | jq -r '.duplicate_state_mutations // 0')
    local converged=$(echo "$metrics" | jq -r '.reconnect_converged // false')
    
    echo "Duplicate state mutations: ${dup_mutations}"
    echo "Reconnect converged: ${converged}"
    
    if [ "$dup_mutations" -ne 0 ] || [ "$converged" != "true" ]; then
        echo -e "${RED}❌ Reconnect synchronization did not converge cleanly${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Reconnect synchronization converged without duplicate mutations${NC}"
    return 0
}

# Function to restart the realtime service mid-run and observe recovery
ws_restart_service() {
    echo -e "${YELLOW}♻️  Restarting realtime service at ${WS_RESTART_AT}s${NC}"
    
    curl -s -X POST "$API_BASE_URL/api/realtime/restart" \
        -H "Authorization: Bearer $(get_auth_token)" \
        -o /dev/null
    
    sleep 5
    check_api_health
}

# Function to run the WebSocket fanout and reconnect load profile
benchmark_ws_fanout() {
    echo -e "${BLUE}🛰️  WebSocket Fanout & Reconnect Storm Benchmark${NC}"
    echo "Clients: $WS_CLIENTS | Rooms: $WS_ROOMS | Slow: $WS_SLOW_CONSUMERS | Storm: $WS_RECONNECT_STORM"
    
    local token=$(get_auth_token)
    local start_time=$(date +%s)
    
    # 1. Connect authenticated clients and fan out across rooms.
    ws_connect_clients "$token" "$WS_CLIENTS" "false"
    ws_connect_clients "$token" "$WS_SLOW_CONSUMERS" "true"
    ws_fanout_peak
    
    # 2. Sample realtime metrics (memory, queue depth, latency) over the run.
    local end_time=$((start_time + TEST_DURATION))
    while [ $(date +%s) -lt $end_time ]; do
        local metrics=$(get_realtime_metrics $token)
        local ts=$(date +%s)
        local mem=$(echo "$metrics" | jq -r '.memory_bytes // 0')
        local queue=$(echo "$metrics" | jq -r '.max_queue_depth // 0')
        local latency=$(echo "$metrics" | jq -r '.p95_latency_ms // 0')
        echo "$ts,$mem,$queue,$latency" >> "$WS_LOG_FILE"
        
        # Restart the service once mid-run to observe recovery behavior.
        if [ $((ts - start_time)) -ge "$WS_RESTART_AT" ] && [ ! -f ".ws_restarted" ]; then
            ws_restart_service
            touch ".ws_restarted"
        fi
        
        sleep 5
    done
    rm -f ".ws_restarted"
    
    # 3. Verify slow-consumer bounds and reconnect convergence.
    local slow_ok=0
    local reconnect_ok=0
    ws_check_slow_consumers && slow_ok=1
    ws_reconnect_storm && reconnect_ok=1
    
    # 4. Emit the reproducible load profile and capacity envelope comparison.
    local final_metrics=$(get_realtime_metrics $token)
    cat > "$WS_RESULTS_FILE" << EOF
{
  "ws_fanout_benchmark": {
    "timestamp": "$(date -Iseconds)",
    "load_profile": {
      "ws_base_url": "$WS_BASE_URL",
      "clients": $WS_CLIENTS,
      "rooms": $WS_ROOMS,
      "slow_consumers": $WS_SLOW_CONSUMERS,
      "reconnect_storm": $WS_RECONNECT_STORM,
      "restart_at_seconds": $WS_RESTART_AT,
      "duration": $TEST_DURATION
    },
    "capacity_envelope": {
      "max_buffer_bytes": $WS_MAX_BUFFER_BYTES,
      "max_queue_depth": $WS_MAX_QUEUE_DEPTH,
      "max_latency_ms": $WS_MAX_LATENCY_MS
    },
    "results": {
      "final_metrics": $final_metrics,
      "slow_consumers_bounded": $slow_ok,
      "reconnect_converged": $reconnect_ok,
      "log_file": "$WS_LOG_FILE"
    }
  }
}
EOF
    
    echo "WebSocket fanout report saved to: $WS_RESULTS_FILE"
    
    if [ "$slow_ok" -eq 1 ] && [ "$reconnect_ok" -eq 1 ]; then
        echo -e "${GREEN}✅ WebSocket fanout & reconnect storm within capacity envelope${NC}"
    else
        echo -e "${RED}❌ WebSocket fanout & reconnect storm exceeded capacity envelope${NC}"
        return 1
    fi
}

# Function to generate performance report
generate_report() {
    echo -e "${BLUE}📋 Generating Performance Report${NC}"
    
    local token=$(get_auth_token)
    local final_stats=$(get_matchmaking_stats $token)
    
    # Create JSON report
    cat > "$RESULTS_FILE" << EOF
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
    
    echo "Report saved to: $RESULTS_FILE"
    
    # Display summary
    echo ""
    echo -e "${GREEN}📊 Benchmark Summary${NC}"
    echo "===================="
    echo "Total Players Tested: $CONCURRENT_USERS"
    echo "Test Duration: ${TEST_DURATION}s"
    echo "Final Queue Size: $(echo $final_stats | jq -r '.total_players_in_queue // 0')"
    echo "Active Games: $(echo $final_stats | jq -r '.active_games // 0')"
}

# Main execution
main() {
    echo -e "${BLUE}Starting benchmark suite...${NC}"
    echo ""
    
    # Check API health first
    if ! check_api_health; then
        echo -e "${RED}❌ Cannot proceed without healthy API${NC}"
        exit 1
    fi
    
    # Run benchmarks
    benchmark_queue_operations
    echo ""
    
    benchmark_api_latency
    echo ""
    
    stress_test_redis
    echo ""
    
    benchmark_ws_fanout
    echo ""
    
    generate_report
    echo ""
    
    echo -e "${GREEN}✅ Benchmark suite completed${NC}"
    echo "Results: $RESULTS_FILE"
    echo "WebSocket fanout results: $WS_RESULTS_FILE"
}

# Run main function
main "$@"
