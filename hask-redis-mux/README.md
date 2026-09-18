# hask-redis-mux

[![Hackage](https://img.shields.io/hackage/v/hask-redis-mux.svg)](https://hackage.haskell.org/package/hask-redis-mux)
[![CI](https://github.com/sspeaks/redis-client/actions/workflows/runTests.yml/badge.svg)](https://github.com/sspeaks/redis-client/actions/workflows/runTests.yml)

A multiplexed Redis client library for Haskell with RESP2-first command
support, Redis Cluster topology discovery, connection pooling, and TLS.

## RESP support

The command client parses and encodes this exact `RespData` subset:

- RESP2 simple strings, errors, integers, bulk strings (including null bulk
  strings), and non-null arrays.
- RESP3-shaped maps and sets as aggregate values.

This is not full RESP3 support. The command parser does not interpret RESP3
pushes, attributes, streamed encodings, booleans, doubles, big numbers, bulk
errors, verbatim strings, or arbitrary module replies. The client also does not
negotiate RESP3 session semantics; authenticated connections explicitly retain
RESP2 with `HELLO 2`.

The pinned cluster tunnel has a separate opaque fallback that forwards complete
RESP3 frames outside `RespData`, including streamed values, byte-for-byte.
RESP3-shaped maps and sets take the `RespData` path and are re-encoded, so their
original ordering is not preserved. Opaque forwarding is transport framing
compatibility only and does not make those RESP3 types available to command
APIs.

## Features

- **Standalone & Cluster** — works with single-node Redis and Redis Cluster
- **Multiplexed pipelining** — concurrent commands share a single TCP connection
- **Typed returns** via `FromResp` — parse responses as `ByteString`, `Integer`, `Text`, `Bool`, or custom types
- **TLS support** — connect over TLS with `crypton`
- **Bracket-style resource management** — `withStandaloneClient` / `withClusterClient` for exception-safe cleanup
- **Connection pooling** — automatic pool management for cluster nodes

`Database.Redis` is the stable convenience facade for the documented
standalone and cluster lifecycle APIs, including `runRedis`,
`defaultStandaloneConfig`, `withStandaloneClient`, `withClusterClient`, and
`runClusterCommandClient`. Advanced connection, pooling, and raw-command APIs
remain available from their named modules. The legacy top-level package
library retains its internal multiplexing re-exports for source compatibility,
but they are intentionally not part of the `Database.Redis` facade.

### Multiplexer backpressure and response-slot retention

Multiplexed clients retain at most **256 idle response slots** per client pool.
Slots are striped by capability and return to the stripe where they were
acquired, preserving local reuse even when cancellation cleanup runs on another
thread. Slots allocated during a traffic burst above that cap are released to
the runtime after their response or failure is observed; they are never reused
before completion.

The slot-pool cap bounds post-burst retention, while the separate admission cap
below bounds total outstanding commands. The pool cap was selected as 16 slots
across each of the 16 capability stripes: sufficient for the normal
low-concurrency path while avoiding a permanently retained slot for every
transient request in large bursts.

Each multiplexer also applies bounded backpressure before queue admission:

- At most **4,096 total submitted-but-not-yet-completed commands** may exist
  across the command queue, the writer-owned active batch, and the pending
  response queue.
- The writer sends at most **512 commands per batch** before returning to the
  shared queue, so a stalled connection cannot accumulate one arbitrarily large
  builder or delay later commands behind an unlimited drain.
- Completion, parser failure, connection close, and cancelled waiters all
  release their admission capacity exactly once.

`SlotPoolBurstBench` exercises 64, 1,024, and 4,096 outstanding commands plus
a 1,024-command cancellation burst with RTS statistics enabled. On the
reference local run, the 4,096-command burst retained 256 slots, allocated
17,814,464 bytes, reached 8,388,608 bytes peak residency, settled at 590,792
bytes live after GC, and
completed at 857k operations/second with 0.24 microseconds p99 wait latency.
The cancellation burst retained the same 256 slots, allocated 3,339,312 bytes,
and settled at 0.21 MiB
after GC. These synthetic transport measurements isolate slot lifecycle costs;
they are not Redis network throughput claims.

`MultiplexerBackpressureBench` drives 8,192 concurrent 4 KiB `SET` commands
against a deliberately stalled synthetic server and reports peak outstanding
commands, peak residency, mutator/GC/total CPU-seconds, throughput, and
p50/p95/p99 latency. Run it with RTS stats enabled (`+RTS -T -s -RTS`) so the
machine-readable line and the RTS summary expose overload CPU costs. The
benchmark accepts two modes:

- `baseline` disables the new bounds for this workload by setting both limits
  to 8,192, approximating the legacy "drain everything / admit everything"
  behavior.
- `bounded` uses the production defaults of 4,096 outstanding commands and 512
  commands per writer batch.

On the reference local run, `baseline` peaked at **8,192** outstanding
commands, **93.0 MiB** peak residency, **10.6k ops/s**, and **623 ms** p99
latency. The bounded run plateaued at **4,096** outstanding commands,
**60.0 MiB** peak residency, **7.1k ops/s**, and **1.04 s** p99 latency while
keeping writer batches capped at **512** commands. This synthetic overload
benchmark intentionally trades some peak throughput and tail latency for a
documented memory ceiling under stalled-server conditions.

## Installation

Add to your `.cabal` file:

```cabal
build-depends:
  hask-redis-mux >= 0.3 && < 0.4,
  text >= 2.1 && < 2.2
```

## Versioning and releases

`hask-redis-mux` follows the Haskell PVP independently of the `redis-client`
executable. Breaking API changes bump the major component, additive API changes
increment the minor component, and compatible fixes update the patch level. The
package usually advances on its own; it only releases alongside the CLI when a
single commit intentionally ships both packages.

The release tag for this package is `hask-redis-mux-vX.Y.Z.W`. That tag must
match the version in `hask-redis-mux.cabal` and the dated top version heading
in `hask-redis-mux/CHANGELOG.md`. It creates a namespaced GitHub Release with
the package source distribution; Hackage publication remains a manual step.
The repository-wide release checklist lives in
[`../docs/release-process.md`](../docs/release-process.md).

## Quick Start

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Database.Redis

main :: IO ()
main = do
  -- Connect to localhost:6379, run commands, auto-close
  result <- runRedis defaultStandaloneConfig $ do
    (_ :: Bool) <- set "greeting" "hello"
    (val :: ByteString) <- get "greeting"
    return val
  print result  -- Right "hello"
```

## Typed Returns with FromResp

Commands return polymorphic types via the `FromResp` typeclass. Just add a
type annotation and the response is parsed automatically:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Data.Text (Text)
import Database.Redis

main :: IO ()
main = do
  result <- runRedis defaultStandaloneConfig $ do
    (_ :: Bool) <- set "counter" "42"
    (n :: Integer) <- get "counter"
    (bs :: ByteString) <- get "counter"
    (mt :: Maybe Text) <- get "missing"
    (ok :: Bool) <- set "k" "v"
    return (n, bs, mt, ok)
  print result
```

## Additional Core Commands (Unreleased 0.3.0.0)

The unreleased 0.3.0.0 API adds typed wrappers for:

- Strings: `append`, `strlen`, `setex`, `incrby`, `decrby`, `incrbyfloat`,
  `getdel`, and `getex`.
- Hashes and lists: `hgetall`, `hlen`, `hsetnx`, `hincrby`, `hincrbyfloat`,
  `linsert`, `lset`, `ltrim`, and `lrem`.
- Sets and HyperLogLog: `srem`, `sdiff`, `sinter`, `sunion`, `spop`,
  `srandmember`, `pfadd`, `pfcount`, and `pfmerge`.
- Sorted sets and keys: `zrem`, `zcard`, `zscore`, `zrank`, `zrevrank`,
  `zcount`, `zincrby`, `zrangestore`, `persist`, `keyType`, `rename`,
  `renamenx`, and `unlink`.

These wrappers use the same polymorphic `FromResp` conversion as existing
commands. In a cluster, every key of a multi-key wrapper must share a hash
slot; mismatched keys fail locally with `CROSSSLOT` before a command is sent.
`getex` and `zrangestore` accept their Redis option tokens as `ByteString`
lists and validate them against the bundled Redis 7.2 command metadata.

Because `RedisCommands` is a public typeclass, adding methods requires
downstream custom instances to implement them. This is a PVP breaking change
and is therefore part of the planned 0.3.0.0 release.

## Bracket Pattern (Recommended)

Use bracket-style functions for exception-safe resource management:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Database.Redis

standaloneExample :: IO (Either RedisClientError ByteString)
standaloneExample =
  withStandaloneClient defaultStandaloneConfig $ \client ->
    runStandaloneClient client $ do
      (_ :: Bool) <- set "key" "value"
      get "key"

clusterExample :: IO (Either RedisClientError ByteString)
clusterExample =
  withClusterClient exampleClusterConfig clusterPlaintextConnector $ \client ->
    runClusterCommandClient client $ do
      (_ :: Bool) <- set "{example}:key" "value"
      get "{example}:key"

exampleClusterConfig :: ClusterConfig
exampleClusterConfig = ClusterConfig
  { clusterSeedNode = NodeAddress "localhost" 7000
  , clusterPoolConfig = PoolConfig
      { maxConnectionsPerNode = 2
      , connectionTimeout = 5
      , maxRetries = 3
      , useTLS = False
      }
  , clusterMaxRetries = 3
  , clusterRetryDelay = 100000
  , clusterTopologyRefreshInterval = 600
  }
```

The callback owns the client only for its duration. When it returns or throws,
the library permanently closes every plaintext or TLS transport acquired by
that client. Teardown is idempotent and each transport finalizer runs exactly
once. A client or pool must not be reused after bracket exit or explicit close:
later submissions return a typed closed-client/pool failure and never reconnect.

## Unified Error Contract

All public sequential, standalone, cluster, low-level command, and topology
refresh runners return `Either RedisClientError`. Redis error replies are
always `Left`, including commands decoded as `()` or raw `RespData`.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Database.Redis

setExample :: IO ()
setExample = do
  result <- runRedis defaultStandaloneConfig
    (set "key" "value" :: StandaloneCommandClient Bool)
  putStrLn $ classify result

classify :: Either RedisClientError value -> String
classify (Right _) = "success"
classify (Left (RedisServerError _)) = "server"
classify (Left (RedisProtocolError _)) = "protocol"
classify (Left (RedisTransportError _)) = "transport"
classify (Left (RedisClusterError _)) = "cluster"
classify (Left (RedisLifecycleError _)) = "lifecycle"
classify (Left (RedisConversionError _)) = "conversion"
```

Transport, setup, cleanup, and retry failures retain structured
`SomeException` or nested `RedisClientError` causes. Callers can inspect a
transport cause using `fromException`; the library does not replace it with
`displayException`. Asynchronous exceptions such as thread cancellation are
re-thrown and never converted to `Left`.

This is a breaking replacement for the former mix of thrown runner failures,
`Either ClusterError`, and `MonadFail`. Migration consists of matching the
runner result:

```haskell
import Database.Redis

runAction
  :: StandaloneClient
  -> StandaloneCommandClient ByteString
  -> IO ()
runAction client action = do
  result <- runStandaloneClient client action
  case result of
    Left err -> print err
    Right value -> print value
```

`ClusterError` remains as a deprecated alias for source migration, but new
code should use `RedisClientError`. Cluster failures retain these semantics:

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

## Custom Configuration

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Database.Redis

main :: IO ()
main = do
  let config = StandaloneConfig
        { standaloneNodeAddress     = NodeAddress "redis.example.com" 6379
        , standaloneConnector       = clusterPlaintextConnector
        , standaloneMultiplexerCount = 4  -- 4 multiplexed connections
        }
  result <- withStandaloneClient config $ \client ->
    runStandaloneClient client
      (set "key" "value" :: StandaloneCommandClient Bool)
  print result
```

## Cluster Authentication

Redis authentication is connection-scoped. Authenticated cluster clients must
therefore apply credentials while each physical connection is created, before
topology discovery or application commands:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Database.Redis

authenticatedExample :: IO (Either RedisClientError ByteString)
authenticatedExample =
  withClusterClientAuthentication
      exampleClusterConfig
      (ClusterPassword "secret")
      (clusterTLSConnector "redis.example.net") $ \client ->
    runClusterCommandClient client $ get "{example}:key"

exampleClusterConfig :: ClusterConfig
exampleClusterConfig = ClusterConfig
  { clusterSeedNode = NodeAddress "redis.example.net" 6380
  , clusterPoolConfig = PoolConfig
      { maxConnectionsPerNode = 2
      , connectionTimeout = 5
      , maxRetries = 3
      , useTLS = True
      }
  , clusterMaxRetries = 3
  , clusterRetryDelay = 100000
  , clusterTopologyRefreshInterval = 600
  }
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
{-# LANGUAGE DataKinds #-}

import Database.Redis

tlsConnection :: IO (TLSClient 'Connected)
tlsConnection =
  connectTLSWithTimeout 5 "redis.example.net" 6380

standalonePing :: IO (Either RedisClientError ByteString)
standalonePing =
  withStandaloneClient standaloneConfig $ \client ->
    runStandaloneClient client ping
  where
    standaloneConfig = defaultStandaloneConfig
      { standaloneConnector = clusterPlaintextConnectorWithTimeout 5 }
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
