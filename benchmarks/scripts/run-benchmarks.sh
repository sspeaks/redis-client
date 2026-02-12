#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run-benchmarks.sh — Stress-test Haskell and .NET REST APIs with autocannon
###############################################################################

HASKELL_URL="${HASKELL_URL:-http://localhost:3000}"
DOTNET_URL="${DOTNET_URL:-http://localhost:5000}"
DURATION="${DURATION:-30}"
CONNECTIONS="${CONNECTIONS:-100}"
PIPELINING="${PIPELINING:-10}"

# Determine output directory: standalone (default) or cluster
MODE="${BENCHMARK_MODE:-standalone}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../results/$MODE}"
mkdir -p "$RESULTS_DIR"

AUTOCANNON="npx --prefix $SCRIPT_DIR autocannon"

# Helper: pick a random user ID between 1 and 10000
rand_id() {
  echo $(( (RANDOM % 10000) + 1 ))
}

###############################################################################
# Scenario 1: GET single user (random IDs 1–10000)
###############################################################################
run_get_single() {
  local url="$1" label="$2"
  local uid
  uid=$(rand_id)
  echo ">>> [$label] GET single user — $url/users/$uid"
  $AUTOCANNON \
    -c "$CONNECTIONS" -p "$PIPELINING" -d "$DURATION" -j \
    --renderStatusCodes \
    "$url/users/$uid" \
    > "$RESULTS_DIR/${label}_get_single.json"
}

###############################################################################
# Scenario 2: GET paginated list
###############################################################################
run_get_list() {
  local url="$1" label="$2"
  echo ">>> [$label] GET paginated list — $url/users?page=1&limit=20"
  $AUTOCANNON \
    -c "$CONNECTIONS" -p "$PIPELINING" -d "$DURATION" -j \
    --renderStatusCodes \
    "$url/users?page=1&limit=20" \
    > "$RESULTS_DIR/${label}_get_list.json"
}

###############################################################################
# Scenario 3: POST new user (programmatic API for unique emails)
#   Lower connections to avoid SQLite write contention (single-writer DB)
###############################################################################
run_post() {
  local url="$1" label="$2"
  local post_conns=10
  echo ">>> [$label] POST new user — $url/users (${post_conns} connections)"
  node "$SCRIPT_DIR/post-bench.js" \
    "$url" "$post_conns" "1" "$DURATION" \
    "$RESULTS_DIR/${label}_post.json"
}

###############################################################################
# Scenario 4: Mixed workload (via Node.js programmatic API)
#   70% GET single, 10% GET list, 10% POST, 5% PUT, 5% DELETE
#   Lower connections to avoid SQLite write contention from concurrent writes
###############################################################################
run_mixed() {
  local url="$1" label="$2"
  local mixed_conns=20
  echo ">>> [$label] Mixed workload — $url (${mixed_conns} connections)"
  node "$SCRIPT_DIR/mixed-bench.js" \
    "$url" "$mixed_conns" "1" "$DURATION" \
    "$RESULTS_DIR/${label}_mixed.json"
}

###############################################################################
# Run all scenarios for a given target
###############################################################################
run_all() {
  local url="$1" label="$2"
  echo ""
  echo "=========================================="
  echo "  Benchmarking: $label ($url)"
  echo "  Duration: ${DURATION}s | Connections: $CONNECTIONS | Pipelining: $PIPELINING"
  echo "=========================================="
  run_get_single "$url" "$label"
  run_get_list   "$url" "$label"
  run_post       "$url" "$label"
  run_mixed      "$url" "$label"
}

###############################################################################
# Extract metrics from autocannon JSON and print summary table
###############################################################################
print_summary() {
  echo ""
  echo "=========================================="
  echo "  BENCHMARK RESULTS SUMMARY ($MODE mode)"
  echo "=========================================="

  printf "\n%-12s %-15s %10s %10s %10s %10s\n" \
    "Target" "Scenario" "Req/s" "p50(ms)" "p95(ms)" "p99(ms)"
  printf "%-12s %-15s %10s %10s %10s %10s\n" \
    "------" "--------" "-----" "-------" "-------" "-------"

  for label in haskell dotnet; do
    for scenario in get_single get_list post mixed; do
      local f="$RESULTS_DIR/${label}_${scenario}.json"
      if [ -f "$f" ]; then
        local rps p50 p95 p99
        rps=$(node -e "const d=require('$f'); console.log(d.requests?.average ?? 'N/A')")
        p50=$(node -e "const d=require('$f'); console.log(d.latency?.p50 ?? 'N/A')")
        p95=$(node -e "const d=require('$f'); console.log(d.latency?.p95 ?? 'N/A')")
        p99=$(node -e "const d=require('$f'); console.log(d.latency?.p99 ?? 'N/A')")
        printf "%-12s %-15s %10s %10s %10s %10s\n" "$label" "$scenario" "$rps" "$p50" "$p95" "$p99"
      fi
    done
  done
  echo ""
  echo "Raw JSON results saved to: $RESULTS_DIR/"
}

###############################################################################
# Main
###############################################################################
echo "=== Autocannon Benchmark Suite ==="
echo "Mode: $MODE"

SQLITE_DB="${SQLITE_DB:-$SCRIPT_DIR/../shared/bench.db}"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Reseed and flush Redis before each target for fair comparison
reseed() {
  echo ""
  echo ">>> Reseeding SQLite database and flushing Redis..."
  SQLITE_DB="$SQLITE_DB" python3 "$ROOT_DIR/benchmarks/shared/seed.py" 2>&1 || echo "  Warning: reseed had issues"
  if [ "$MODE" = "cluster" ]; then
    # Flush all cluster nodes
    for p in 7000 7001 7002 7003 7004; do
      redis-cli -p "$p" FLUSHALL > /dev/null 2>&1 || true
    done
  else
    docker compose -f "$ROOT_DIR/docker/docker-compose.yml" exec -T redis redis-cli FLUSHALL > /dev/null 2>&1 || \
      redis-cli FLUSHALL > /dev/null 2>&1 || true
  fi
  echo "  Done."
}

reseed
run_all "$HASKELL_URL" "haskell"

reseed
run_all "$DOTNET_URL"  "dotnet"

print_summary
