# Revision history for redis-client

## 0.5.0.0 -- 2026-02-05

*   **Major Feature: Redis Cluster Support**
    *   Implemented full cluster support including topology management, connection pooling, and slot routing.
    *   Added smart routing with automatic `MOVED` and `ASK` redirection handling.
    *   Updated `fill`, `cli`, and `tunnel` modes to work seamlessly with Redis Cluster.
    *   Added "Pinned Proxy" mode to support specific cluster proxy configurations.
    *   Fixed hostname rewriting for cluster nodes in tunnel mode.
*   **Infrastructure & Testing**
    *   Added comprehensive End-to-End (E2E) tests for Cluster scenarios (Basic, Fill, Tunnel, CLI).
    *   Updated build system to prefer `nix-build` and `make test`.
    *   Added GitHub Actions workflows for automated testing and bootstrapping.
*   **Improvements**
    *   Fixed various race conditions and unsafe head usage.
    *   Improved error handling for `CROSSSLOT` operations.
    *   Refactored codebase for better maintainability (Cluster separation).

## 0.4.0.0 -- 2026-02-02

*   **Azure Integration**
    *   Added `azure-redis-connect` python script for Azure Redis Cache discovery and connectivity.
    *   Added support for Entra authentication (username/OID retrieval from JWT).
*   **Performance Optimization**
    *   Optimized data filling with parallel noise generation strategies.
    *   Optimized connection handling (parallel connections adjustment).
*   **DevOps**
    *   Added agent testing infrastructure.

## 0.3.0.0 -- 2025-10-15

*   **Command Expansion**
    *   Added support for Geo commands.
    *   Expanded standard Redis command set support.
*   **Build System**
    *   Added `flake.nix` for modern Nix support.
    *   Fixed inefficient store usage in build.
*   **Testing**
    *   Added tunneling tests.

## 0.2.0.0 -- 2025-03-28

*   **New Architectures**
    *   Added "Tunnel mode" for proxying Redis connections.
    *   Added TLS client support.
    *   Added Pipelining support for improved throughput.
*   **CLI & Usability**
    *   Added argument parsing for the CLI application.
    *   Added support for arrow key navigation in CLI.
    *   Added DNS resolution support.
*   **Core Improvements**
    *   Refactored RESP parsing logic.
    *   Improved Incremental network reading (State monad refactor).
    *   Added basic E2E testing framework.

## 0.1.0.0 -- 2025-02-11

*   First version.
*   Basic RESP data types.
*   Simple plaintext client implementation.
