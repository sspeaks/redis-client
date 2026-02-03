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

# Go back to root directory
cd ..

# Build the test executable
echo "Building ClusterEndToEnd test executable..."
cabal build ClusterEndToEnd

# Run the cluster E2E tests
echo "Running cluster E2E tests..."
cabal run ClusterEndToEnd || {
    EXIT_CODE=$?
    echo "Tests failed with exit code $EXIT_CODE"
    cd docker-cluster
    docker-compose down
    exit $EXIT_CODE
}

# Cleanup
echo "Cleaning up..."
cd docker-cluster
docker-compose down

echo "Cluster E2E tests completed successfully!"
