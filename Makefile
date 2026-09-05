# Agent testing infrastructure
# First-time setup: make setup
# Then: make build && make test-unit

# Detect if nix-shell is available
HAS_NIX := $(shell command -v nix-shell >/dev/null 2>&1 && echo yes || echo no)

.PHONY: help build test test-unit test-metadata test-credentials test-e2e-runner test-tls-fixtures test-e2e test-cluster-e2e test-authenticated-cluster-e2e test-library-e2e clean redis-start redis-stop redis-cluster-start redis-cluster-stop profile setup

# Default target
help:
	@echo "Targets: setup build test test-unit test-e2e-runner test-e2e test-cluster-e2e test-authenticated-cluster-e2e redis-start redis-stop redis-cluster-start redis-cluster-stop profile clean"

# Setup dependencies (run once in new environment)
setup:
	git config core.hooksPath .githooks
	@echo "Git hooks configured from .githooks/"
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

# Build the project (both hask-redis-mux and redis-client)
build:
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal build all -fe2e"
else
	cabal build all
endif

# Run all tests
test: test-unit test-e2e test-cluster-e2e test-authenticated-cluster-e2e test-library-e2e

# Run unit tests (hask-redis-mux tests run via nix dependency build; FillHelpersSpec from redis-client)
test-unit: test-metadata test-credentials test-e2e-runner
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal build all && cabal test all"
else
	cabal build all && cabal test all
endif

test-metadata:
	python3 scripts/test-redis-command-metadata.py

test-credentials:
	python3 -m unittest scripts/test_azure_redis_connect.py
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal build redis-client && cabal test CredentialSpec && ./scripts/test-credential-handling.sh"
else
	cabal build redis-client && cabal test CredentialSpec && ./scripts/test-credential-handling.sh
endif

test-e2e-runner:
	./scripts/test-run-e2e-tests.sh

# Validate ephemeral TLS credential generation without starting Docker.
test-tls-fixtures:
	./scripts/test-tls-fixtures.sh

# Run end-to-end tests with Docker
test-e2e: test-tls-fixtures
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "Error: docker is not installed or not in PATH"; \
		exit 1; \
	fi
	@if ! command -v nix-build >/dev/null 2>&1; then \
		echo "Error: nix-build is not installed or not in PATH"; \
		echo "E2E tests require Nix to build the test container image"; \
		exit 1; \
	fi
	./scripts/run-e2e-tests.sh

# Run cluster end-to-end tests with Docker
test-cluster-e2e:
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "Error: docker is not installed or not in PATH"; \
		exit 1; \
	fi
	@echo "Running cluster E2E tests..."
	./scripts/run-cluster-e2e-tests.sh

# Run authenticated cluster interoperability tests with Docker
test-authenticated-cluster-e2e:
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "Error: docker is not installed or not in PATH"; \
		exit 1; \
	fi
	@echo "Running authenticated cluster E2E tests..."
	./scripts/run-authenticated-cluster-e2e-tests.sh

# Run library end-to-end tests with Docker
test-library-e2e:
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "Error: docker is not installed or not in PATH"; \
		exit 1; \
	fi
	@echo "Running library E2E tests..."
	./scripts/run-library-e2e-tests.sh

# Start Redis with Docker Compose
redis-start:
	@./scripts/start-standalone-redis.sh

# Start Redis Cluster with Docker Compose
redis-cluster-start:
	@cd docker/cluster && docker compose up -d
	@sleep 5
	@cd docker/cluster && ./make_cluster.sh

# Stop Redis
redis-stop:
	@./scripts/stop-standalone-redis.sh

# Stop Redis Cluster
redis-cluster-stop:
	@cd docker/cluster && docker compose down

# Build with profiling enabled (both packages)
profile:
ifeq ($(HAS_NIX),yes)
	nix-shell --run "cabal build all --enable-profiling"
else
	cabal build all --enable-profiling
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
