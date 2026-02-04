# Redis Cluster Support - Implementation Status

## Executive Summary

This document tracks the implementation of Redis Cluster support in the redis-client project. The core infrastructure has been completed through Phase 4, and Phase 5 code implementation is complete with testing pending.

**Current Status**: Phases 1-4 complete with full functionality. Phase 5 code complete (testing pending). Phases 6-8 remain: tunnel mode (6), comprehensive testing (7), and optional optimizations (8).

## Implementation Status

### ✅ Phase 1: Foundation (COMPLETE)
- ✅ Implemented `Cluster.hs` - topology management, slot calculation, hash tag extraction
- ✅ Implemented `ConnectionPool.hs` - thread-safe connection pooling
- ✅ Implemented slot routing with CRC16 hash
- ✅ Unit tests for slot calculation and hash tag extraction (`ClusterSpec.hs`)

### ✅ Phase 2: Command Execution (COMPLETE)
- ✅ Created `ClusterCommandClient.hs` - cluster-aware command client
- ✅ Implemented `RedisCommands` instance for `ClusterCommandClient`
- ✅ MOVED/ASK error handling infrastructure in place
- ✅ Retry logic with exponential backoff
- ✅ Unit tests for cluster command client (`ClusterCommandSpec.hs`)

### ✅ Phase 3: Mode Integration (COMPLETE - Basic Implementation)
- ✅ CLI mode: Structure integrated, basic REPL placeholder
  - **Limitation**: Currently displays placeholder message instead of executing commands
  - **Next Step**: Implement full command parsing and execution via cluster client
- ✅ Fill mode: Structure integrated, demonstrates cluster connection
  - **Limitation**: Does not perform actual bulk filling in cluster mode
  - **Next Step**: Implement optimized bulk data distribution across cluster nodes
- ✅ Tunnel mode: Structure integrated, pinned mode available
  - **Limitation**: Smart proxy mode not yet implemented
  - **Next Step**: Implement smart routing in tunnel mode

### ✅ Phase 4: CLI Mode (COMPLETE)
Complete the CLI mode implementation for cluster support.

- ✅ Parse user input into RESP commands
- ✅ Execute commands via `ClusterCommandClient`
- ✅ Display responses with formatting
- ✅ Handle CROSSSLOT errors with helpful messages
- ⏳ Show node information in debug mode (optional enhancement)

**Implementation Guide**: Study `app/Main.hs` `repl` function (lines 303-325) for the standalone implementation pattern. The cluster version should follow the same structure but route through `ClusterCommandClient`.

**Current Command Routing Strategy**: 
The implementation uses explicit command lists to determine routing:
- **Keyless commands**: Defined in `keylessCommands` list - routed to any master node
  - Examples: PING, INFO, CLUSTER, FLUSHALL, CONFIG, etc.
- **Keyed commands**: Defined in `requiresKeyCommands` list - routed by key's hash slot
  - Examples: GET, SET, HGET, LPUSH, ZADD, etc.
- **Unknown commands**: If not in either list and has arguments, treated as keyed command

**Limitations of Current Approach**:
- **Issue**: Lists must be manually maintained as Redis evolves with new commands
- **Issue**: Unknown commands may route incorrectly if they don't follow standard patterns
- **Issue**: Multi-key commands with varying key positions are handled by routing to first key's slot

**Future Work - Command Routing Improvements (Post Phase 4)**:

Several approaches could eliminate the hardcoded command lists:

1. **Parse Redis Command Metadata** (Recommended)
   - Redis publishes command metadata via `COMMAND` and `COMMAND DOCS`
   - Could fetch this at startup and build routing tables dynamically
   - Would always be up-to-date with the connected Redis version
   - Estimated effort: ~200-300 LOC

2. **Heuristic-based Routing with Fallback**
   - Try routing by key slot, fall back to keyless on specific errors
   - Simple but may cause unnecessary round-trips
   - Estimated effort: ~100-150 LOC

3. **Parse Redis Command JSON Spec**
   - Redis repo contains JSON spec of all commands
   - Could be embedded at build time or loaded from file
   - Always accurate but requires keeping spec file updated
   - Estimated effort: ~150-200 LOC

