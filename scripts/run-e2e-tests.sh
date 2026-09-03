#! /usr/bin/env nix-shell
#! nix-shell -p bash openssl -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/standalone/docker-compose.yml"
TLS_RUNTIME_ROOT="$REPO_ROOT/docker/standalone/.runtime"
TLS_CERT_DIR=""
COMPOSE_STARTED=0

cleanup() {
  local status=$?
  local image_ids

  trap - EXIT INT TERM HUP
  set +e

  if [[ "$COMPOSE_STARTED" -eq 1 ]]; then
    docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1
  fi

  image_ids="$(docker images "e2etests:*" -q 2>/dev/null)"
  if [[ -n "$image_ids" ]]; then
    # shellcheck disable=SC2086
    docker rmi $image_ids >/dev/null 2>&1
  fi

  rm -f "$REPO_ROOT/result"
  if [[ -n "$TLS_CERT_DIR" ]]; then
    rm -rf -- "$TLS_CERT_DIR"
  fi
  rmdir "$TLS_RUNTIME_ROOT" 2>/dev/null

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

cd "$REPO_ROOT"

if ! TLS_CERT_DIR="$("$SCRIPT_DIR/generate-test-tls-certs.sh" "$TLS_RUNTIME_ROOT")"; then
  echo "Error: failed to generate ephemeral TLS credentials for standalone E2E tests." >&2
  exit 1
fi

export REDIS_TLS_CERT_DIR="$TLS_CERT_DIR"
export REDIS_TLS_CERT_UID
export REDIS_TLS_CERT_GID
REDIS_TLS_CERT_UID="$(id -u)"
REDIS_TLS_CERT_GID="$(id -g)"

# shellcheck disable=SC2046
docker load <$(nix-build nix/e2e-docker.nix)
COMPOSE_STARTED=1
docker compose -f "$COMPOSE_FILE" up --exit-code-from e2etests
