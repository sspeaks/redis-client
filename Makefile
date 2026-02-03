# Agent testing infrastructure
# First-time setup: make setup
# Then: make build && make test-unit

# Detect if nix-shell is available
HAS_NIX := $(shell command -v nix-shell >/dev/null 2>&1 && echo yes || echo no)

.PHONY: help build test test-unit test-e2e clean redis-start redis-stop profile setup

# Default target
help:
	@echo "Targets: setup build test test-unit test-e2e redis-start redis-stop profile clean"

# Setup dependencies (run once in new environment)
setup:
ifeq ($(HAS_NIX),yes)
	@echo "Using Nix for dependency management"
	nix-shell --run "cabal update"
else
	@echo "Nix not found, using system package manager"
	cabal update
	sudo apt-get update && sudo apt-get install -y libreadline-dev || true
endif

# Build the project
build:
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal build"
else
	cabal build
endif

# Run all tests
test: test-unit test-e2e

# Run unit tests (RespSpec)
test-unit:
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal test RespSpec"
else
	cabal test RespSpec
endif

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
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal build --enable-profiling"
else
	cabal build --enable-profiling
endif

# Clean build artifacts
clean:
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal clean"
else
	cabal clean
endif
	rm -f *.hp *.prof *.ps *.aux *.stat
	rm -rf dist-newstyle