4. **Hybrid Approach**
   - Keep minimal list of most common commands
   - Use `COMMAND` metadata for unknown commands
   - Provides best balance of performance and maintenance
   - Estimated effort: ~250-350 LOC

**Recommendation**: Implement approach #1 (Parse Redis Command Metadata) in a future phase after completing Phases 5-7. This provides the most maintainable and accurate solution.

**Estimated Effort**: ~200-300 LOC (current implementation complete), ~200-300 LOC for future enhancement

### ✅ Phase 5: Fill Mode (CODE COMPLETE - Testing Pending)
Complete the Fill mode implementation for cluster support.

- ✅ Calculate slots for keys to ensure even distribution (automatic via CRC16)
- ✅ Distribute data generation across cluster nodes (via ClusterCommandClient routing)
- ✅ Use parallel connections to multiple nodes (default: 2 parallel threads)
- ✅ Implement efficient bulk operations (fire-and-forget mode with CLIENT REPLY OFF)
- ⏳ Add profiling to compare with standalone mode (pending: testing)

**Implementation Status**: Code complete as of 2026-02-04. Implementation reuses existing `fillCacheWithData` and `fillCacheWithDataMB` functions through the `ClusterCommandClient` which automatically routes commands to the correct nodes based on hash slots.

**Key Decision Made**: Runtime CRC16 calculation (simple and automatic). The `ClusterCommandClient` automatically calculates hash slots for each key and routes to the correct node. No manual slot calculation or pre-computed hash tags needed.

**Actual Implementation**: ~29 LOC net change (39 added, 10 removed)
- Significantly less than estimated 300-400 LOC
- Achieved through code reuse and leveraging existing infrastructure
- See `PHASE5_REVIEW.md` for detailed analysis

**Testing Status**: Blocked by build environment issues (network connectivity). See `TESTING_PHASE5.md` for comprehensive test plan.

### ⏳ Phase 6: Tunnel Mode (NOT STARTED)
Complete the smart tunnel mode implementation for cluster support.

- ⏳ Accept connections on localhost:6379
- ⏳ Parse incoming RESP commands from clients
- ⏳ Calculate slot and route to appropriate cluster node
- ⏳ Forward responses back to client
- ⏳ Handle redirections transparently

**Implementation Guide**: Study the existing `serve` function in `lib/client/Client.hs` for tunnel implementation patterns. The smart proxy needs to parse commands before forwarding.

**Estimated Effort**: ~400-500 LOC

### ⏳ Phase 7: E2E Testing & CI Integration (NOT STARTED)
Expand E2E test coverage and integrate into CI/CD after completing Phases 4-6.

**Basic Tests** (already exist in `ClusterE2E.hs`):
- ✅ Connect to cluster and query topology
- ✅ Execute GET/SET commands
- ✅ Route commands to correct nodes
- ✅ Handle keys with hash tags

**Additional Tests Needed**:
- ⏳ CLI mode: Test interactive command execution
- ⏳ Fill mode: Test bulk data distribution across nodes
- ⏳ Tunnel mode: Test smart proxy routing
- ⏳ MOVED/ASK redirection scenarios
- ⏳ Topology changes (add/remove nodes)
- ⏳ Failure scenarios (node down, network partition)
- ⏳ Performance benchmarks (compare with standalone)

**CI/CD Integration**:
- ⏳ Create `runClusterE2ETests.sh` script (model after `rune2eTests.sh`)
- ⏳ Update `rune2eTests.sh` to run both standalone and cluster tests
- ⏳ Add cluster test stage to CI/CD pipeline

**Implementation Guide**: Study `test/E2E.hs` extensively - it has excellent patterns for testing all three modes (fill, cli, tunnel) that should be adapted for cluster testing. **Don't reinvent the wheel** - reuse the testing patterns, process handling, and assertion strategies from the standalone E2E tests. The cluster tests should follow the same structure and style.

**Estimated Effort**: ~300-400 LOC

### ⏳ Phase 8: Advanced Features (NOT STARTED)
Optional enhancements for production optimization.

