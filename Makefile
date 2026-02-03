# Agent testing infrastructure
# First-time setup: make setup
# Then: make build && make test-unit

.PHONY: help build test test-unit test-e2e clean redis-start redis-stop profile setup

# Default target
help:
	@echo "Targets: setup build test test-unit test-e2e redis-start redis-stop profile clean"

# Setup dependencies (run once in new environment)
setup:
	@if command -v nix-shell >/dev/null 2>&1; then \
		echo "Using Nix for dependency management"; \
		nix-shell --run "cabal update"; \
	else \
		echo "Nix not found, using system package manager"; \
		cabal update; \
		sudo apt-get update && sudo apt-get install -y libreadline-dev || true; \
	fi

# Build the project
build:
	@if command -v nix-shell >/dev/null 2>&1; then \
		nix-shell --run "cabal build"; \
	else \
		cabal build; \
	fi

# Run all tests
test: test-unit test-e2e

# Run unit tests (RespSpec)
test-unit:
	@if command -v nix-shell >/dev/null 2>&1; then \
		nix-shell --run "cabal test RespSpec"; \
	else \
		cabal test RespSpec; \
	fi

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
	@if command -v nix-shell >/dev/null 2>&1; then \
		nix-shell --run "cabal build --enable-profiling"; \
	else \
		cabal build --enable-profiling; \
	fi

# Clean build artifacts
clean:
	@if command -v nix-shell >/dev/null 2>&1; then \
		nix-shell --run "cabal clean"; \
	else \
		cabal clean; \
	fi
	rm -f *.hp *.prof *.ps *.aux *.stat
	rm -rf dist-newstyle
