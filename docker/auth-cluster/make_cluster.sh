#! /usr/bin/env nix-shell
#! nix-shell -i bash -p redis

set -Eeuo pipefail

DEFAULT_PASSWORD="redis-client-e2e-password"
NODES=(
  "auth-redis1:6379"
  "auth-redis2:6380"
  "auth-redis3:6381"
)

check_node_ready() {
  local service=$1
  local port=$2

  for attempt in $(seq 1 20); do
    if docker compose exec -T \
      -e REDISCLI_AUTH="$DEFAULT_PASSWORD" \
      "$service" redis-cli -p "$port" ping 2>/dev/null |
      grep -q "PONG"; then
      return 0
    fi
    echo "Waiting for $service to accept authenticated connections ($attempt/20)..."
    sleep 1
  done

  echo "Error: $service did not become ready." >&2
  return 1
}

check_node_ready auth-redis1 6379
check_node_ready auth-redis2 6380
check_node_ready auth-redis3 6381

docker compose exec -T \
  -e REDISCLI_AUTH="$DEFAULT_PASSWORD" \
  auth-redis1 redis-cli --cluster create "${NODES[@]}" --cluster-yes >/dev/null

for attempt in $(seq 1 20); do
  if docker compose exec -T \
    -e REDISCLI_AUTH="$DEFAULT_PASSWORD" \
    auth-redis1 redis-cli -p 6379 cluster info 2>/dev/null |
    grep -q "cluster_state:ok"; then
    echo "Authenticated Redis cluster is ready."
    exit 0
  fi
  echo "Waiting for authenticated cluster state ($attempt/20)..."
  sleep 1
done

echo "Error: authenticated Redis cluster did not reach cluster_state:ok." >&2
exit 1
