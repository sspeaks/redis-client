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
    for port in 7000 7001 7002; do
      redis-cli -h 127.0.0.1 -p "$port" shutdown nosave >/dev/null 2>&1 || true
    done
    rm -rf "$CLUSTER_ROOT"
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

cabal run redis-client-benchmark -- \
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
  +RTS -T -RTS >/dev/null

cabal run redis-client-benchmark -- \
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
  +RTS -T -RTS >/dev/null

mkdir -p "$CLUSTER_ROOT"
for port in 7000 7001 7002; do
  mkdir -p "$CLUSTER_ROOT/$port"
  cat >"$CLUSTER_ROOT/$port/redis.conf" <<EOF
bind 127.0.0.1
protected-mode no
port $port
save ""
appendonly no
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-announce-ip 127.0.0.1
cluster-announce-port $port
dir $CLUSTER_ROOT/$port
daemonize yes
pidfile $CLUSTER_ROOT/$port/redis.pid
logfile $CLUSTER_ROOT/$port/redis.log
EOF
  redis-server "$CLUSTER_ROOT/$port/redis.conf"
done
CLUSTER_STARTED=1

for port in 7000 7001 7002; do
  for attempt in $(seq 1 20); do
    if redis-cli -h 127.0.0.1 -p "$port" ping 2>/dev/null | grep -qx PONG; then
      break
    fi
    if [[ "$attempt" -eq 20 ]]; then
      echo "Error: Redis cluster node on port $port did not become ready." >&2
      exit 1
    fi
    sleep 0.5
  done
done

redis-cli --cluster create \
  127.0.0.1:7000 \
  127.0.0.1:7001 \
  127.0.0.1:7002 \
  --cluster-yes >/dev/null

cabal run redis-client-benchmark -- \
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
  +RTS -T -RTS >/dev/null

python3 - <<'PY'
import json
from pathlib import Path

artifact_dir = Path("artifacts/benchmark-smoke")
for path in sorted(artifact_dir.glob("*.json")):
    with path.open("r", encoding="utf-8") as handle:
        json.load(handle)
PY
