#! /usr/bin/env nix-shell
#! nix-shell -i bash -p redis

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker/auth-cluster/docker-compose.yml"
PROJECT_NAME="redis-client-auth-cluster-$$"

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down -v \
    --remove-orphans >/dev/null 2>&1 || true
  docker image rm authenticatedclustere2etests:latest >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/result"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

cd "$SCRIPT_DIR/docker/auth-cluster"
export COMPOSE_PROJECT_NAME="$PROJECT_NAME"

docker compose -f "$COMPOSE_FILE" up -d
./make_cluster.sh

cd "$SCRIPT_DIR"
nix-build nix/authenticated-cluster-e2e-docker.nix
docker load < result >/dev/null

NETWORK_NAME="$(
  docker network ls \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --format "{{.Name}}" |
    head -n 1
)"

if [ -z "$NETWORK_NAME" ]; then
  echo "Error: authenticated cluster network was not found." >&2
  exit 1
fi

docker run --rm --network="$NETWORK_NAME" \
  authenticatedclustere2etests:latest
