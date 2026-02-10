#! /usr/bin/env nix-shell
#! nix-shell -i bash -p redis

set -e

echo "Starting Redis Cluster E2E Tests..."

# Navigate to docker-cluster directory
cd docker-cluster

# Start the cluster
echo "Starting Redis cluster nodes..."
docker compose up -d

# Wait for nodes to be ready
echo "Waiting for Redis nodes to be ready..."
sleep 5

# Create the cluster
echo "Creating Redis cluster..."
./make_cluster.sh || {
    echo "Cluster creation failed. Cleaning up..."
    docker compose down
    exit 1
}

# Give cluster time to stabilize and verify it's ready
echo "Waiting for cluster to stabilize..."
MAX_RETRIES=10
RETRY_COUNT=0
CLUSTER_READY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  sleep 2
  
  # Check cluster state
  if redis-cli -p 6379 cluster info | grep -q "cluster_state:ok"; then
    echo "Cluster is ready!"
    CLUSTER_READY=true
    break
  fi
  
  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "Cluster not ready yet (attempt $RETRY_COUNT/$MAX_RETRIES)..."
done

if [ "$CLUSTER_READY" = false ]; then
  echo "ERROR: Cluster failed to reach 'ok' state after $MAX_RETRIES attempts"
  echo "Cluster info:"
  redis-cli -p 6379 cluster info
  echo ""
  echo "Cluster nodes:"
  redis-cli -p 6379 cluster nodes
  docker compose down
  exit 1
fi

# Go back to root directory
cd ..

# Build the Docker image
echo "Building cluster E2E test Docker image..."
nix-build nix/cluster-e2e-docker.nix || {
    echo "Failed to build Docker image"
    cd docker-cluster
    docker compose down
    exit 1
}

# Load the Docker image
echo "Loading cluster E2E test Docker image..."
docker load < result

# Get the actual network name created by docker compose
# Docker compose prefixes the network name with the project name (usually the directory name)
NETWORK_NAME=$(docker network ls --filter name=redis-cluster-net --format "{{.Name}}" | grep -E 'redis-cluster-net$' | head -n 1)

if [ -z "$NETWORK_NAME" ]; then
  echo "Error: Could not find redis-cluster-net network"
  cd docker-cluster
  docker compose down
  exit 1
fi

# Run the cluster E2E tests in Docker on the same network as the cluster
echo "Running cluster E2E tests in Docker container on network $NETWORK_NAME..."
docker run --network="$NETWORK_NAME" clustere2etests:latest  || {
    EXIT_CODE=$?
    echo "Tests failed with exit code $EXIT_CODE"
    cd docker-cluster
    docker compose down
    # Clean up docker image
    docker rmi $(docker images "clustere2etests:*" -q) 2>/dev/null || true
    rm -f result
    exit $EXIT_CODE
}

# Cleanup
echo "Cleaning up..."
cd docker-cluster
docker compose down
cd ..
docker rmi $(docker images "clustere2etests:*" -q) 2>/dev/null || true
rm -f result

echo "Cluster E2E tests completed successfully!"
