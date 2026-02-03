.PHONY: help build test test-unit test-e2e clean redis-start redis-stop redis-logs redis-clean profile lint format

# Default target
help:
	@echo "Available targets:"
	@echo "  make build          - Build the project with cabal"
	@echo "  make test           - Run all tests (unit + e2e)"
	@echo "  make test-unit      - Run unit tests only"
	@echo "  make test-e2e       - Run end-to-end tests with Docker"
	@echo "  make redis-start    - Start Redis using Docker Compose (full setup with TLS)"
	@echo "  make redis-stop     - Stop Docker Compose Redis"
	@echo "  make redis-logs     - View Docker Compose Redis logs"
	@echo "  make redis-clean    - Stop Redis and remove volumes"
	@echo "  make profile        - Build with profiling enabled"
	@echo "  make clean          - Clean build artifacts"
	@echo ""
	@echo "Example workflows:"
	@echo "  1. Local development with Docker Compose:"
	@echo "     make redis-start    # Start Redis (full setup)"
	@echo "     make build          # Build the project"
	@echo "     make test-unit      # Run unit tests"
	@echo "     make redis-stop     # Stop Redis when done"
	@echo ""
	@echo "  2. Quick Redis with script (simpler, no TLS):"
	@echo "     ./start-redis-local.sh  # Quick Redis container"
	@echo "     make build"
	@echo "     make test-unit"
	@echo "     ./stop-redis-local.sh"
	@echo ""
	@echo "  3. Full test suite:"
	@echo "     make test           # Runs all tests"

# Build the project
build:
	cabal build

# Run all tests
test: test-unit test-e2e

# Run unit tests (RespSpec)
test-unit:
	cabal test RespSpec

# Run end-to-end tests with Docker
test-e2e:
	./rune2eTests.sh

# Start Redis locally with Docker Compose
redis-start:
	@echo "Starting Redis with Docker Compose..."
	@docker compose up -d redis
	@echo "Waiting for Redis to be ready..."
	@sleep 2
	@echo "Redis is running at localhost:6379"
	@echo "Use 'make redis-logs' to view logs"
	@echo "Use 'make redis-stop' to stop Redis"

# Stop Redis
redis-stop:
	@echo "Stopping Redis..."
	@docker compose stop redis

# View Redis logs
redis-logs:
	docker compose logs -f redis

# Stop Redis and remove volumes
redis-clean:
	@echo "Stopping Redis and cleaning up..."
	@docker compose down -v
	@echo "Redis stopped and volumes removed"

# Build with profiling enabled
profile:
	cabal build --enable-profiling

# Clean build artifacts
clean:
	cabal clean
	rm -f *.hp *.prof *.ps *.aux *.stat
	rm -rf dist-newstyle

# Quick development cycle: build and run unit tests
dev: build test-unit
