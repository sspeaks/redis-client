#! /usr/bin/env nix-shell
#! nix-shell -i bash -p redis

set -e

echo "Starting Redis Cluster E2E Tests..."

# Navigate to docker-cluster directory
cd docker-cluster

# Start the cluster
echo "Starting Redis cluster nodes..."
docker-compose up -d

# Wait for nodes to be ready
echo "Waiting for Redis nodes to be ready..."
sleep 5

# Create the cluster
echo "Creating Redis cluster..."
./make_cluster.sh || {
    echo "Cluster creation failed. Cleaning up..."
    docker-compose down
    exit 1
}

# Give cluster time to stabilize
echo "Waiting for cluster to stabilize..."
sleep 3

# Verify cluster is up
echo "Verifying cluster status..."
redis-cli -p 6379 cluster info | grep "cluster_state:ok" || {
    echo "Cluster is not in OK state. Dumping cluster info:"
    redis-cli -p 6379 cluster info
    docker-compose down
    exit 1
}

# Go back to root directory
cd ..

# Build the Docker image
echo "Building cluster E2E test Docker image..."
nix-build e2eClusterDockerImg.nix || {
    echo "Failed to build Docker image"
    cd docker-cluster
    docker-compose down
    exit 1
}

# Load the Docker image
echo "Loading cluster E2E test Docker image..."
docker load < result

# Run the cluster E2E tests in Docker
echo "Running cluster E2E tests in Docker container..."
docker run --network=host clusterE2eTests:latest || {
    EXIT_CODE=$?
    echo "Tests failed with exit code $EXIT_CODE"
    cd docker-cluster
    docker-compose down
    # Clean up docker image
    docker rmi $(docker images "clusterE2eTests:*" -q) 2>/dev/null || true
    rm -f result
    exit $EXIT_CODE
}

# Cleanup
echo "Cleaning up..."
cd docker-cluster
docker-compose down
cd ..
docker rmi $(docker images "clusterE2eTests:*" -q) 2>/dev/null || true
rm -f result

echo "Cluster E2E tests completed successfully!"
