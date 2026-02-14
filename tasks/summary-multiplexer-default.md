# Multiplexer Default

## Overview
Multiplexing is now the default behavior for both standalone and cluster Redis connections. A new standalone multiplexed client has been added, enabling pipelined throughput for single-node Redis without requiring cluster mode. Comprehensive unit and end-to-end tests ensure the multiplexer subsystem is robust under concurrency and stress.

## What's New

### Standalone Multiplexed Client
A new `StandaloneClient` module provides a multiplexed Redis client for standalone (non-cluster) Redis instances. It wraps a single `Multiplexer` and supports all 40+ Redis commands (GET, SET, DEL, MGET, HSET, HGET, LPUSH, ZADD, etc.) with automatic pipelining for high throughput.

### Standalone Client Configuration
A `StandaloneConfig` data type lets you configure the standalone client with options for node address, connector (plaintext or TLS), multiplexer count, and a `useMultiplexing` flag. Setting `useMultiplexing = False` falls back to sequential single-connection behavior.

### Cluster Multiplexing Enabled by Default
Cluster mode now uses multiplexing by default. No configuration change is needed to benefit from pipelined throughput in cluster mode. You can still opt out by setting `clusterUseMultiplexing = False`.

### Multiplexer Unit Tests
Two new test suites (`MultiplexerSpec` and `MultiplexPoolSpec`) provide 22 unit tests covering slot allocation, response demultiplexing, command batching, lifecycle management, round-robin routing, lazy creation, multi-node routing, and pool closure — all without requiring a live Redis instance.

### Standalone E2E and Concurrency Tests
26 new end-to-end tests exercise the standalone client against a real Redis instance, covering basic operations, hash/list/set/sorted-set commands, concurrent access (50+ threads), multi-multiplexer load distribution, and graceful handling of submit-after-destroy scenarios.

## How to Use

### Standalone Multiplexed Client (Recommended)

```haskell
import Redis

main :: IO ()
main = do
  let config = StandaloneConfig
        { standaloneNodeAddress = ("localhost", 6379)
        , standaloneConnector   = plaintextConnector
        , standaloneMultiplexerCount = Nothing  -- defaults to numCapabilities
        , standaloneUseMultiplexing  = True     -- default
        }
  client <- createStandaloneClientFromConfig config
  result <- runStandaloneClient client $ do
    set "mykey" "myvalue"
    get "mykey"
  print result
  closeStandaloneClient client
```

### Simple Standalone Client (No Config)

```haskell
client <- createStandaloneClient plaintextConnector ("localhost", 6379)
result <- runStandaloneClient client $ get "mykey"
closeStandaloneClient client
```

### Cluster Client (Multiplexing On by Default)

```haskell
let config = ClusterConfig
      { clusterNodes = [("localhost", 7000)]
      , clusterConnector = plaintextConnector
      , clusterUseMultiplexing = True  -- now the default
      }
```

### Opting Out of Multiplexing

Set `standaloneUseMultiplexing = False` or `clusterUseMultiplexing = False` to fall back to sequential single-connection behavior.

### Running Tests

```bash
# All unit tests (includes MultiplexerSpec and MultiplexPoolSpec)
cabal test MultiplexerSpec MultiplexPoolSpec

# Full E2E suite (requires Docker cluster + standalone Redis)
make test
```

## Technical Notes

- **CLIENT REPLY OFF/SKIP** commands are silently ignored when multiplexing is enabled, since suppressing responses would desynchronize the multiplexer's response demultiplexer.
- The `StandaloneBackend` uses an existential GADT pattern (`DirectBackend` / `MuxBackend`) to support both multiplexed and direct-connection backends behind the same `StandaloneClient` type.
- A bug fix was applied to `MultiplexPool.createNodeMuxes`: the round-robin counter now initializes to 1 instead of 0, because `getMultiplexer` returns the first mux directly on initial creation without incrementing the counter.
- A standalone Redis container (`redis-standalone.local:6390`) was added to the Docker Compose setup for E2E testing.
- `SMEMBERS` returns elements in arbitrary order — tests use membership checks rather than exact array comparison.
- `zadd` takes `Int` scores, not `Double`.

## Files Changed

### Library (New Modules)
- `lib/cluster/StandaloneClient.hs` — standalone multiplexed client with `StandaloneConfig`, `StandaloneClient`, and `StandaloneCommandClient` types

### Library (Modified)
- `lib/cluster/ClusterCommandClient.hs` — updated haddock to document `clusterUseMultiplexing` default as `True`
- `lib/cluster/MultiplexPool.hs` — fixed round-robin counter initialization (0 → 1)
- `lib/redis/Redis.hs` — re-exports `StandaloneClient`, `StandaloneConfig`, `createStandaloneClientFromConfig`

### Build Configuration
- `hask-redis-mux/hask-redis-mux.cabal` — added `StandaloneClient` to exposed/reexported modules; added `MultiplexerSpec` and `MultiplexPoolSpec` test suites

### Tests (New)
- `test/MultiplexerSpec.hs` — 14 unit tests for Multiplexer internals (slot pool, response slots, batching, lifecycle)
- `test/MultiplexPoolSpec.hs` — 8 unit tests for MultiplexPool (round-robin, lazy creation, multi-node, closure)
- `test/LibraryE2E/StandaloneTests.hs` — 20 E2E tests for standalone client (all command families)
- `test/LibraryE2E/StandaloneConcurrencyTests.hs` — 6 concurrency/stress tests (50-thread storms, submit-after-destroy)

### Tests (Modified)
- `test/LibraryE2E/Utils.hs` — `defaultTestConfig` flipped to `clusterUseMultiplexing = True`
- `test/LibraryE2E.hs` — registered new standalone test modules
- `redis-client.cabal` — added new test modules to `other-modules`

### Docker / Infrastructure
- `docker-cluster/docker-compose.yml` — added `redis-standalone` service on port 6390
- `docker-cluster/redis-standalone.conf` — standalone Redis configuration

### Documentation
- `README.md` — added Library Usage section with standalone and cluster examples; updated project structure and test commands
- `CHANGELOG.md` — added v0.6.0.0 entry documenting all changes
