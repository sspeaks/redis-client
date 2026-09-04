#! /usr/bin/env nix-shell
#! nix-shell -p bash openssl coreutils -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/standalone/docker-compose.yml"
TLS_RUNTIME_ROOT="$REPO_ROOT/docker/standalone/.runtime"
TLS_CERT_DIR=""
RUN_STATE_DIR=""
RUN_TOKEN=""
PROJECT_NAME=""
E2E_IMAGE_NAME=""
E2E_IMAGE_TAG="latest"
E2E_IMAGE=""
IMAGE_OWNER_LABEL="com.redis-client.e2e.owner"
IMAGE_OWNERSHIP_ESTABLISHED=0
COMPOSE_OWNERSHIP_ESTABLISHED=0

reserve_run_identity() {
  local candidate
  local attempts=0

  umask 077
  mkdir -p "$TLS_RUNTIME_ROOT"
  chmod 700 "$TLS_RUNTIME_ROOT"

  while [[ "$attempts" -lt 10 ]]; do
    candidate="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$candidate" =~ ^[0-9a-f]{32}$ ]] \
      && mkdir "$TLS_RUNTIME_ROOT/run.$candidate" 2>/dev/null; then
      RUN_TOKEN="$candidate"
      RUN_STATE_DIR="$TLS_RUNTIME_ROOT/run.$candidate"
      PROJECT_NAME="redis-client-standalone-e2e-$RUN_TOKEN"
      E2E_IMAGE_NAME="redis-client-e2e-tests-$RUN_TOKEN"
      E2E_IMAGE="$E2E_IMAGE_NAME:$E2E_IMAGE_TAG"
      return 0
    fi
    attempts=$((attempts + 1))
  done

  echo "Error: failed to reserve a unique standalone E2E ownership token." >&2
  return 1
}

assert_image_identity_available() {
  local owned_images

  owned_images="$(
    docker image ls --quiet --no-trunc \
      --filter "label=$IMAGE_OWNER_LABEL=$RUN_TOKEN"
  )"
  if [[ -n "$owned_images" ]] \
    || docker image inspect "$E2E_IMAGE" >/dev/null 2>&1; then
    echo "Error: standalone E2E image identity already exists; refusing to adopt it." >&2
    return 1
  fi

  IMAGE_OWNERSHIP_ESTABLISHED=1
}

assert_compose_identity_available() {
  local project_filter="label=com.docker.compose.project=$PROJECT_NAME"
  local containers
  local networks
  local volumes

  containers="$(docker container ls --all --quiet --filter "$project_filter")"
  networks="$(docker network ls --quiet --filter "$project_filter")"
  volumes="$(docker volume ls --quiet --filter "$project_filter")"
  if [[ -n "$containers" || -n "$networks" || -n "$volumes" ]]; then
    echo "Error: standalone E2E Compose identity already exists; refusing to adopt it." >&2
    return 1
  fi

  COMPOSE_OWNERSHIP_ESTABLISHED=1
}

cleanup() {
  local primary_status=$?
  local cleanup_status=0
  local command_status
  local image_ids
  local image_owner
  local image_id

  trap - EXIT INT TERM HUP
  set +e

  if [[ "$COMPOSE_OWNERSHIP_ESTABLISHED" -eq 1 ]]; then
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down \
      >/dev/null 2>&1
    command_status=$?
    if [[ "$command_status" -ne 0 ]]; then
      echo "Warning: failed to stop the standalone E2E Compose project (exit $command_status)." >&2
      cleanup_status=$command_status
    fi
  fi

  if [[ "$IMAGE_OWNERSHIP_ESTABLISHED" -eq 1 ]]; then
    image_ids="$(
      docker image ls --quiet --no-trunc \
        --filter "label=$IMAGE_OWNER_LABEL=$RUN_TOKEN" 2>/dev/null
    )"
    command_status=$?
    if [[ "$command_status" -ne 0 ]]; then
      echo "Warning: failed to discover the standalone E2E image (exit $command_status)." >&2
      if [[ "$cleanup_status" -eq 0 ]]; then
        cleanup_status=$command_status
      fi
    else
      while IFS= read -r image_id; do
        [[ -z "$image_id" ]] && continue
        image_owner="$(
          docker image inspect \
            --format '{{ index .Config.Labels "com.redis-client.e2e.owner" }}' \
            "$image_id" 2>/dev/null
        )"
        command_status=$?
        if [[ "$command_status" -ne 0 ]]; then
          continue
        fi
        if [[ "$image_owner" != "$RUN_TOKEN" ]]; then
          echo "Warning: refusing to remove a standalone E2E image with mismatched ownership." >&2
          if [[ "$cleanup_status" -eq 0 ]]; then
            cleanup_status=1
          fi
          continue
        fi
        docker image rm "$image_id" >/dev/null 2>&1
        command_status=$?
        if [[ "$command_status" -ne 0 ]]; then
          echo "Warning: failed to remove the standalone E2E image (exit $command_status)." >&2
          if [[ "$cleanup_status" -eq 0 ]]; then
            cleanup_status=$command_status
          fi
        fi
      done <<<"$image_ids"
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

  if [[ -n "$RUN_STATE_DIR" ]]; then
    rmdir "$RUN_STATE_DIR" 2>/dev/null
    command_status=$?
    if [[ "$command_status" -ne 0 ]]; then
      echo "Warning: failed to release the standalone E2E ownership token (exit $command_status)." >&2
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

reserve_run_identity

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
    --argstr imageOwner "$RUN_TOKEN" \
    nix/e2e-docker.nix
)"

assert_image_identity_available
docker load <"$image_archive"

loaded_owner="$(
  docker image inspect \
    --format '{{ index .Config.Labels "com.redis-client.e2e.owner" }}' \
    "$E2E_IMAGE"
)"
if [[ "$loaded_owner" != "$RUN_TOKEN" ]]; then
  echo "Error: loaded standalone E2E image has unexpected ownership." >&2
  exit 1
fi

assert_compose_identity_available
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" \
  up --exit-code-from e2etests
