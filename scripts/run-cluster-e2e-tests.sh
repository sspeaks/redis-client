#! /usr/bin/env nix-shell
#! nix-shell -i bash -p redis

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker/cluster-e2e/docker-compose.yml"
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

  while [[ "$attempts" -lt 10 ]]; do
    candidate="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$candidate" =~ ^[0-9a-f]{32}$ ]]; then
      RUN_TOKEN="$candidate"
      PROJECT_NAME="redis-client-cluster-e2e-$RUN_TOKEN"
      E2E_IMAGE_NAME="redis-client-cluster-e2e-tests-$RUN_TOKEN"
      E2E_IMAGE="$E2E_IMAGE_NAME:$E2E_IMAGE_TAG"
      COMPOSE=(docker compose --project-name "$PROJECT_NAME" --file "$COMPOSE_FILE")
      return 0
    fi
    attempts=$((attempts + 1))
  done

  echo "Error: failed to reserve a unique cluster E2E ownership token." >&2
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
    echo "Error: cluster E2E image identity already exists; refusing to adopt it." >&2
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
    echo "Error: cluster E2E Compose identity already exists; refusing to adopt it." >&2
    return 1
  fi

  COMPOSE_OWNERSHIP_ESTABLISHED=1
}

diagnostics() {
  echo "Cluster E2E diagnostics for project $PROJECT_NAME:"
  "${COMPOSE[@]}" ps || true
  for node in redis1 redis2 redis3 redis4 redis5 redis6; do
    echo "--- $node ---"
    "${COMPOSE[@]}" logs --no-color "$node" || true
  done
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

  if [[ "$primary_status" -ne 0 && "$COMPOSE_OWNERSHIP_ESTABLISHED" -eq 1 ]]; then
    diagnostics
  fi

  if [[ "$COMPOSE_OWNERSHIP_ESTABLISHED" -eq 1 ]]; then
    "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1
    command_status=$?
    if [[ "$command_status" -ne 0 ]]; then
      echo "Warning: failed to stop the cluster E2E Compose project (exit $command_status)." >&2
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
      echo "Warning: failed to discover the cluster E2E image (exit $command_status)." >&2
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
          echo "Warning: refusing to remove a cluster E2E image with mismatched ownership." >&2
          if [[ "$cleanup_status" -eq 0 ]]; then
            cleanup_status=1
          fi
          continue
        fi
        docker image rm "$image_id" >/dev/null 2>&1
        command_status=$?
        if [[ "$command_status" -ne 0 ]]; then
          echo "Warning: failed to remove the cluster E2E image (exit $command_status)." >&2
          if [[ "$cleanup_status" -eq 0 ]]; then
            cleanup_status=$command_status
          fi
        fi
      done <<<"$image_ids"
    fi
  fi

  if [[ "$primary_status" -ne 0 ]]; then
    exit "$primary_status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_for_healthy_nodes() {
  for attempt in $(seq 1 30); do
    healthy=0
    for node in redis1 redis2 redis3 redis4 redis5 redis6; do
      status=$("${COMPOSE[@]}" ps --format json "$node" 2>/dev/null | \
        sed -n 's/.*"Health":"\([^"]*\)".*/\1/p')
      [ "$status" = "healthy" ] && healthy=$((healthy + 1))
    done
    [ "$healthy" -eq 6 ] && return 0
    sleep 1
  done
  return 1
}

wait_for_cluster() {
  for attempt in $(seq 1 30); do
    if "${COMPOSE[@]}" exec -T redis1 redis-cli -p 6379 cluster info 2>/dev/null | \
        grep -q '^cluster_state:ok'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

reserve_run_identity
assert_image_identity_available

echo "Building isolated cluster E2E image..."
image_archive="$(
  cd "$SCRIPT_DIR"
  nix-build --no-out-link nix/cluster-e2e-docker.nix \
    --argstr imageName "$E2E_IMAGE_NAME" \
    --argstr imageTag "$E2E_IMAGE_TAG" \
    --argstr imageOwner "$RUN_TOKEN"
)"
docker load <"$image_archive"

loaded_owner="$(
  docker image inspect \
    --format '{{ index .Config.Labels "com.redis-client.e2e.owner" }}' \
    "$E2E_IMAGE"
)"
if [[ "$loaded_owner" != "$RUN_TOKEN" ]]; then
  echo "Error: loaded cluster E2E image has unexpected ownership." >&2
  exit 1
fi

assert_compose_identity_available
echo "Starting isolated Redis 7.2 six-node Cluster E2E fixture ($PROJECT_NAME)..."
"${COMPOSE[@]}" up --detach
if ! wait_for_healthy_nodes; then
  echo "Error: cluster nodes did not become healthy." >&2
  exit 1
fi

echo "Creating three-primary, three-replica cluster..."
"${COMPOSE[@]}" exec -T redis1 redis-cli --cluster create --cluster-replicas 1 --cluster-yes \
  redis1.local:6379 redis2.local:6380 redis3.local:6381 \
  redis4.local:6382 redis5.local:6383 redis6.local:6384
if ! wait_for_cluster; then
  echo "Error: cluster did not reach cluster_state:ok." >&2
  exit 1
fi

NETWORK_NAME="${PROJECT_NAME}_default"
network_owner="$(
  docker network inspect \
    --format '{{ index .Labels "com.docker.compose.project" }}' \
    "$NETWORK_NAME"
)"
if [[ "$network_owner" != "$PROJECT_NAME" ]]; then
  echo "Error: cluster E2E network has unexpected ownership." >&2
  exit 1
fi

echo "Running cluster E2E tests on $NETWORK_NAME..."
docker run --rm --network "$NETWORK_NAME" "$E2E_IMAGE"
echo "Cluster E2E tests completed successfully."
