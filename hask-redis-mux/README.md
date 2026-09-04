# hask-redis-mux

[![Hackage](https://img.shields.io/hackage/v/hask-redis-mux.svg)](https://hackage.haskell.org/package/hask-redis-mux)
[![CI](https://github.com/sspeaks/redis-client/actions/workflows/runTests.yml/badge.svg)](https://github.com/sspeaks/redis-client/actions/workflows/runTests.yml)

A multiplexed Redis client library for Haskell with full RESP protocol support,
Redis Cluster topology discovery, connection pooling, and TLS.

## Features

- **Standalone & Cluster** — works with single-node Redis and Redis Cluster
- **Multiplexed pipelining** — concurrent commands share a single TCP connection
- **Typed returns** via `FromResp` — parse responses as `ByteString`, `Integer`, `Text`, `Bool`, or custom types
- **TLS support** — connect over TLS with `crypton`
- **Bracket-style resource management** — `withStandaloneClient` / `withClusterClient` for exception-safe cleanup
- **Connection pooling** — automatic pool management for cluster nodes

## Installation

Add to your `.cabal` file:

```cabal
build-depends: hask-redis-mux >= 0.1 && < 0.2
```

## Quick Start

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Database.Redis

main :: IO ()
main = do
  -- Connect to localhost:6379, run commands, auto-close
  result <- runRedis defaultStandaloneConfig $ do
    set "greeting" "hello"
    (val :: ByteString) <- get "greeting"
    return val
  print result  -- "hello"
```

## Typed Returns with FromResp

Commands return polymorphic types via the `FromResp` typeclass. Just add a
type annotation and the response is parsed automatically:

```haskell
runRedis defaultStandaloneConfig $ do
  set "counter" "42"

  (n :: Integer)      <- get "counter"   -- 42
  (bs :: ByteString)  <- get "counter"   -- "42"
  (mt :: Maybe Text)  <- get "missing"   -- Nothing
  (ok :: Bool)        <- set "k" "v"     -- True (from +OK)
```

## Bracket Pattern (Recommended)

Use bracket-style functions for exception-safe resource management:

```haskell
-- Standalone
withStandaloneClient config $ \client ->
  runStandaloneClient client $ do
    set "key" "value"
    get "key"

-- Cluster
withClusterClient clusterConfig connector $ \client ->
  runClusterCommandClient client $ do
    set "key" "value"
    get "key"
```

## Custom Configuration

```haskell
import Database.Redis

main :: IO ()
main = do
  let config = StandaloneConfig
        { standaloneNodeAddress     = NodeAddress "redis.example.com" 6379
        , standaloneConnector       = clusterPlaintextConnector
        , standaloneMultiplexerCount = 4  -- 4 multiplexed connections
        }
  withStandaloneClient config $ \client ->
    runStandaloneClient client $ do
      set "key" "value"
```

## Transport Security

Use a TLS connector before issuing `AUTH` or otherwise transmitting credentials.
The library exposes transport and authentication separately, so direct library
callers are responsible for keeping authenticated traffic off plaintext
connectors.

TLS certificate verification is enabled by default. For controlled testing
only, set `REDIS_CLIENT_TLS_INSECURE=1` to disable verification. The client emits
a warning whenever the bypass is active. Unset, empty, `0`, and `false` preserve
verification; other values are rejected instead of silently weakening TLS.

## Documentation

- [Haddock API docs](https://hackage.haskell.org/package/hask-redis-mux)
- [GitHub repository](https://github.com/sspeaks/redis-client)

## License

MIT — see [LICENSE](LICENSE) for details.