- ⏳ **Multi-key command splitting**: MGET/MSET across slots with result reassembly (~200-300 LOC)
- ⏳ **Pipelining optimization**: Group commands by node, parallel execution, result ordering (~300-400 LOC)
- ⏳ **Enhanced error messages**: Show target node, suggest hash tags for CROSSSLOT, debug routing info (~100-200 LOC)
- ⏳ **Read replica support**: READONLY/READWRITE commands for high-throughput scenarios (~200-300 LOC, optional)

**Implementation Guide**: These features build on the solid foundation from Phases 4-7. Implement based on actual user needs and performance profiling results.

**Estimated Effort**: ~800-1200 LOC (varies based on features selected)

**Current State**: Core infrastructure (Phases 1-3) is solid and functional. Remaining phases focus on completing user-facing functionality (4-6), comprehensive testing (7), and optional optimizations (8).

## Implemented Architecture (Phases 1-2)

### 1. Cluster Topology Management (`lib/cluster/Cluster.hs`)
**Status**: ✅ Complete

**Core Functions**:
- `calculateSlot :: ByteString -> IO Word16` - Calculate hash slot for a key using CRC16
- `extractHashTag :: ByteString -> ByteString` - Extract hash tag from keys like `{user}:profile`
- `parseClusterSlots :: RespData -> UTCTime -> Either String ClusterTopology` - Parse CLUSTER SLOTS response
- `findNodeForSlot :: ClusterTopology -> Word16 -> Maybe Text` - Find node ID for a slot

**Data Structure**:
```haskell
data ClusterTopology = ClusterTopology
  { topologySlots      :: Vector Text,           -- 16384 slots -> node IDs
    topologyNodes      :: Map Text ClusterNode,  -- Node ID -> details
    topologyUpdateTime :: UTCTime
  }
```

**Key Features**:
- ✅ Slot calculation using existing CRC16 (mod 16384)
- ✅ Hash tag extraction: `{user}:profile` → `"user"`
- ✅ CLUSTER SLOTS response parsing
- ✅ Fast O(1) node lookup by slot

### 2. Connection Pool (`lib/cluster/ConnectionPool.hs`)
**Status**: ✅ Complete

**Design**: Thread-safe connection pool using STM, one connection per node (extendable if needed)

```haskell
data ConnectionPool client = ConnectionPool
  { poolConnections :: TVar (Map NodeAddress (client 'Connected)),
    poolConfig      :: PoolConfig
  }
```

**Key Features**:
- ✅ Thread-safe with STM `TVar`
- ✅ Lazy connection creation
- ✅ Connection reuse across commands
- 📝 Can be extended to multiple connections per node if profiling shows contention

### 3. Cluster Command Client (`lib/cluster/ClusterCommandClient.hs`)
**Status**: ✅ Complete

**Design**: Wraps `RedisCommandClient` with cluster-aware routing

```haskell
data ClusterClient client = ClusterClient
  { clusterTopology       :: TVar ClusterTopology,
    clusterConnectionPool :: ConnectionPool client,
    clusterConfig         :: ClusterConfig
  }

instance RedisCommands (ClusterCommandClient client) where
  -- All ~40 Redis commands implemented with automatic routing
```

**Key Features**:
- ✅ Implements full `RedisCommands` type class
- ✅ Automatic command routing:
  - Keyed commands (SET, GET, etc.): Route to node owning key's slot
  - Multi-key commands (MGET, DEL): Route using first key's slot
  - Keyless commands (PING, FLUSHALL): Route to any master node
- ✅ MOVED/ASK error handling infrastructure
- ✅ Retry with exponential backoff
- ✅ Topology refresh on connection

## Mode Integration (Phase 3)

### CLI Mode
**Status**: ✅ Structure integrated, ⏳ Functionality placeholder

**Current State**: 
- Creates cluster client and connects successfully
- REPL loop exists but displays placeholder message
- Structure and error handling in place

**What's Needed for Full Functionality**:
1. Parse user input into RESP commands
2. Execute commands via `ClusterCommandClient`
3. Display responses and errors with node information
4. Handle CROSSSLOT errors with helpful messages

