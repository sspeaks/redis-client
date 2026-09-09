#! /usr/bin/env nix-shell
#! nix-shell -p bash openssl coreutils redis gnugrep -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/direct-tls-e2e/docker-compose.yml"
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
COMPOSE=()

reserve_run_identity() {
  local candidate
  local attempts=0

  umask 077
  mkdir -p "$TLS_RUNTIME_ROOT"
  chmod 700 "$TLS_RUNTIME_ROOT"
  while [[ "$attempts" -lt 10 ]]; do
    candidate="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$candidate" =~ ^[0-9a-f]{32}$ ]] \
      && mkdir "$TLS_RUNTIME_ROOT/direct-tls.$candidate" 2>/dev/null; then
      RUN_TOKEN="$candidate"
      RUN_STATE_DIR="$TLS_RUNTIME_ROOT/direct-tls.$candidate"
      PROJECT_NAME="redis-client-direct-tls-e2e-$RUN_TOKEN"
      E2E_IMAGE_NAME="redis-client-direct-tls-e2e-tests-$RUN_TOKEN"
      E2E_IMAGE="$E2E_IMAGE_NAME:$E2E_IMAGE_TAG"
      COMPOSE=(docker compose --project-name "$PROJECT_NAME" --file "$COMPOSE_FILE")
      return 0
    fi
    attempts=$((attempts + 1))
  done
  echo "Error: failed to reserve a unique direct TLS E2E ownership token." >&2
  return 1
}

assert_identities_available() {
  local project_filter="label=com.docker.compose.project=$PROJECT_NAME"
  if docker image inspect "$E2E_IMAGE" >/dev/null 2>&1 \
    || [[ -n "$(docker image ls --quiet --no-trunc --filter "label=$IMAGE_OWNER_LABEL=$RUN_TOKEN")" ]]; then
    echo "Error: direct TLS E2E image identity already exists; refusing to adopt it." >&2
    return 1
  fi
  IMAGE_OWNERSHIP_ESTABLISHED=1
  if [[ -n "$(docker container ls --all --quiet --filter "$project_filter")" ]] \
    || [[ -n "$(docker network ls --quiet --filter "$project_filter")" ]] \
    || [[ -n "$(docker volume ls --quiet --filter "$project_filter")" ]]; then
    echo "Error: direct TLS E2E Compose identity already exists; refusing to adopt it." >&2
    return 1
  fi
  COMPOSE_OWNERSHIP_ESTABLISHED=1
}

cleanup() {
  local primary_status=$?
  local cleanup_status=0
  local command_status
  local image_id

  trap - EXIT INT TERM HUP
  set +e

  if [[ "$COMPOSE_OWNERSHIP_ESTABLISHED" -eq 1 ]]; then
    "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1
    command_status=$?
    [[ "$command_status" -eq 0 ]] || cleanup_status=$command_status
  fi

  if [[ "$IMAGE_OWNERSHIP_ESTABLISHED" -eq 1 ]]; then
    while IFS= read -r image_id; do
      [[ -z "$image_id" ]] && continue
      docker image rm "$image_id" >/dev/null 2>&1
      command_status=$?
      [[ "$command_status" -eq 0 ]] || cleanup_status=$command_status
    done < <(docker image ls --quiet --no-trunc \
      --filter "label=$IMAGE_OWNER_LABEL=$RUN_TOKEN" 2>/dev/null)
  fi

  if [[ -n "$TLS_CERT_DIR" ]]; then
    rm -rf -- "$TLS_CERT_DIR"
    command_status=$?
    [[ "$command_status" -eq 0 ]] || cleanup_status=$command_status
  fi
  if [[ -n "$RUN_STATE_DIR" ]]; then
    rmdir "$RUN_STATE_DIR" 2>/dev/null
    command_status=$?
    [[ "$command_status" -eq 0 ]] || cleanup_status=$command_status
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

wait_for_healthy_services() {
  local service
  local status
  local healthy
  for _ in $(seq 1 30); do
    healthy=0
    for service in standalone cluster1 cluster2 cluster3; do
      status="$("${COMPOSE[@]}" ps --format json "$service" 2>/dev/null \
        | sed -n 's/.*"Health":"\([^"]*\)".*/\1/p')"
      [[ "$status" == "healthy" ]] && healthy=$((healthy + 1))
    done
    [[ "$healthy" -eq 4 ]] && return 0
    sleep 1
  done
  return 1
}

wait_for_cluster() {
  for _ in $(seq 1 30); do
    if "${COMPOSE[@]}" exec -T cluster1 \
      redis-cli --tls --insecure -h cluster-node1.local -p 6380 cluster info \
      2>/dev/null | grep -q '^cluster_state:ok'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cd "$REPO_ROOT"
reserve_run_identity
TLS_CERT_DIR="$("$SCRIPT_DIR/generate-test-tls-certs.sh" "$RUN_STATE_DIR")"
export REDIS_TLS_CERT_DIR="$TLS_CERT_DIR"
export REDIS_TLS_CERT_UID
export REDIS_TLS_CERT_GID
REDIS_TLS_CERT_UID="$(id -u)"
REDIS_TLS_CERT_GID="$(id -g)"

image_archive="$(
  nix-build --no-out-link nix/direct-tls-e2e-docker.nix \
    --argstr imageName "$E2E_IMAGE_NAME" \
    --argstr imageTag "$E2E_IMAGE_TAG" \
    --argstr imageOwner "$RUN_TOKEN"
)"
assert_identities_available
docker load <"$image_archive"

loaded_owner="$(
  docker image inspect \
    --format '{{ index .Config.Labels "com.redis-client.e2e.owner" }}' \
    "$E2E_IMAGE"
)"
[[ "$loaded_owner" == "$RUN_TOKEN" ]] || {
  echo "Error: loaded direct TLS E2E image has unexpected ownership." >&2
  exit 1
}

"${COMPOSE[@]}" up --detach
if ! wait_for_healthy_services; then
  echo "Error: direct TLS E2E services did not become healthy." >&2
  "${COMPOSE[@]}" ps
  exit 1
fi

timeout 120 "${COMPOSE[@]}" exec -T cluster1 \
  redis-cli --cluster create --cluster-replicas 0 --cluster-yes \
    cluster-node1.local:6379 cluster-node2.local:6379 cluster-node3.local:6379
if ! wait_for_cluster; then
  echo "Error: direct TLS E2E cluster did not reach cluster_state:ok." >&2
  exit 1
fi

network_name="${PROJECT_NAME}_default"
network_owner="$(
  docker network inspect \
    --format '{{ index .Labels "com.docker.compose.project" }}' \
    "$network_name"
)"
[[ "$network_owner" == "$PROJECT_NAME" ]] || {
  echo "Error: direct TLS E2E network has unexpected ownership." >&2
  exit 1
}

docker run --rm \
  --network "$network_name" \
  -v "$TLS_CERT_DIR/redis-ca.crt:/certs/redis-ca.crt:ro" \
  -v "$TLS_CERT_DIR/untrusted-ca.crt:/certs/untrusted-ca.crt:ro" \
  "$E2E_IMAGE"
