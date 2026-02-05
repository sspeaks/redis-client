#! /usr/bin/env nix-shell
#! nix-shell -i bash -p  redis

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

# Create the cluster
echo "Creating Redis cluster..."
redis-cli --cluster create "${NODES[@]}" --cluster-yes

# Check if the cluster creation was successful
if [ $? -eq 0 ]; then
  echo "Redis cluster created successfully!"
else
  echo "Error: Failed to create Redis cluster."
  exit 1
fi