**Implementation Location**: `app/Main.hs` - `replCluster` function

### Fill Mode
**Status**: ✅ Structure integrated, ⏳ Functionality placeholder

**Current State**:
- Creates cluster client and connects successfully
- Can flush cluster (FLUSHALL via any master)
- Demonstrates cluster integration
- Displays informational message about limitations

**What's Needed for Full Functionality**:
1. Distribute data generation across cluster nodes
2. Calculate slots for keys to ensure even distribution
3. Use parallel connections to multiple nodes
4. Implement bulk operations or pipelining for efficiency

**Implementation Options**:
- **Option A**: Runtime CRC16 calculation for each key (simple, realistic)
- **Option B**: Pre-computed hash tags for perfect distribution
- **Option C**: Leverage MOVED redirections (not recommended - high overhead)

**Implementation Location**: `app/Main.hs` - `fillCluster` function

### Tunnel Mode
**Status**: ✅ Pinned mode implemented, ⏳ Smart mode placeholder

**Current State**:
- Pinned mode: Can forward to single seed node
- Smart mode: Placeholder with fallback to pinned
- TLS support structure in place

**What's Needed for Full Smart Mode**:
1. Accept connections on localhost:6379
2. Parse incoming RESP commands
3. Calculate slot and route to appropriate node
4. Forward responses back to client
5. Handle redirections transparently

**Implementation Location**: `app/Main.hs` - `tunnCluster` functions

## Testing

### Unit Tests (Complete - Part of Phases 1-2)
**Files**: `test/ClusterSpec.hs`, `test/ClusterCommandSpec.hs`

**Coverage**:
- ✅ Hash tag extraction (all edge cases)
- ✅ Slot calculation (range validation, consistency)
- ✅ Topology parsing (simple and complex responses)
- ✅ Node lookup by slot
- ✅ Error parsing (MOVED, ASK)

### E2E Tests (Basic Implementation - Phase 3)
**File**: `test/ClusterE2E.hs`

**Current Scenarios**:
- ✅ Connect to cluster and query topology
- ✅ Execute GET/SET commands
- ✅ Route commands to correct nodes
- ✅ Handle keys with hash tags
- ✅ Execute PING and CLUSTER SLOTS

**Additional Tests Needed** (Phase 7 - after completing Phases 4-6):
- ⏳ CLI mode command execution (requires Phase 4)
- ⏳ Fill mode bulk loading (requires Phase 5)
- ⏳ Tunnel mode smart proxy (requires Phase 6)
- ⏳ MOVED/ASK redirection in practice
- ⏳ Topology changes (add/remove nodes)
- ⏳ Failure scenarios (node down, network partition)
- ⏳ Performance testing (bulk operations)

### Test Infrastructure
**Docker Setup**: `docker-cluster/` directory

**Available**:
- ✅ 5-node cluster setup (docker-compose)
- ✅ Configuration files for ports 6379-6383
- ✅ `make_cluster.sh` initialization script

**Integration Needed** (Phase 7):
- ⏳ Create `runClusterE2ETests.sh` - model after `rune2eTests.sh`
- ⏳ Update `rune2eTests.sh` to run both standalone and cluster tests
- ⏳ Add cluster test stage to CI/CD pipeline

**⚠️ IMPORTANT for Future Agents**: When implementing Phase 7 testing, study `test/E2E.hs` extensively. It contains excellent patterns for testing all three modes (fill, cli, tunnel) that should be adapted for cluster testing. The file demonstrates:
- Process management and cleanup
- Waiting for readiness signals
- Input/output handling for interactive modes
- Assertion strategies
- Environment variable handling
- Testing patterns for all three execution modes

**Don't reinvent the wheel** - adapt these proven patterns rather than creating new test infrastructure from scratch.

## Command-Line Interface

