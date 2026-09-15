# Revision history for hask-redis-mux

## 0.3.0.0 -- Unreleased

*   **Breaking unified public error model**
    *   Sequential, standalone, cluster, low-level command, and topology-refresh
        runners now return `Either RedisClientError`; the previous mixture of
        thrown exceptions, `MonadFail`, and `Either ClusterError` is removed.
    *   `RedisClientError` layers server, conversion, protocol, transport,
        cluster, and lifecycle failures. Retry, setup, action, and cleanup
        failures retain structured nested causes rather than display strings.
    *   Public exception boundaries rethrow asynchronous cancellation instead
        of converting it to `Left`.
    *   Redis error replies can no longer decode successfully as `()` or raw
        `RespData`. `ClusterError` remains as a deprecated migration alias.

*   **Qualified RESP support**
    *   Command parsing and encoding are RESP2-first, with RESP3-shaped map
        and set aggregates only. RESP3 session and scalar types remain
        unsupported by command APIs; pinned tunnel opaque forwarding is
        documented separately.
*   **Bounded multiplexer backpressure**
    *   Each multiplexer now admits at most 4,096 submitted-but-not-yet-completed
        commands across queued, writer-owned, and reader-owned states.
    *   Writer drains are capped at 512 commands per batch instead of draining
        the entire ready queue unconditionally.
    *   Completion, parser failure, connection close, destroy, and cancelled
        waiters all release admission capacity exactly once.
    *   `MultiplexerBackpressureBench` documents the synthetic stalled-server
        tradeoff: lower peak residency from 93.0 MiB to 60.0 MiB in exchange
        for lower overload throughput and higher p99 latency, while
        `MultiplexerSpec` covers admission closure, parser failure, and
        cancellation release paths.
*   **Connection-pool synchronization API change**
    *   `ConnectionPool(..)` now exposes per-node synchronization state rather than
        the former single pool-wide `MVar`; code that constructed or inspected this
        record must use `createPool`, `withConnection`, `getConnectionPoolStats`, and
        `closePool` instead.
    *   Pool closure is terminal at checkout linearization: idle checkouts,
        queued direct handoffs, reservations, and newly connecting checkouts
        reject once `closePool` has marked the pool closed. Leases acquired
        before that point remain valid and are closed when returned.
*   **Expanded public Redis command API**
    *   Added 39 previously missing `RedisCommands` methods: `append`, `strlen`,
        `setex`, `incrby`, `decrby`, `incrbyfloat`, `getdel`, `getex`, `persist`,
        `keyType`, `rename`, `renamenx`, `unlink`, `pfadd`, `pfcount`, `pfmerge`,
        `srem`, `sdiff`, `sinter`, `sunion`, `spop`, `srandmember`, `hgetall`,
        `hlen`, `hsetnx`, `hincrby`, `hincrbyfloat`, `linsert`, `lset`, `ltrim`,
        `lrem`, `zrem`, `zcard`, `zscore`, `zrank`, `zrevrank`, `zcount`,
        `zincrby`, and `zrangestore`.
    *   Direct, standalone multiplexed, and cluster clients implement the new
        methods. Downstream `RedisCommands` instances must also implement them;
        this source-incompatible typeclass expansion is part of the same
        `0.3.0.0` release rather than introducing another breaking version.
    *   Cluster dispatch validates the new command grammar and all participating
        keys before sending. `ZCOUNT` score ranges match the pinned Redis 7.2
        `zslParseRange` boundary, including exclusive finite and infinite bounds.
*   **Bounded connection setup**
    *   `PoolConfig.connectionTimeout` now uses a supervised wall-clock deadline for DNS, TCP connect, and TLS context/handshake setup.
    *   Timeout cleanup aborts failed TLS setup instead of waiting for graceful `bye`, with exactly-once registered transport cleanup.
    *   Setup timeouts preserve the transport phase and endpoint in `ConnectionSetupTimeout` and participate in bounded cluster retries.
    *   Added timeout-aware direct helpers; legacy raw connector helpers remain intentionally unbounded for API compatibility.
    *   Plaintext and TLS setup failures close partially allocated sockets; the separate 300-second post-connect receive timeout is unchanged.
*   **Per-connection cluster authentication**
    *   Added `ClusterPassword` and `ClusterACL` construction policies that authenticate seed, pooled, multiplexed, redirected, and replacement connections before use.
    *   Password authentication uses `AUTH password`; named ACL authentication uses `HELLO 2 AUTH username password` and never negotiates RESP3.
    *   Cluster runtime `auth` now rejects its misleading one-socket behavior; standalone `auth` remains connection-scoped.
*   **Authoritative MOVED recovery**
    *   MOVED commands retry directly at the advertised target without sending `ASKING`, and patch the affected slot before the retry.
    *   Full topology refresh uses a bounded candidate list of the redirect target, known masters, and the original seed.
    *   Concurrent MOVED patches survive stale in-flight refreshes, while connector and refresh failures remain in the typed retry result.
*   **Central cluster error classification**
    *   MOVED, ASK, TRYAGAIN, CLUSTERDOWN, CROSSSLOT, and ordinary Redis errors now share one strict reply classifier across keyed, keyless, and redirected paths.
    *   TRYAGAIN retries the current route with bounded saturating exponential backoff; CLUSTERDOWN performs a best-effort refresh before bounded backoff without replacing the Redis cause when refresh validation or I/O fails.
    *   CROSSSLOT and ordinary server errors return immediately as typed `ClusterError` values, preserving the complete server error payload.
*   **Strict smart routing**
    *   Smart cluster routing now validates commands, subcommands, and argument counts against the pinned Redis 7.2 metadata before dispatch.
    *   Unknown or malformed commands and cross-slot multi-key requests are rejected instead of falling through to first-argument routing.
    *   The exported `keylessCommands` and `requiresKeyCommands` routing lists are now generated from the pinned metadata snapshot.

## 0.1.0.1 -- 2025-02-11

*   First version.
*   RESP2-first parser, encoder, and direct client basics.
*   Initial TLS, routing, and typed response conversion APIs.
