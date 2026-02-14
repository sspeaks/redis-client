# PRD: hask-redis-mux Ergonomics & Hackage Readiness

## Overview

Make the `hask-redis-mux` library as ergonomic and friendly to use as possible, and fully prepare it for publishing to Hackage. Ergonomics take priority over performance.

## Problem Statement

The library has a solid internal architecture (multiplexed connections, cluster support, TLS, CRC16 slot routing) but its public API has several ergonomic friction points that make it harder to adopt than necessary:

1. **All commands return raw `RespData`** — users must pattern-match at every call site to extract typed values
2. **Flat module names** (`Resp`, `Client`, `Cluster`) conflict with common names and don't follow Hackage conventions
3. **No bracket-style resource management** — users must manually pair `create`/`close` calls
4. **Internal modules are re-exported** — `Multiplexer`, `MultiplexPool`, `SlotPool` are exposed but shouldn't be part of the primary API
5. **Missing Hackage metadata** — no upper-bounded dependencies, no homepage/bug-reports URLs, `cabal check` not clean, incomplete Haddock coverage

## Goals

- Make the library a joy to use for common Redis operations
- Follow Haskell ecosystem conventions (module naming, PVP, Hackage standards)
- Ergonomics above all else — trade performance for usability where needed

## Non-Goals

- Adding new Redis commands (SCAN, Streams, EVAL, ACL, etc.)
- Changing the multiplexer or connection pool internals
- Supporting `MonadResource` or `conduit`-style streaming
- Adding a `ToRedis` input typeclass — `ByteString` keys/values with `OverloadedStrings` is sufficient

---

## Feature Requirements

### F1: `FromResp` Typeclass for Typed Command Returns

**Description:** Add a `FromResp` typeclass that allows commands to return polymorphic, user-chosen types instead of raw `RespData`. This eliminates pattern-matching boilerplate at every call site.

**Details:**

- Define `class FromResp a where fromResp :: RespData -> Either RedisError a`
- Provide instances for common types:
  - `ByteString` — unwraps `RespBulkString`
  - `Maybe ByteString` — handles `RespNullBulkString` → `Nothing`
  - `Integer` — unwraps `RespInteger`
  - `Bool` — interprets `RespSimpleString "OK"` → `True`, `RespInteger 1` → `True`
  - `[ByteString]` — unwraps `RespArray` of bulk strings
  - `[RespData]` — unwraps `RespArray` as-is
  - `RespData` — identity (no conversion, for full control)
  - `()` — discards the response (for fire-and-forget commands like `flushAll`)
  - `Text` — decodes UTF-8 from `RespBulkString`
  - `Maybe Text` — handles null + UTF-8 decode
- Add a clear `UnexpectedResp` error constructor to `RedisError`
- Update the `RedisCommands` typeclass so commands have `FromResp` constraints on their return types:
  ```haskell
  get :: (FromResp a) => ByteString -> m a
  set :: (FromResp a) => ByteString -> ByteString -> m a
  incr :: (FromResp a) => ByteString -> m a
  lrange :: (FromResp a) => ByteString -> Int -> Int -> m a
  ```

**Acceptance Criteria:**
- All existing commands work with `FromResp` constraints
- `RespData` still works as a return type (backwards-compatible escape hatch)
- Unit tests for each `FromResp` instance
- Haddock examples showing typed usage

---

### F2: Hierarchical Module Naming (`Database.Redis.*`)

**Description:** Rename all exposed modules to follow the `Database.Redis.*` Hackage convention. This prevents name collisions and follows ecosystem norms.

**Details:**

Current → New mapping:
| Current Module | New Module |
|---|---|
| `Resp` | `Database.Redis.Resp` |
| `Client` | `Database.Redis.Client` |
| `Crc16` | `Database.Redis.Crc16` |
| `RedisCommandClient` | `Database.Redis.Command` |
| `Cluster` | `Database.Redis.Cluster` |
| `ClusterCommandClient` | `Database.Redis.Cluster.Client` |
| `ClusterCommands` | `Database.Redis.Cluster.Commands` |
| `ClusterSlotMapping` | `Database.Redis.Cluster.SlotMapping` |
| `ConnectionPool` | `Database.Redis.Cluster.ConnectionPool` |
| `Connector` | `Database.Redis.Connector` |
| `MultiplexPool` | `Database.Redis.Internal.MultiplexPool` |
| `Multiplexer` | `Database.Redis.Internal.Multiplexer` |
| `StandaloneClient` | `Database.Redis.Standalone` |
| `Redis` | `Database.Redis` |

