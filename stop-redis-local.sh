#!/bin/bash
# Stop the Redis container

set -e

REDIS_CONTAINER_NAME="redis-client-dev"

if ! docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER_NAME}$"; then
    echo "Redis container not running"
    exit 0
fi

docker stop "$REDIS_CONTAINER_NAME"
echo "Redis stopped"
