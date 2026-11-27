#! /usr/bin/env nix-shell
#! nix-shell -i bash -p bash coreutils openssl python3 redis
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/artifacts/benchmark-smoke"
STANDALONE_STARTED=0
STANDALONE_MODE=""
CLUSTER_ROOT="$ARTIFACT_DIR/cluster-fixture"
CLUSTER_STARTED=0

run_benchmark() {
  local -a cmd=(cabal run redis-client-benchmark -- "$@")
  local rendered_cmd

  printf -v rendered_cmd '%q ' "${cmd[@]}"
  (
    cd "$REPO_ROOT"
    nix-shell --run "$rendered_cmd"
  ) >/dev/null
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$STANDALONE_STARTED" -eq 1 ]]; then
    if [[ "$STANDALONE_MODE" == "docker" ]]; then
      "$SCRIPT_DIR/stop-standalone-redis.sh" >/dev/null 2>&1
    else
      redis-cli -h 127.0.0.1 -p 6379 shutdown nosave >/dev/null 2>&1 || true
      rm -f "$ARTIFACT_DIR/redis-standalone.pid"
    fi
  fi
  if [[ "$CLUSTER_STARTED" -eq 1 ]]; then
    "$SCRIPT_DIR/benchmark-cluster.sh" stop "$CLUSTER_ROOT"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

cd "$REPO_ROOT"

mkdir -p "$ARTIFACT_DIR"
rm -f "$ARTIFACT_DIR"/*.json
rm -rf "$CLUSTER_ROOT"

if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
  "$SCRIPT_DIR/start-standalone-redis.sh"
  STANDALONE_MODE="docker"
else
  redis-server \
    --save "" \
    --appendonly no \
    --bind 127.0.0.1 \
    --port 6379 \
    --daemonize yes \
    --pidfile "$ARTIFACT_DIR/redis-standalone.pid"
  STANDALONE_MODE="local"
  sleep 1
fi
STANDALONE_STARTED=1

run_benchmark \
  --scenario standalone \
  --host 127.0.0.1 \
  --port 6379 \
  --duration 1 \
  --warmup 0 \
  --concurrency 2 \
  --batch-size 8 \
  --mux-count 1 \
  --key-size 16 \
  --payload-size 64 \
  --operation mixed \
  --timeout-ms 500 \
  --output "$ARTIFACT_DIR/standalone.json" \
  +RTS -T -RTS

run_benchmark \
  --scenario slow-server \
  --duration 1 \
  --warmup 0 \
  --concurrency 2 \
  --batch-size 16 \
  --mux-count 1 \
  --key-size 16 \
  --payload-size 64 \
  --operation ping \
  --timeout-ms 75 \
  --response-delay-ms 50 \
  --stall-after-requests 4 \
  --output "$ARTIFACT_DIR/slow-server.json" \
  +RTS -T -RTS

CLUSTER_STARTED=1
"$SCRIPT_DIR/benchmark-cluster.sh" start "$CLUSTER_ROOT"

run_benchmark \
  --scenario cluster \
  --host 127.0.0.1 \
  --port 7000 \
  --duration 1 \
  --warmup 0 \
  --concurrency 2 \
  --batch-size 8 \
  --mux-count 2 \
  --key-size 16 \
  --payload-size 64 \
  --operation mixed \
  --timeout-ms 500 \
  --output "$ARTIFACT_DIR/cluster.json" \
  +RTS -T -RTS

python3 - <<'PY'
import json
from pathlib import Path

artifact_dir = Path("artifacts/benchmark-smoke")
for path in sorted(artifact_dir.glob("*.json")):
    with path.open("r", encoding="utf-8") as handle:
        json.load(handle)
PY