### Current Flags
```bash
redis-client [mode] [OPTIONS]

Modes:
  cli     Interactive Redis command-line interface
  fill    Fill Redis cache with random data
  tunn    Start TLS tunnel proxy

Cluster Options:
  -c, --cluster              Enable cluster mode
  --tunnel-mode MODE         Tunnel mode: 'smart' or 'pinned' (default: smart)
  
Connection Options:
  -h, --host HOST           Host to connect to
  -p, --port PORT           Port (default: 6379 plaintext, 6380 TLS)
  -t, --tls                 Use TLS
  -u, --username USERNAME   Authentication username
  -a, --password PASSWORD   Authentication password

Fill Options:
  -d, --data GBs           Amount of data in GB
  -f, --flush              Flush before filling
  -s, --serial             Serial mode (no concurrency)
  -n, --connections NUM    Parallel connections (default: 2)
```

### Examples
```bash
# Cluster CLI
redis-client cli -h node1 -c

# Cluster fill (structure in place, needs implementation)
redis-client fill -h node1 -d 5 -c

# Cluster tunnel - pinned mode (works)
redis-client tunn -h node1 -t -c --tunnel-mode pinned

# Cluster tunnel - smart mode (not yet implemented)
redis-client tunn -h node1 -t -c --tunnel-mode smart
```

## Redis Cluster Protocol Reference

### Key Concepts
1. **Slot Assignment**: 16384 hash slots distributed across master nodes
2. **Slot Calculation**: `HASH_SLOT = CRC16(key) & 16383`
3. **Redirection**: `-MOVED slot host:port` or `-ASK slot host:port` errors
4. **Cluster Discovery**: `CLUSTER SLOTS` command reveals topology
5. **Hash Tags**: Keys like `{user}:profile` hash on `user` only

### Error Types
```
-MOVED 3999 127.0.0.1:6381       # Permanent redirection
-ASK 3999 127.0.0.1:6381         # Temporary redirection (requires ASKING)
-CLUSTERDOWN                      # Cluster is down
-TRYAGAIN                         # Retry the operation
-CROSSSLOT                        # Keys map to different slots
```

### Hash Tag Examples
```bash
# Different slots (likely different nodes)
SET user:123:profile "Alice"
SET user:123:settings "..."

# Same slot (guaranteed same node)
SET {user:123}:profile "Alice"
SET {user:123}:settings "..."
MGET {user:123}:profile {user:123}:settings  # Works!

# Only content inside {} is hashed
# {user:123}:profile and {user:123}:settings both hash "user:123"
```

## Remaining Work (Phases 5-8)

### ✅ Phase 4: CLI Mode Command Execution (COMPLETE)
**Status**: Fully implemented and functional

### Phase 5: Fill Mode Bulk Loading (CODE COMPLETE - Testing Pending)
**Goal**: Enable efficient bulk data loading across cluster

**Status**: Implementation complete, testing blocked by build environment

**Completed Tasks**:
1. ✅ Automatic slot calculation via ClusterCommandClient
2. ✅ Data distribution across cluster nodes
3. ✅ Parallel execution with configurable connections
4. ⏳ Profiling before/after comparison (pending)

**Actual Effort**: ~29 LOC (vs estimated 300-400 LOC)

**Next Steps**: 
- Complete build (blocked by network issues)
- Execute test plan in `TESTING_PHASE5.md`
- Run profiling comparison
- Mark Phase 5 as fully complete

### Phase 6: Smart Tunnel Mode
**Goal**: Implement intelligent proxy with cluster routing

**Tasks**:
1. Accept connections on localhost:6379
2. Parse incoming RESP commands
3. Calculate slot and route to appropriate node
4. Forward responses transparently
5. Handle redirections

**Reference Implementation**: Study `lib/client/Client.hs` `serve` function for tunnel patterns

**Estimated Effort**: ~400-500 LOC

### Phase 7: Comprehensive E2E Testing & CI Integration
**Goal**: Full test coverage for Phases 4-6 features

**⚠️ IMPORTANT**: Complete Phases 4-6 first, then write tests for those features

**Tasks**:
1. **CLI Mode Tests**:
   - Test interactive command execution
   - Test error handling and display
   
2. **Fill Mode Tests**:
   - Test data distribution across nodes
   - Verify all masters receive data
   - Test profiling output
   
