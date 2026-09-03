#! /usr/bin/env nix-shell
#! nix-shell -p bash coreutils gawk gnugrep iproute2 redis -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/cluster/docker-compose.yml"
STARTED=0

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$STARTED" -eq 1 ]]; then
    docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -n "$(docker compose -f "$COMPOSE_FILE" ps -q)" ]]; then
  echo "Error: the cluster Compose project is already running; stop it before this isolated check." >&2
  exit 1
fi

STARTED=1
docker compose -f "$COMPOSE_FILE" up -d redis1

for _ in {1..15}; do
  if redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q '^PONG$'; then
    break
  fi
  sleep 1
done

if ! redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q '^PONG$'; then
  echo "Error: Redis was not reachable through its intended loopback publication." >&2
  exit 1
fi

if ! docker compose -f "$COMPOSE_FILE" exec -T redis1 \
  redis-cli -h redis1.local -p 6379 ping | grep -q '^PONG$'; then
  echo "Error: Redis was not reachable through the internal Compose network." >&2
  exit 1
fi

if [[ "$(docker compose -f "$COMPOSE_FILE" port redis1 6379)" != "127.0.0.1:6379" ]]; then
  echo "Error: Redis client port is not published exclusively on 127.0.0.1." >&2
  exit 1
fi

if docker compose -f "$COMPOSE_FILE" port redis1 16379 2>/dev/null | grep -q .; then
  echo "Error: Redis cluster-bus port 16379 must not be published to the host." >&2
  exit 1
fi

NON_LOOPBACK_IP="$(
  ip -4 -o addr show scope global |
    awk '{ split($4, address, "/"); if (address[1] !~ /^127\./) { print address[1]; exit } }'
)"
if [[ -z "$NON_LOOPBACK_IP" ]]; then
  echo "Error: no non-loopback IPv4 address is available for the exposure check." >&2
  exit 1
fi

if timeout 3 redis-cli -h "$NON_LOOPBACK_IP" -p 6379 ping 2>/dev/null | grep -q '^PONG$'; then
  echo "Error: Redis was reachable through non-loopback address $NON_LOOPBACK_IP." >&2
  exit 1
fi

printf '%s\n' "Redis is reachable locally and internally, but not through $NON_LOOPBACK_IP."
