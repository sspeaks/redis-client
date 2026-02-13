#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run-json-serialization.sh — Compare Aeson vs manual Builder JSON encoding
# Tests both cache-hit-heavy and cache-miss-heavy scenarios
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
echo ">>> Building Aeson (warp-only) and Manual Builder executables..."
(cd "$ROOT_DIR" && cabal build haskell-rest-warp-only haskell-rest-manual-json 2>&1 | tail -5)
AESON_BIN=$(cd "$ROOT_DIR" && cabal list-bin exe:haskell-rest-warp-only 2>/dev/null)
BUILDER_BIN=$(cd "$ROOT_DIR" && cabal list-bin exe:haskell-rest-manual-json 2>/dev/null)

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
  local name="$1" bin="$2" output_file="$3" scenario="$4"

  echo ""
  echo "=========================================="
  echo "  Variant: $name ($scenario)"
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

  if [ "$scenario" = "cache-hit" ]; then
    # Warm up: hit a single user repeatedly to populate cache
    local uid=$(( (RANDOM % 10000) + 1 ))
    echo "  Warming cache for user $uid (10s)..."
    $AUTOCANNON -c 50 -p 5 -d 10 "http://localhost:$HASKELL_PORT/users/$uid" > /dev/null 2>&1 || true

    # Benchmark: same user = almost all cache hits (JSON encoding bypassed)
    echo "  Running cache-hit benchmark: GET /users/$uid"
    $AUTOCANNON \
      -c "$CONNECTIONS" -p "$PIPELINING" -d "$DURATION" -j \
      --renderStatusCodes \
      "http://localhost:$HASKELL_PORT/users/$uid" \
      > "$output_file"
  else
    # Cache-miss scenario: flush Redis every 500ms in background to force cache misses
    # This ensures most requests go through SQLite → JSON encode → Redis SET → response
    local uid=$(( (RANDOM % 10000) + 1 ))
    echo "  Warming up (5s)..."
    $AUTOCANNON -c 50 -p 5 -d 5 "http://localhost:$HASKELL_PORT/users/$uid" > /dev/null 2>&1 || true

    flush_redis
    echo "  Starting continuous Redis flush (every 500ms) for cache-miss test..."

    # Background flusher to keep cache empty
    (while true; do
      flush_redis
      sleep 0.5
    done) &
    FLUSHER_PID=$!

    echo "  Running cache-miss benchmark: GET /users/$uid"
    $AUTOCANNON \
      -c "$CONNECTIONS" -p "$PIPELINING" -d "$DURATION" -j \
      --renderStatusCodes \
      "http://localhost:$HASKELL_PORT/users/$uid" \
      > "$output_file"

    # Stop the flusher
    kill "$FLUSHER_PID" 2>/dev/null || true
    wait "$FLUSHER_PID" 2>/dev/null || true
    echo "  Cache flusher stopped."
  fi

  echo "  Results saved to $(basename "$output_file")"

  # Stop app
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  echo "  App stopped."
  sleep 2
}

echo "=== JSON Serialization Benchmark ==="
echo "Comparing Aeson vs manual ByteString Builder on GET single (cluster mode)"
echo "Duration: ${DURATION}s | Connections: $CONNECTIONS | Pipelining: $PIPELINING"

# Cache-hit scenario (JSON encoding bypassed on hits — returns raw bytes from Redis)
run_variant "Aeson" "$AESON_BIN" "$RESULTS_DIR/json_aeson_cache_hit.json" "cache-hit"
run_variant "Builder" "$BUILDER_BIN" "$RESULTS_DIR/json_builder_cache_hit.json" "cache-hit"

# Cache-miss scenario (JSON encoding happens on every miss)
run_variant "Aeson" "$AESON_BIN" "$RESULTS_DIR/json_aeson_cache_miss.json" "cache-miss"
run_variant "Builder" "$BUILDER_BIN" "$RESULTS_DIR/json_builder_cache_miss.json" "cache-miss"

echo ""
echo "=== JSON Serialization Benchmark Complete ==="
echo ""

# Print comparison
print_results() {
  local scenario="$1"
  local key="${scenario//-/_}"
  echo ""
  echo "--- $scenario ---"
  printf "%-15s %10s %10s %10s %10s %10s\n" "Variant" "Req/s" "p50(ms)" "p97.5(ms)" "p99(ms)" "p99.9(ms)"
  printf "%-15s %10s %10s %10s %10s %10s\n" "-------" "-----" "-------" "--------" "-------" "--------"

  for variant in aeson builder; do
    local f="$RESULTS_DIR/json_${variant}_${key}.json"
    if [ -f "$f" ]; then
      rps=$(node -e "const d=require('$f'); console.log(d.requests?.average ?? 'N/A')")
      p50=$(node -e "const d=require('$f'); console.log(d.latency?.p50 ?? 'N/A')")
      p975=$(node -e "const d=require('$f'); console.log(d.latency?.p97_5 ?? d.latency?.p975 ?? 'N/A')")
      p99=$(node -e "const d=require('$f'); console.log(d.latency?.p99 ?? 'N/A')")
      p999=$(node -e "const d=require('$f'); console.log(d.latency?.p99_9 ?? d.latency?.p999 ?? 'N/A')")
      printf "%-15s %10s %10s %10s %10s %10s\n" "$variant" "$rps" "$p50" "$p975" "$p99" "$p999"
    fi
  done

  local aeson_rps=$(node -e "const d=require('$RESULTS_DIR/json_aeson_${key}.json'); console.log(d.requests?.average ?? 0)")
  local builder_rps=$(node -e "const d=require('$RESULTS_DIR/json_builder_${key}.json'); console.log(d.requests?.average ?? 0)")
  if [ "$aeson_rps" != "0" ] && [ "$aeson_rps" != "N/A" ]; then
    local diff_pct=$(node -e "console.log((($builder_rps - $aeson_rps) / $aeson_rps * 100).toFixed(1))")
    echo "  Builder vs Aeson: ${diff_pct}% throughput difference"
  fi
}

print_results "cache-hit"
print_results "cache-miss"

echo ""
echo "Results saved to: $RESULTS_DIR/json_*.json"
