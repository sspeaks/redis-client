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
	@if command -v apt-get >/dev/null 2>&1; then \
		echo "Installing libreadline-dev via apt-get (you may be prompted for your password)"; \
		if command -v sudo >/dev/null 2>&1; then \
			sudo apt-get update && sudo apt-get install -y libreadline-dev; \
		else \
			apt-get update && apt-get install -y libreadline-dev; \
		fi; \
	else \
		echo "Error: apt-get not found. Please install 'libreadline-dev' using your system package manager and re-run 'make setup'."; \
		exit 1; \
	fi
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
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "Error: docker is not installed or not in PATH"; \
		exit 1; \
	fi
	@if ! command -v nix-build >/dev/null 2>&1; then \
		echo "Error: nix-build is not installed or not in PATH"; \
		echo "E2E tests require Nix to build the test container image"; \
		exit 1; \
	fi
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