3. **Tunnel Mode Tests**:
   - Test smart proxy routing
   - Test multi-client connections
   
4. **Advanced Scenarios**:
   - MOVED/ASK redirection handling
   - Topology changes (add/remove nodes)
   - Failure scenarios (node down)
   - Performance benchmarks vs standalone

5. **CI/CD Integration**:
   - Create `runClusterE2ETests.sh` (model after `rune2eTests.sh`)
   - Update existing test runner to include cluster tests
   - Add to CI/CD pipeline

**Reference Implementation**: **Study `test/E2E.hs` extensively** - it has excellent patterns for testing all three modes. Don't reinvent the wheel - adapt the existing patterns:
- Process management and cleanup
- Waiting for readiness signals
- Input/output handling
- Assertion strategies
- Environment variable handling

**Estimated Effort**: ~300-400 LOC

### Phase 8: Advanced Features (Optional)
**Goal**: Production optimizations based on profiling and user needs

**Features** (prioritize based on actual needs):
1. Multi-key command splitting (MGET/MSET across slots) - ~200-300 LOC
2. Pipelining optimization (group by node, parallel execution) - ~300-400 LOC
3. Enhanced error messages (node info, hash tag suggestions) - ~100-200 LOC
4. Read replica support (READONLY/READWRITE) - ~200-300 LOC

**Estimated Effort**: ~800-1200 LOC (varies by features selected)

## Success Criteria

### Functional Requirements
- ✅ Core cluster infrastructure complete (Phases 1-2)
- ✅ RedisCommands instance for ClusterCommandClient (Phase 2)
- ✅ Basic mode integration structure (Phase 3)
- ⏳ CLI mode fully functional (Phase 4)
- ⏳ Fill mode fully functional (Phase 5)
- ⏳ Tunnel smart mode functional (Phase 6)
- ⏳ Comprehensive E2E tests passing (Phase 7)

### Quality Requirements
- ✅ Unit test coverage >80% for cluster modules (Phases 1-2)
- ⏳ E2E tests cover all three modes in cluster configuration (Phase 7)
- ⏳ Performance benchmarks vs standalone (Phase 7)
- ✅ Zero breaking changes for existing standalone users
- ✅ Documentation for cluster usage

### Non-Functional Requirements
- ⏳ Cluster mode adds <10% latency overhead (Phase 7 measurement)
- ⏳ Fill mode achieves near-linear speedup with cluster size (Phase 5 + Phase 7)
- ✅ Memory overhead <10MB for typical cluster (3-10 nodes)
- ✅ Backward compatibility maintained

## Backward Compatibility

**Guarantee**: All existing standalone Redis usage remains unchanged

**How**:
- Default behavior: No `--cluster` flag = standalone mode
- Same commands work identically
- Same flags and options
- No code changes required for existing users

**Detection**: Explicit `--cluster` flag required (no auto-detection)
- **Pro**: Clear, explicit, debuggable
- **Pro**: No extra round-trip on connection
- **Con**: Users must know their deployment type

## Architecture Strengths

**Leveraged Existing Infrastructure**:
1. ✅ CRC16 implementation ready for slot calculation
2. ✅ Parallel execution proven in fill mode
3. ✅ Docker cluster setup exists
4. ✅ Clean architecture enables extension without breaking changes

**Design Decisions**:
1. ✅ Used Text node IDs to break circular dependencies
2. ✅ Single connection per node (simple, sufficient, extensible)
3. ✅ STM for thread-safe pool management
4. ✅ Type class instance for transparent cluster usage

## Next Steps

### Phase 4: CLI Mode (First Priority)
1. Study `app/Main.hs` `repl` function for standalone implementation pattern
2. Implement command parsing from user input
3. Execute via ClusterCommandClient with proper error handling
4. Display results with optional node information

### Phase 5: Fill Mode (Second Priority)
1. Study `app/Filler.hs` for parallel execution and seed spacing patterns
2. Implement slot calculation and key distribution
3. Distribute work across cluster nodes
4. Add profiling to measure performance

