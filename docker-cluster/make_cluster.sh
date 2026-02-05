#! /usr/bin/env nix-shell
#! nix-shell -i bash -p  redis
#
# Script to create a Redis cluster from Docker containers.
# This script:
# 1. Starts Redis containers via docker compose
# 2. Waits for all nodes to be ready
# 3. Resets any stale cluster state (fixes hanging issues)
# 4. Creates the cluster with a 60-second timeout
#
# If cluster creation hangs, run: docker compose down -v

docker compose up -d

# Define the Redis nodes
NODES=(
  "localhost:6379"
  "localhost:6380"
  "localhost:6381"
  "localhost:6382"
  "localhost:6383"
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

# Wait for all nodes to be ready
for node in "${NODES[@]}"; do
  check_node_ready "$node" || exit 1
done

# Reset cluster state on all nodes to avoid stale configuration issues
echo "Resetting cluster state on all nodes..."
for node in "${NODES[@]}"; do
  host="${node%:*}"
  port="${node#*:}"
  echo "Resetting cluster on $node..."
  redis-cli -h "$host" -p "$port" CLUSTER RESET SOFT 2>/dev/null || true
done

# Give nodes a moment to reset (allows cluster state to fully clear)
sleep 2

# Create the cluster with a timeout
echo "Creating Redis cluster..."
if timeout 60 redis-cli --cluster create "${NODES[@]}" --cluster-yes; then
  echo "Redis cluster created successfully!"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "Error: Cluster creation timed out after 60 seconds."
    echo "This usually indicates a networking or configuration issue."
    echo "Try running 'docker compose down -v' to clean up volumes and retry."
  else
    echo "Error: Failed to create Redis cluster (exit code: $EXIT_CODE)."
  fi
  exit 1
fi