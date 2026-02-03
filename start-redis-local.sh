#!/bin/bash
# Start a simple Redis container for testing

set -e

REDIS_CONTAINER_NAME="redis-client-dev"
REDIS_PORT="${REDIS_PORT:-6379}"

# Check if container already exists and is running
if docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER_NAME}$"; then
    echo "Redis already running at localhost:$REDIS_PORT"
    exit 0
fi

# Check if container exists but stopped
if docker ps -a --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER_NAME}$"; then
    docker start "$REDIS_CONTAINER_NAME"
    echo "Redis started at localhost:$REDIS_PORT"
    exit 0
fi

# Start a new Redis container
docker run -d --name "$REDIS_CONTAINER_NAME" -p "$REDIS_PORT:6379" redis:latest
echo "Redis started at localhost:$REDIS_PORT"
