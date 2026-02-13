#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run-http-framework.sh — Compare Scotty vs raw Warp on GET single
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

# RTS flags — use best-performing from US-002 (match-main)
RTS_FLAGS="+RTS -H1024M -A128m -n8m -qb -N -RTS"

AUTOCANNON="npx --prefix $SCRIPT_DIR autocannon"

# Build both executables
echo ">>> Building Scotty and Warp-only executables..."
(cd "$ROOT_DIR" && cabal build haskell-rest-benchmark haskell-rest-warp-only 2>&1 | tail -5)
SCOTTY_BIN=$(cd "$ROOT_DIR" && cabal list-bin exe:haskell-rest-benchmark 2>/dev/null)
WARP_BIN=$(cd "$ROOT_DIR" && cabal list-bin exe:haskell-rest-warp-only 2>/dev/null)

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

run_variant() {
  local name="$1" bin="$2" output_file="$3"

  echo ""
  echo "=========================================="
  echo "  Variant: $name"
  echo "  RTS flags: $RTS_FLAGS"
  echo "=========================================="

  # Flush Redis for fair comparison
  flush_redis
  echo "  Redis flushed."

  # Start app
  REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" REDIS_CLUSTER=true \
    SQLITE_DB="$SQLITE_DB" PORT="$HASKELL_PORT" \
    $bin $RTS_FLAGS &
  APP_PID=$!
  echo "  App PID: $APP_PID"

  wait_for_app "http://localhost:$HASKELL_PORT" "$name"

  # Warm up
  echo "  Warming up (5s)..."
  $AUTOCANNON -c 50 -p 5 -d 5 "http://localhost:$HASKELL_PORT/users/$(( (RANDOM % 10000) + 1 ))" > /dev/null 2>&1 || true

  # Run benchmark
  local uid=$(( (RANDOM % 10000) + 1 ))
  echo "  Running benchmark: GET /users/$uid"
  $AUTOCANNON \
    -c "$CONNECTIONS" -p "$PIPELINING" -d "$DURATION" -j \
    --renderStatusCodes \
    "http://localhost:$HASKELL_PORT/users/$uid" \
    > "$output_file"

  echo "  Results saved to $(basename "$output_file")"

  # Stop app
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  echo "  App stopped."
  sleep 2
}

echo "=== HTTP Framework Benchmark ==="
echo "Comparing Scotty vs raw Warp on GET single (cluster mode)"
echo "Duration: ${DURATION}s | Connections: $CONNECTIONS | Pipelining: $PIPELINING"

run_variant "Scotty" "$SCOTTY_BIN" "$RESULTS_DIR/http_scotty.json"
run_variant "Warp-only" "$WARP_BIN" "$RESULTS_DIR/http_warp_only.json"

echo ""
echo "=== HTTP Framework Benchmark Complete ==="
echo ""

# Print comparison
echo "COMPARISON:"
printf "%-15s %10s %10s %10s %10s %10s\n" "Variant" "Req/s" "p50(ms)" "p97.5(ms)" "p99(ms)" "p99.9(ms)"
printf "%-15s %10s %10s %10s %10s %10s\n" "-------" "-----" "-------" "--------" "-------" "--------"

for variant in scotty warp_only; do
  f="$RESULTS_DIR/http_${variant}.json"
  if [ -f "$f" ]; then
    label=$(echo "$variant" | tr '_' '-')
    rps=$(node -e "const d=require('$f'); console.log(d.requests?.average ?? 'N/A')")
    p50=$(node -e "const d=require('$f'); console.log(d.latency?.p50 ?? 'N/A')")
    p975=$(node -e "const d=require('$f'); console.log(d.latency?.p97_5 ?? d.latency?.p975 ?? 'N/A')")
    p99=$(node -e "const d=require('$f'); console.log(d.latency?.p99 ?? 'N/A')")
    p999=$(node -e "const d=require('$f'); console.log(d.latency?.p99_9 ?? d.latency?.p999 ?? 'N/A')")
    printf "%-15s %10s %10s %10s %10s %10s\n" "$label" "$rps" "$p50" "$p975" "$p99" "$p999"
  fi
done

# Calculate difference
scotty_rps=$(node -e "const d=require('$RESULTS_DIR/http_scotty.json'); console.log(d.requests?.average ?? 0)")
warp_rps=$(node -e "const d=require('$RESULTS_DIR/http_warp_only.json'); console.log(d.requests?.average ?? 0)")
if [ "$scotty_rps" != "0" ] && [ "$scotty_rps" != "N/A" ]; then
  diff_pct=$(node -e "console.log((($warp_rps - $scotty_rps) / $scotty_rps * 100).toFixed(1))")
  echo ""
  echo "Warp-only vs Scotty: ${diff_pct}% throughput difference"
fi

echo ""
echo "Results saved to: $RESULTS_DIR/http_*.json"
