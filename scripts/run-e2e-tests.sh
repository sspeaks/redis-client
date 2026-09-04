#! /usr/bin/env nix-shell
#! nix-shell -p bash openssl -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/standalone/docker-compose.yml"
TLS_RUNTIME_ROOT="$REPO_ROOT/docker/standalone/.runtime"
TLS_CERT_DIR=""
RUN_ID="$$"
PROJECT_NAME="redis-client-standalone-e2e-$RUN_ID"
E2E_IMAGE_NAME="redis-client-e2e-tests-$RUN_ID"
E2E_IMAGE_TAG="latest"
E2E_IMAGE="$E2E_IMAGE_NAME:$E2E_IMAGE_TAG"
IMAGE_LOADED=0
COMPOSE_STARTED=0

cleanup() {
  local primary_status=$?
  local cleanup_status=0
  local command_status

  trap - EXIT INT TERM HUP
  set +e

  if [[ "$COMPOSE_STARTED" -eq 1 ]]; then
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down \
      >/dev/null 2>&1
    command_status=$?
    if [[ "$command_status" -ne 0 ]]; then
      echo "Warning: failed to stop the standalone E2E Compose project (exit $command_status)." >&2
      cleanup_status=$command_status
    fi
  fi

  if [[ "$IMAGE_LOADED" -eq 1 ]]; then
    docker image rm "$E2E_IMAGE" >/dev/null 2>&1
    command_status=$?
    if [[ "$command_status" -ne 0 ]]; then
      echo "Warning: failed to remove the standalone E2E image (exit $command_status)." >&2
      if [[ "$cleanup_status" -eq 0 ]]; then
        cleanup_status=$command_status
      fi
    fi
  fi

  if [[ -n "$TLS_CERT_DIR" ]]; then
    rm -rf -- "$TLS_CERT_DIR"
    command_status=$?
    if [[ "$command_status" -ne 0 ]]; then
      echo "Warning: failed to remove standalone E2E TLS credentials (exit $command_status)." >&2
      if [[ "$cleanup_status" -eq 0 ]]; then
        cleanup_status=$command_status
      fi
    fi
  fi
  rmdir "$TLS_RUNTIME_ROOT" 2>/dev/null

  if [[ "$primary_status" -ne 0 ]]; then
    exit "$primary_status"
  fi
  exit "$cleanup_status"
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
export REDIS_E2E_IMAGE="$E2E_IMAGE"
REDIS_TLS_CERT_UID="$(id -u)"
REDIS_TLS_CERT_GID="$(id -g)"

image_archive="$(
  nix-build \
    --no-out-link \
    --argstr imageName "$E2E_IMAGE_NAME" \
    --argstr imageTag "$E2E_IMAGE_TAG" \
    nix/e2e-docker.nix
)"
docker load <"$image_archive"
IMAGE_LOADED=1
COMPOSE_STARTED=1
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" \
  up --exit-code-from e2etests
