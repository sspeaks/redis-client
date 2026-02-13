#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run-gc-tuning.sh — Test multiple GHC RTS flag combinations on GET single
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$ROOT_DIR/benchmarks/results/gc-http-json"
mkdir -p "$RESULTS_DIR"

HASKELL_PORT="${PORT_HASKELL:-3000}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-7000}"
SQLITE_DB="${SQLITE_DB:-$ROOT_DIR/benchmarks/shared/bench.db}"
DURATION="${DURATION:-30}"
CONNECTIONS=100
PIPELINING=10

HASKELL_BIN="$1"
AUTOCANNON="npx --prefix $SCRIPT_DIR autocannon"

# RTS flag configurations to test
declare -a CONFIG_NAMES=(
  "default"
  "aggressive-nursery"
  "match-main"
  "nonmoving-gc"
  "large-nursery-no-idle"
)

declare -a CONFIG_FLAGS=(
  "+RTS -N -RTS"
  "+RTS -A64m -n4m -H512m -N -RTS"
  "+RTS -H1024M -A128m -n8m -qb -N -RTS"
  "+RTS --nonmoving-gc -N -RTS"
  "+RTS -A128m -I0 -N -RTS"
)

declare -a CONFIG_DESCRIPTIONS=(
  "-N only (current default)"
  "-A64m -n4m -H512m -N (aggressive nursery)"
  "-H1024M -A128m -n8m -qb -N (match main executable)"
  "--nonmoving-gc -N (non-moving GC)"
  "-A128m -I0 -N (large nursery, idle GC disabled)"
)

wait_for_app() {
  local url="$1" name="$2"
  for _i in $(seq 1 30); do
    if curl -sf "$url/users/1" > /dev/null 2>&1; then
      echo "  $name is ready."
      return 0
    fi
    sleep 1
  done
  echo "  ERROR: $name did not become ready in 30 seconds." >&2
  return 1
}

flush_redis() {
  for p in 7000 7001 7002 7003 7004; do
    redis-cli -p "$p" FLUSHALL > /dev/null 2>&1 || true
  done
}

echo "=== GC Tuning Benchmark ==="
echo "Testing ${#CONFIG_NAMES[@]} RTS configurations on GET single (cluster mode)"
echo "Duration: ${DURATION}s | Connections: $CONNECTIONS | Pipelining: $PIPELINING"
echo ""

for i in "${!CONFIG_NAMES[@]}"; do
  name="${CONFIG_NAMES[$i]}"
  flags="${CONFIG_FLAGS[$i]}"
  desc="${CONFIG_DESCRIPTIONS[$i]}"

  echo "=========================================="
  echo "  Config $((i+1))/${#CONFIG_NAMES[@]}: $name"
  echo "  Flags: $flags"
  echo "=========================================="

  # Flush Redis for fair comparison
  flush_redis
  echo "  Redis flushed."

  # Start Haskell app with these RTS flags
  REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" REDIS_CLUSTER=true \
    SQLITE_DB="$SQLITE_DB" PORT="$HASKELL_PORT" \
    $HASKELL_BIN $flags &
  APP_PID=$!
  echo "  App PID: $APP_PID"

  # Wait for app to be ready
  wait_for_app "http://localhost:$HASKELL_PORT" "Haskell ($name)"

  # Warm up: quick 5s run to populate caches
  echo "  Warming up (5s)..."
  $AUTOCANNON -c 50 -p 5 -d 5 "http://localhost:$HASKELL_PORT/users/$(( (RANDOM % 10000) + 1 ))" > /dev/null 2>&1 || true

  # Run the actual benchmark
  uid=$(( (RANDOM % 10000) + 1 ))
  echo "  Running benchmark: GET /users/$uid"
  $AUTOCANNON \
    -c "$CONNECTIONS" -p "$PIPELINING" -d "$DURATION" -j \
    --renderStatusCodes \
    "http://localhost:$HASKELL_PORT/users/$uid" \
    > "$RESULTS_DIR/gc_${name}.json"

  echo "  Results saved to gc_${name}.json"

  # Stop the app
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  echo "  App stopped."
  echo ""

  # Brief pause between runs
  sleep 2
done

echo "=== GC Tuning Benchmark Complete ==="
echo ""

# Print summary table
echo "SUMMARY:"
printf "%-25s %10s %10s %10s %10s %10s\n" "Config" "Req/s" "p50(ms)" "p97.5(ms)" "p99(ms)" "p99.9(ms)"
printf "%-25s %10s %10s %10s %10s %10s\n" "------" "-----" "-------" "--------" "-------" "--------"

for i in "${!CONFIG_NAMES[@]}"; do
  name="${CONFIG_NAMES[$i]}"
  f="$RESULTS_DIR/gc_${name}.json"
  if [ -f "$f" ]; then
    rps=$(node -e "const d=require('$f'); console.log(d.requests?.average ?? 'N/A')")
    p50=$(node -e "const d=require('$f'); console.log(d.latency?.p50 ?? 'N/A')")
    p975=$(node -e "const d=require('$f'); console.log(d.latency?.p97_5 ?? d.latency?.p975 ?? 'N/A')")
    p99=$(node -e "const d=require('$f'); console.log(d.latency?.p99 ?? 'N/A')")
    p999=$(node -e "const d=require('$f'); console.log(d.latency?.p99_9 ?? d.latency?.p999 ?? 'N/A')")
    printf "%-25s %10s %10s %10s %10s %10s\n" "$name" "$rps" "$p50" "$p975" "$p99" "$p999"
  fi
done

echo ""
echo "Results saved to: $RESULTS_DIR/gc_*.json"
