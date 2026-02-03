#!/bin/bash

# Script to stop the local Redis instance for development

set -e

REDIS_CONTAINER_NAME="redis-client-dev"

echo "Stopping local Redis container..."

if ! docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER_NAME}$"; then
    echo "Redis container is not running"
    exit 0
fi

docker stop "$REDIS_CONTAINER_NAME"
echo "✓ Redis container stopped"
echo ""
echo "To start again: ./start-redis-local.sh or make redis-start"
echo "To remove completely: docker rm $REDIS_CONTAINER_NAME"
