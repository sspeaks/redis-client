#! /usr/bin/env nix-shell
#! nix-shell -p bash coreutils -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/standalone/docker-compose.yml"
TLS_RUNTIME_ROOT="$REPO_ROOT/docker/standalone/.runtime"
STATE_FILE="$TLS_RUNTIME_ROOT/standalone-cert-dir"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: no generated standalone Redis TLS state was found." >&2
  exit 1
fi

TLS_CERT_DIR="$(<"$STATE_FILE")"
case "$TLS_CERT_DIR" in
  "$TLS_RUNTIME_ROOT"/tls.*) ;;
  *)
    echo "Error: refusing to remove unexpected TLS credential path '$TLS_CERT_DIR'." >&2
    exit 1
    ;;
esac

export REDIS_TLS_CERT_DIR="$TLS_CERT_DIR"
export REDIS_TLS_CERT_UID
export REDIS_TLS_CERT_GID
REDIS_TLS_CERT_UID="$(id -u)"
REDIS_TLS_CERT_GID="$(id -g)"

status=0
docker compose -f "$COMPOSE_FILE" down || status=$?
rm -rf -- "$TLS_CERT_DIR"
rm -f "$STATE_FILE"
rmdir "$TLS_RUNTIME_ROOT" 2>/dev/null || true
exit "$status"
