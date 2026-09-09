#! /usr/bin/env nix-shell
#! nix-shell -p bash openssl -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/standalone/docker-compose.yml"
TLS_RUNTIME_ROOT="$REPO_ROOT/docker/standalone/.runtime"
STATE_FILE="$TLS_RUNTIME_ROOT/standalone-cert-dir"
TLS_CERT_DIR=""
STARTED=0

cleanup_on_failure() {
  local status=$?

  trap - EXIT INT TERM HUP
  if [[ "$status" -ne 0 ]]; then
    set +e
    if [[ "$STARTED" -eq 1 ]]; then
      docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1
    fi
    rm -f "$STATE_FILE"
    if [[ -n "$TLS_CERT_DIR" ]]; then
      rm -rf -- "$TLS_CERT_DIR"
    fi
    rmdir "$TLS_RUNTIME_ROOT" 2>/dev/null
  fi
  exit "$status"
}

trap cleanup_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -f "$STATE_FILE" ]]; then
  echo "Error: standalone Redis TLS state already exists; run 'make redis-stop' first." >&2
  exit 1
fi

TLS_CERT_DIR="$("$SCRIPT_DIR/generate-test-tls-certs.sh" "$TLS_RUNTIME_ROOT")"
printf '%s\n' "$TLS_CERT_DIR" >"$STATE_FILE"
chmod 600 "$STATE_FILE"

export REDIS_TLS_CERT_DIR="$TLS_CERT_DIR"
export REDIS_TLS_CERT_UID
export REDIS_TLS_CERT_GID
REDIS_TLS_CERT_UID="$(id -u)"
REDIS_TLS_CERT_GID="$(id -g)"

STARTED=1
docker compose -f "$COMPOSE_FILE" up -d redis
sleep 2
