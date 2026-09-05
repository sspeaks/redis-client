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

The callback owns the client only for its duration. When it returns or throws,
the library permanently closes every plaintext or TLS transport acquired by
that client. Teardown is idempotent and each transport finalizer runs exactly
once. A client or pool must not be reused after bracket exit or explicit close:
later submissions return a typed closed-client/pool failure and never reconnect.

## Cluster Error Contract

The low-level `executeKeyedClusterCommand` and
`executeKeylessClusterCommand` APIs return `Either ClusterError RespData`.
Every Redis `RespError` is classified centrally and is returned on the `Left`;
error replies are never success-shaped:

- Keyed `MOVED` and `ASK` replies preserve their existing direct-target routing
  behavior. Keyless commands return those typed redirects immediately because
  they have no routing key to apply at the target.
- `TRYAGAIN` retries the current keyed or keyless route with saturating
  exponential backoff.
- `CLUSTERDOWN` performs a best-effort bounded topology refresh, then retries
  the keyed or keyless command from the current topology with the same backoff
  schedule. Refresh parsing, validation, and connector failures do not replace
  the Redis error or consume a command attempt; client closure and asynchronous
  cancellation remain terminal.
- `CROSSSLOT` is permanent for the command and returns immediately.
- Other server errors such as `ERR`, `WRONGTYPE`, and `NOSCRIPT` return
  `RedisCommandError` with the original server payload.

`clusterMaxRetries` is the total command-attempt budget, including the initial
attempt. Backoff occurs only when another attempt remains, starts at
`clusterRetryDelay`, doubles between attempts, and saturates at `maxBound`
instead of overflowing. The delay remains interruptible, so asynchronous
cancellation is rethrown rather than converted into a cluster error.

The existing typed `ClusterCommandClient` runner still unwraps `ClusterError`
through its historical `MonadFail` behavior. Ordinary Redis errors therefore
fail the typed command instead of appearing as values. The planned breaking
`Either RedisClientError` runner migration will replace that unwrap while
nesting these same structured cluster/server causes; this change does not add a
second compatibility runner.

## Generated command routing source of truth

`Database.Redis.Cluster.Commands` is generated from the immutable Redis 7.2.6
command metadata snapshot in `../vendor/redis-7.2.6-commands/`
(SHA `ae6a2aa95cd094b032e7a69b8b59f64dd1ed085f`).

Use:

```sh
scripts/generate_cluster_routing.py
scripts/audit_cluster_routing.sh
```

`audit_cluster_routing.sh` performs semantic drift detection against canonical
generator output; deliberate mutation of any generated routing entry fails the
audit.

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

## Cluster Authentication

Redis authentication is connection-scoped. Authenticated cluster clients must
therefore apply credentials while each physical connection is created, before
topology discovery or application commands:

```haskell
let credentials = ClusterPassword "secret"

withClusterClientAuthentication
    clusterConfig
    credentials
    (clusterTLSConnector "redis.example.net") $ \client ->
  runClusterCommandClient client $ get "key"
```

`ClusterPassword password` sends `AUTH password`, which authenticates the
default user and remains compatible with legacy password-protected Redis.
`ClusterACL username password` sends
`HELLO 2 AUTH username password`; the explicit protocol version preserves the
library's RESP2 contract and never negotiates RESP3.

The policy is applied exactly once to every seed, topology-refresh, pooled,
keyed multiplexer, MOVED/ASK target, replacement, reconnect, and stored
connector connection before that connection is exposed. Authentication failure
or timeout abortively closes the transport, and
`ClusterAuthenticationException` contains only the endpoint, never the
credential or server response.

Calling the shared `auth` command through `ClusterCommandClient` now throws
`ClusterRuntimeAuthenticationUnsupported`, because authenticating one arbitrary
socket cannot establish cluster-wide state. Migrate custom connector wrappers
to `createClusterClientWithAuthentication` or
`withClusterClientAuthentication`. Existing unauthenticated constructors remain
unchanged.

Standalone `auth` remains meaningful because a standalone client owns one
physical connection. It uses `AUTH password` for an empty or `default` username
and `HELLO 2 AUTH username password` for a named ACL user.

## Transport Security

Use a TLS connector whenever credentials must not cross the network in
plaintext. Passing a plaintext connector to an authenticated constructor is an
explicit caller choice; the library does not silently upgrade transport
security.

TLS certificate verification is enabled by default. For controlled testing
only, set `REDIS_CLIENT_TLS_INSECURE=1` to disable verification. The client emits
a warning whenever the bypass is active. Unset, empty, `0`, and `false` preserve
verification; other values are rejected instead of silently weakening TLS.

## Connection Setup Timeouts

`PoolConfig.connectionTimeout` is a per-attempt wall-clock deadline in seconds.
For plaintext connections it covers DNS resolution, socket creation/options,
TCP connect, and configured connection authentication. For TLS connections it
covers those phases plus certificate store loading, TLS context creation, and
the TLS handshake. A timed-out setup throws `ConnectionSetupTimeout`, which
records the endpoint and active phase without including credentials.

Cluster multiplexers and ordinary pooled connections use the same deadline.
The cluster client retains that bounded connector for benchmark, fill, flush,
and pinned-tunnel connections rather than falling back to the raw connector.
Timeout retries are bounded by `clusterMaxRetries`; the total worst-case
connection time is the per-attempt deadline multiplied by the retry count, plus
configured retry backoff. Timeout retries do not start an additional topology
refresh connection.

The low-level `connectPlaintext`, `connectTLS`, `clusterPlaintextConnector`, and
`clusterTLSConnector` helpers are intentionally unbounded because they do not
take timeout configuration. Direct callers should use the timeout-aware
variants:

```haskell
conn <- connectTLSWithTimeout 5 "redis.example.net" 6380

let standaloneConfig = defaultStandaloneConfig
      { standaloneConnector = clusterPlaintextConnectorWithTimeout 5 }
withStandaloneClient standaloneConfig $ \client ->
  runStandaloneClient client ping
```

`createClusterClientWithAuthentication` supervises the raw connector and AUTH
under one configured deadline. Do not pass a separately timeout-wrapped
connector to that constructor, because nested deadlines obscure the intended
single-attempt budget. `withConnectionTimeoutSupervised` remains available for
custom lower-level initialization.

The caller-side deadline is independent of asynchronous exception delivery.
The supervisor returns at the configured wall-clock boundary, requests worker
cancellation, and aborts any registered transport. A platform resolver or TLS
FFI call that is genuinely non-interruptible may transiently keep its worker
alive until that call returns; no connection returned after expiry is exposed,
and any owned socket is closed as soon as it is available.

The existing 300-second `receive` timeout applies only after a connection has
been established. It is independent of `connectionTimeout` and is not part of
the setup or retry budget.

## Documentation

- [Haddock API docs](https://hackage.haskell.org/package/hask-redis-mux)
- [GitHub repository](https://github.com/sspeaks/redis-client)

## License

MIT — see [LICENSE](LICENSE) for details.