- Internal modules (`Multiplexer`, `MultiplexPool`) move under `Database.Redis.Internal.*` to signal they are not part of the stable API
- The top-level `Database.Redis` module re-exports the public API (commands, client types, config, connectors, `FromResp`)
- Update the cabal file `exposed-modules` and `reexported-modules` accordingly

**Acceptance Criteria:**
- All modules compile under new names
- `Database.Redis` is the single recommended import for users
- Internal modules are clearly separated
- Existing tests updated to use new module names
- The parent `redis-client.cabal` tests updated to use new module names

---

### F3: Bracket-Style Resource Management

**Description:** Add bracket-style `withRedis` / `withCluster` functions as the primary API for client lifecycle management. These ensure connections are cleaned up on exceptions.

**Details:**

- Add `withStandaloneClient`:
  ```haskell
  withStandaloneClient :: StandaloneConfig client -> (StandaloneClient -> IO a) -> IO a
  ```
- Add `withClusterClient`:
  ```haskell
  withClusterClient :: ClusterConfig -> Connector client -> (ClusterClient -> IO a) -> IO a
  ```
- Both use `bracket` internally to guarantee `close` on exceptions
- Add a convenience combinator that creates + runs in one step:
  ```haskell
  runRedis :: StandaloneConfig client -> StandaloneCommandClient a -> IO a
  ```
- Keep existing `createStandaloneClient`/`closeStandaloneClient` available but mark them with Haddock notes recommending the bracket variants
- Provide a `defaultStandaloneConfig` with sensible defaults (localhost:6379, plaintext, 1 multiplexer)

**Acceptance Criteria:**
- `withStandaloneClient` and `withClusterClient` properly release resources on exceptions
- `defaultStandaloneConfig` works out of the box for local development
- Haddock examples show bracket-style as the primary pattern
- Existing create/close API still works

---

### F4: Full Hackage Readiness

**Description:** Prepare the package for `cabal upload` to Hackage with full compliance.

**Details:**

- **PVP Versioning:** Keep `0.1.0.0` for initial release, document versioning policy in CHANGELOG
- **Upper-bounded dependencies:** Add upper bounds to all `build-depends` based on currently tested versions
- **Cabal metadata:**
  - Add `homepage: https://github.com/sspeaks/redis-client`
  - Add `bug-reports: https://github.com/sspeaks/redis-client/issues`
  - Add `tested-with: GHC == 9.8.4` (or whatever version is in the nix build)
  - Add `description` field with proper Haddock markup
- **`cabal check`:** Fix all warnings so `cabal check` passes cleanly
- **Haddock coverage:**
  - Ensure every exported function, type, and typeclass method has a Haddock comment
  - Add a module-level `@since 0.1.0.0` annotation to each module
  - Add usage examples in the top-level `Database.Redis` module documentation
- **README:**
  - Add a library-focused README in `hask-redis-mux/` with:
    - Quick start example (connect, set, get, close)
    - Feature overview (standalone, cluster, TLS, multiplexing)
    - Installation instructions (cabal dependency line)
    - Link to Haddock docs
    - Badge placeholders for Hackage version, CI status, Haddock coverage

**Acceptance Criteria:**
- `cabal check` passes with no warnings
- `cabal haddock` builds with no missing-doc warnings for public API
- README has a working quick-start example
- All dependency bounds are specified (lower and upper)

---

## Technical Considerations

- The `FromResp` typeclass and module renaming are the most impactful changes. Module renaming will touch every file and test — do it first or last to minimize merge conflicts.
- The `OverloadedStrings` extension is already supported since `ByteString` has an `IsString` instance. No library changes needed — just document it in examples.
- The `FromResp` typeclass changes the `RedisCommands` class signature, which is a breaking change. This is acceptable for a `0.1.0.0` pre-release.
- Keep `RespData` as a valid `FromResp` instance so users can always fall back to raw protocol data.

## Implementation Order

1. **F1 (FromResp)** — Core ergonomic improvement, independent of other changes
2. **F2 (Module renaming)** — Large refactor, do after F1 is stable
3. **F3 (Bracket-style)** — Small addition, can be done alongside F2
4. **F4 (Hackage readiness)** — Final polish pass after API is settled
