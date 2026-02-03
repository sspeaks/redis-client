#!/bin/bash

# Script to start a local Redis instance for development and testing
# This is a simpler alternative to using docker-compose for quick testing

set -e

REDIS_CONTAINER_NAME="redis-client-dev"
REDIS_PORT="${REDIS_PORT:-6379}"

echo "Starting local Redis container for development..."
echo "Container name: $REDIS_CONTAINER_NAME"
echo "Port: $REDIS_PORT"

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER_NAME}$"; then
    echo "Container $REDIS_CONTAINER_NAME already exists"
    
    # Check if it's running
    if docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER_NAME}$"; then
        echo "Redis is already running!"
        echo "Access it at: localhost:$REDIS_PORT"
        exit 0
    else
        echo "Starting existing container..."
        docker start "$REDIS_CONTAINER_NAME"
        echo "Redis started at: localhost:$REDIS_PORT"
        exit 0
    fi
fi

# Start a new Redis container
echo "Creating and starting new Redis container..."
docker run -d \
    --name "$REDIS_CONTAINER_NAME" \
    -p "$REDIS_PORT:6379" \
    redis:latest

echo ""
echo "✓ Redis is now running!"
echo "  Access at: localhost:$REDIS_PORT"
echo ""
echo "Useful commands:"
echo "  Stop Redis:    docker stop $REDIS_CONTAINER_NAME"
echo "  Start Redis:   docker start $REDIS_CONTAINER_NAME"
echo "  Remove Redis:  docker rm -f $REDIS_CONTAINER_NAME"
echo "  View logs:     docker logs -f $REDIS_CONTAINER_NAME"
echo ""
echo "Or use the Makefile:"
echo "  make redis-start"
echo "  make redis-stop"
echo "  make redis-logs"
