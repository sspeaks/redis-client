.PHONY: help build test test-unit test-e2e clean redis-start redis-stop profile

# Default target
help:
	@echo "Targets: build test test-unit test-e2e redis-start redis-stop profile clean"

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

# Start Redis with Docker Compose
redis-start:
	@docker compose up -d redis
	@sleep 2

# Stop Redis
redis-stop:
	@docker compose stop redis

# Build with profiling enabled
profile:
	cabal build --enable-profiling

# Clean build artifacts
clean:
	cabal clean
	rm -f *.hp *.prof *.ps *.aux *.stat
	rm -rf dist-newstyle
