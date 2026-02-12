#!/usr/bin/env bash
# Concurrency tuning benchmark script
# Runs benchmarks with varying thread counts and mux counts per node

set -euo pipefail

BENCH_BIN="${BENCH_BIN:-dist-newstyle/build/x86_64-linux/ghc-9.8.4/redis-client-0.5.0.0/x/redis-client/build/redis-client/redis-client}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-7000}"
DURATION="${DURATION:-10}"
KEY_SIZE="${KEY_SIZE:-16}"
VALUE_SIZE="${VALUE_SIZE:-256}"

THREAD_COUNTS=(1 2 4 8 16 32 64)
MUX_COUNTS=(1 2 4)
OPERATIONS=(set get mixed)

RESULTS_FILE="benchmarks/results/concurrency-tuning.json"
mkdir -p benchmarks/results

echo "Starting concurrency tuning benchmarks"
echo "Host: $HOST:$PORT, Duration: ${DURATION}s per test"
echo "Thread counts: ${THREAD_COUNTS[*]}"
echo "Mux counts: ${MUX_COUNTS[*]}"
echo "Operations: ${OPERATIONS[*]}"
echo ""

# Start JSON array
echo "[" > "$RESULTS_FILE"
first=true

for mux_count in "${MUX_COUNTS[@]}"; do
  for threads in "${THREAD_COUNTS[@]}"; do
    for op in "${OPERATIONS[@]}"; do
      echo "Testing: mux_count=$mux_count threads=$threads op=$op"
      
      result=$($BENCH_BIN bench -c -h "$HOST" -p "$PORT" \
        --operation "$op" --duration "$DURATION" \
        -n "$threads" --mux-count "$mux_count" \
        --key-size "$KEY_SIZE" --value-size "$VALUE_SIZE" 2>/dev/null || echo '{"error":true}')
      
      # Extract ops_per_sec
      ops=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ops_per_sec',0))" 2>/dev/null || echo "0")
      
      echo "  => $ops ops/sec"
      
      if [ "$first" = true ]; then
        first=false
      else
        echo "," >> "$RESULTS_FILE"
      fi
      
      # Write result with thread/mux metadata
      cat >> "$RESULTS_FILE" <<EOF
  {"threads":$threads,"mux_count":$mux_count,"operation":"$op","ops_per_sec":$ops,"duration_sec":$DURATION}
EOF
    done
  done
done

echo "" >> "$RESULTS_FILE"
echo "]" >> "$RESULTS_FILE"

echo ""
echo "Results saved to $RESULTS_FILE"
echo ""

# Print summary table
echo "=== Concurrency Tuning Summary ==="
printf "%-6s %-9s %-7s %s\n" "Mux" "Threads" "Op" "Ops/sec"
printf "%-6s %-9s %-7s %s\n" "---" "-------" "----" "-------"

python3 -c "
import json
with open('$RESULTS_FILE') as f:
    data = json.load(f)

for r in data:
    print(f\"{r['mux_count']:<6} {r['threads']:<9} {r['operation']:<7} {r['ops_per_sec']:>10,}\")

# Find optimal for each operation
print()
print('=== Optimal Configurations ===')
for op in ['set', 'get', 'mixed']:
    best = max([r for r in data if r['operation'] == op], key=lambda x: x['ops_per_sec'])
    print(f\"{op:>5}: {best['ops_per_sec']:>10,} ops/sec (threads={best['threads']}, mux_count={best['mux_count']})\")
"
