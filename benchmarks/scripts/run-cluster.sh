#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run-cluster.sh — Full Redis Cluster benchmark: seed, start apps, bench
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HASKELL_PORT="${PORT_HASKELL:-3000}"
DOTNET_PORT="${PORT_DOTNET:-5000}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-7000}"
SQLITE_DB="${SQLITE_DB:-$ROOT_DIR/benchmarks/shared/bench.db}"

HASKELL_PID=""
DOTNET_PID=""

###############################################################################
# Cleanup: stop apps and Redis cluster on exit
###############################################################################
cleanup() {
  echo ""
  echo ">>> Cleaning up..."
  [ -n "$HASKELL_PID" ] && kill "$HASKELL_PID" 2>/dev/null && echo "  Stopped Haskell app (PID $HASKELL_PID)" || true
  [ -n "$DOTNET_PID" ]  && kill "$DOTNET_PID"  2>/dev/null && echo "  Stopped .NET app (PID $DOTNET_PID)"     || true

  echo "  Stopping Redis cluster..."
  docker compose -f "$ROOT_DIR/docker-cluster-host/docker-compose.yml" down --remove-orphans 2>/dev/null || true
  echo ">>> Cleanup complete."
}
trap cleanup EXIT

###############################################################################
# 1. Start Redis Cluster via docker compose + make_cluster.sh
###############################################################################
echo "=== Redis Cluster Benchmark ==="
echo ""
echo ">>> Starting Redis cluster with host networking..."
bash "$ROOT_DIR/docker-cluster-host/make_cluster.sh"

###############################################################################
# 2. Seed the database
###############################################################################
echo ""
echo ">>> Seeding SQLite database at $SQLITE_DB..."
SQLITE_DB="$SQLITE_DB" python3 "$ROOT_DIR/benchmarks/shared/seed.py"
echo "  Seeding complete."

###############################################################################
# 3. Build and start Haskell REST app (cluster mode)
###############################################################################
echo ""
echo ">>> Building Haskell REST app..."
(cd "$ROOT_DIR" && cabal build haskell-rest-benchmark 2>&1 | tail -5)
HASKELL_BIN=$(cd "$ROOT_DIR" && cabal list-bin haskell-rest-benchmark 2>/dev/null)

echo ">>> Starting Haskell REST app on port $HASKELL_PORT (cluster mode)..."
REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" REDIS_CLUSTER=true \
  SQLITE_DB="$SQLITE_DB" PORT="$HASKELL_PORT" \
  "$HASKELL_BIN" &
HASKELL_PID=$!
echo "  Haskell PID: $HASKELL_PID"

###############################################################################
# 4. Build and start .NET REST app (cluster mode)
###############################################################################
echo ""
echo ">>> Building .NET REST app..."
(cd "$ROOT_DIR/benchmarks/dotnet-rest/RedisBenchmark" && dotnet build -c Release --nologo -v q 2>&1 | tail -3)

echo ">>> Starting .NET REST app on port $DOTNET_PORT (cluster mode)..."
REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" REDIS_CLUSTER=true \
  SQLITE_DB="$SQLITE_DB" PORT="$DOTNET_PORT" \
  dotnet run --project "$ROOT_DIR/benchmarks/dotnet-rest/RedisBenchmark" -c Release --no-build &
DOTNET_PID=$!
echo "  .NET PID: $DOTNET_PID"

###############################################################################
# 5. Wait for both apps to be ready
###############################################################################
echo ""
echo ">>> Waiting for apps to be ready..."

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

wait_for_app "http://localhost:$HASKELL_PORT" "Haskell"
wait_for_app "http://localhost:$DOTNET_PORT"  ".NET"

###############################################################################
# 6. Run benchmarks
###############################################################################
echo ""
echo ">>> Running benchmark suite..."
export HASKELL_URL="http://localhost:$HASKELL_PORT"
export DOTNET_URL="http://localhost:$DOTNET_PORT"
export BENCHMARK_MODE="cluster"
export RESULTS_DIR="$ROOT_DIR/benchmarks/results/cluster"

# Install autocannon if needed
(cd "$SCRIPT_DIR" && npm install --silent 2>/dev/null)

bash "$SCRIPT_DIR/run-benchmarks.sh"

echo ""
echo "=== Redis Cluster benchmark complete ==="
echo "Results saved to: $ROOT_DIR/benchmarks/results/cluster/"