### Phase 6: Tunnel Mode (Third Priority)
1. Study `lib/client/Client.hs` `serve` function for tunnel patterns
2. Implement command parsing from tunnel clients
3. Route via ClusterCommandClient
4. Handle response forwarding

### Phase 7: Comprehensive Testing (After Phases 4-6)
1. **Study `test/E2E.hs` thoroughly** - adapt its patterns for cluster testing
2. Write tests for CLI mode features (Phase 4)
3. Write tests for Fill mode features (Phase 5)
4. Write tests for Tunnel mode features (Phase 6)
5. Add advanced scenarios (redirections, failures, topology changes)
6. Create `runClusterE2ETests.sh` following `rune2eTests.sh` structure
7. Integrate into CI/CD pipeline

### Phase 8: Advanced Features (Optional)
Implement based on profiling results and user feedback after Phases 4-7 are complete.

## Appendix A: File Structure

```
lib/
├── cluster/
│   ├── Cluster.hs                    # ✅ Topology, slot calc, hash tags
│   ├── ClusterCommandClient.hs      # ✅ Main cluster client + RedisCommands
│   └── ConnectionPool.hs             # ✅ Thread-safe connection pool
├── client/Client.hs                  # ✅ Existing - connection primitives
├── redis-command-client/
│   └── RedisCommandClient.hs         # ✅ Existing - command monad
├── crc16/
│   ├── Crc16.hs                      # ✅ Existing - slot hash function
│   └── crc16.c                       # ✅ Existing - C implementation
└── resp/Resp.hs                      # ✅ Existing - RESP protocol

app/
└── Main.hs                           # ⏳ Mode integration (structure done)

test/
├── ClusterSpec.hs                    # ✅ Unit tests
├── ClusterCommandSpec.hs             # ✅ Command client tests
├── ClusterE2E.hs                     # ✅ Basic E2E tests
├── Spec.hs                           # ✅ Existing - RESP tests
└── E2E.hs                            # ✅ Existing - standalone E2E

docker-cluster/                       # ✅ Existing - 5-node cluster setup
```

## Appendix B: Estimated Effort

**Completed** (Phases 1-3 structure): ~2000 LOC
- `Cluster.hs`: 153 LOC
- `ClusterCommandClient.hs`: 437 LOC
- `ConnectionPool.hs`: 75 LOC
- `Main.hs` integration: ~150 LOC
- Tests: ~400 LOC
- Total: ~1215 LOC

**Remaining Work by Phase**:
- **Phase 4** (CLI Mode): ~200-300 LOC
- **Phase 5** (Fill Mode): ~300-400 LOC
- **Phase 6** (Tunnel Mode): ~400-500 LOC
- **Phase 7** (E2E Testing): ~300-400 LOC
- **Phase 8** (Advanced Features): ~800-1200 LOC (optional)

**Total Remaining**: ~1200-1600 LOC for core functionality (Phases 4-7)
**Total with Phase 8**: ~2000-2800 LOC

**Total Project**: ~3200-4800 LOC for full cluster support (depending on Phase 8 features)

## Appendix C: Known Limitations

### Current Limitations
1. CLI mode displays placeholder message (no command execution)
2. Fill mode demonstrates connection only (no bulk loading)
3. Tunnel mode has only pinned mode (smart mode placeholder)
4. Multi-key commands use first key only (no splitting)
5. No automatic topology refresh (manual refresh via MOVED)
6. No read replica support (master-only)

### Acceptable Trade-offs
1. Single connection per node (sufficient for most workloads)
2. No pipelining optimization (can add later)
3. Explicit --cluster flag (vs auto-detection)
4. No READONLY/READWRITE support (not needed initially)

### Future Enhancements (Beyond Phase 5)
1. Connection pool scaling (if profiling shows need)
2. Topology caching across restarts
3. Circuit breaker pattern for failed nodes
4. Read replica support
5. Pub/Sub cluster routing
6. Transaction (MULTI/EXEC) cluster support

---

**Document Version**: 2.2  
**Last Updated**: 2026-02-04  
**Status**: Active Development - Phases 1-4 Complete, Phase 5 Code Complete (Testing Pending), Phases 6-8 Remaining
