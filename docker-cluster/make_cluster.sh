#! /usr/bin/env nix-shell
#! nix-shell -i bash -p  redis
#
# Script to create a Redis cluster from Docker containers using bridge networking.
# This script:
# 1. Starts Redis containers via docker compose
# 2. Waits for all nodes to be ready (checking from host via mapped ports)
# 3. Resets any stale cluster state
# 4. Creates the cluster using container hostnames from within the Docker network
#
# If cluster creation hangs, run: docker compose down -v

docker compose up -d

# Define the Redis nodes for external access (via mapped ports)
EXTERNAL_NODES=(
  "localhost:6379"
  "localhost:6380"
  "localhost:6381"
  "localhost:6382"
  "localhost:6383"
)

# Define the Redis nodes for cluster creation (internal container hostnames)
CLUSTER_NODES=(
  "redis1:6379"
  "redis2:6380"
  "redis3:6381"
  "redis4:6382"
  "redis5:6383"
)

# Function to check if a Redis node is ready
check_node_ready() {
  local node=$1
  local retries=10
  local delay=2

  for ((i=1; i<=retries; i++)); do
    if redis-cli -h "${node%:*}" -p "${node#*:}" ping | grep -q "PONG"; then
      echo "Node $node is ready."
      return 0
    else
      echo "Waiting for node $node to be ready... ($i/$retries)"
      sleep $delay
    fi
  done

  echo "Error: Node $node is not ready after $retries attempts."
  return 1
}

# Wait for all nodes to be ready (check from host)
for node in "${EXTERNAL_NODES[@]}"; do
  check_node_ready "$node" || exit 1
done

# Reset cluster state on all nodes to avoid stale configuration issues
echo "Resetting cluster state on all nodes..."
for node in "${EXTERNAL_NODES[@]}"; do
  host="${node%:*}"
  port="${node#*:}"
  echo "Resetting cluster on $node..."
  redis-cli -h "$host" -p "$port" CLUSTER RESET SOFT 2>/dev/null || true
done

# Give nodes a moment to reset (allows cluster state to fully clear)
sleep 2

# Get the actual network name created by docker compose
NETWORK_NAME=$(docker network ls --filter name=redis-cluster-net --format "{{.Name}}" | head -n 1)

if [ -z "$NETWORK_NAME" ]; then
  echo "Error: Could not find redis-cluster-net network. Is docker compose running?"
  exit 1
fi

# Create the cluster with a timeout using a container in the same network
# This allows the cluster nodes to communicate using their container hostnames
echo "Creating Redis cluster using container hostnames..."
if timeout 120 docker run --rm --network "$NETWORK_NAME" redis redis-cli \
  --cluster create "${CLUSTER_NODES[@]}" --cluster-yes; then
  echo "Redis cluster created successfully!"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "Error: Cluster creation timed out after 120 seconds."
    echo "This usually indicates a networking or configuration issue."
    echo "Try running 'docker compose down -v' to clean up volumes and retry."
  else
    echo "Error: Failed to create Redis cluster (exit code: $EXIT_CODE)."
  fi
  exit 1
fi