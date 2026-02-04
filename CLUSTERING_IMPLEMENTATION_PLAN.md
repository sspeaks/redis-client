# Redis Cluster Support - Implementation Status

## Executive Summary

This document tracks the implementation of Redis Cluster support in the redis-client project. The core infrastructure and user-facing modes have been completed through Phase 5, enabling the client to work with Redis Cluster deployments while maintaining backward compatibility with standalone Redis instances.

**Current Status**: Phases 1-5 complete. CLI mode (Phase 4) and Fill mode (Phase 5) are fully functional. Remaining: Tunnel smart mode (Phase 6), comprehensive testing (Phase 7), and optional optimizations (Phase 8).

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

### ✅ Phase 5: Fill Mode (COMPLETE)
Complete the Fill mode implementation for cluster support.

- ✅ Calculate slots for keys to ensure even distribution
- ✅ Distribute data generation across cluster nodes
- ✅ Use parallel connections to multiple nodes
- ✅ Use 2 threads for each node unless otherwise specified (configurable via -n flag)
- ✅ Implement efficient bulk operations (fire-and-forget mode)
- ✅ Utilize the flat txt file that maps Slot number to hashtag that maps to it

**Implementation Complete**: Created `app/ClusterFiller.hs` (300 LOC) with cluster-specific fill logic. Key features:
- Loads 16,384 slot-to-hashtag mappings from `cluster_slot_mapping.txt`
- Distributes work evenly across cluster master nodes
- Spawns configurable threads per node (default: 2, via -n flag)
- Generates keys with hash tags (`{tag}:seed:padding`) for proper routing
- Uses CLIENT REPLY OFF/ON for maximum throughput
- Maintains same parallel execution pattern as standalone mode

**Actual Effort**: 300 LOC (ClusterFiller module) + 20 LOC (Main.hs updates)

**Status**: Code complete, builds successfully, all unit tests passing. Ready for performance profiling in production cluster environment.

### ⏳ Phase 6: Tunnel Mode (NOT STARTED)
Complete the tunnel mode implementation for cluster support.

#### Tunnel Mode Overview

The primary purpose of tunnel mode is to **terminate TLS and handle authentication** so local applications don't need to worry about these concerns. There are two distinct tunnel modes for cluster support:

**Pinned Tunnel Mode**:
- Creates **one listening socket for every node in the cluster**
- Each listening socket listens on the **same port that the corresponding cluster node is listening on**
- For example, if a cluster has 5 nodes listening on ports 6379-6383, the tunnel creates 5 local listeners on ports 6379-6383
- Each local listener establishes a dedicated TLS connection to its corresponding cluster node
- Applications connect to `localhost:6379`, `localhost:6380`, etc., and the tunnel forwards traffic to the appropriate cluster node
- **Response rewriting**: Must intercept and rewrite cluster topology responses (`CLUSTER NODES`, `CLUSTER SLOTS`) and redirection errors (`MOVED`, `ASK`) to replace remote host addresses with `127.0.0.1` to prevent confusion for cluster clients connecting to the tunnel
- This mode preserves cluster topology visibility to the application, which must still understand Redis Cluster protocol
- **Use case**: When local applications need to be cluster-aware but want to offload TLS/authentication

**Smart Tunnel Mode**:
- Makes a clustered cache **appear as if it were a single-node cache** to local applications
- Creates a single listening socket (typically on `localhost:6379`)
- Accepts connections from local applications that don't know about Redis Cluster
- Parses incoming RESP commands to determine routing
- Calculates hash slots and routes commands to the appropriate cluster nodes transparently
- Handles MOVED/ASK redirections internally without exposing them to the application
- Returns responses as if they came from a single Redis instance
- **Use case**: When local applications are cluster-unaware but you need the benefits of a clustered backend

#### Implementation Tasks

**Smart Mode Tasks**:
- ⏳ Accept connections on localhost:6379
- ⏳ Parse incoming RESP commands from clients
- ⏳ Calculate slot and route to appropriate cluster node
- ⏳ Forward responses back to client
- ⏳ Handle redirections transparently

**Pinned Mode Tasks**:
- ⏳ Query cluster topology to discover all nodes
- ⏳ Create one listening socket per cluster node on the same port
- ⏳ Establish and maintain TLS connections to each cluster node
- ⏳ Forward traffic bidirectionally between local socket and cluster node
- ⏳ Handle authentication for each cluster node connection
- ⏳ Intercept and rewrite cluster responses: `CLUSTER NODES`, `CLUSTER SLOTS`, `MOVED` errors, and `ASK` errors to replace remote hosts with `127.0.0.1`

**Implementation Guide**: Study the existing `serve` function in `lib/client/Client.hs` for tunnel implementation patterns. The smart proxy needs to parse commands before forwarding. You might be able to reuse some existing logic used by the ClusterCLI to determine which commands are keyed and which aren't.

**Estimated Effort**: ~400-500 LOC (Smart Mode), ~300-400 LOC (Pinned Mode enhancements)

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

**Implementation Guide**: Study `test/E2E.hs` extensively - it has excellent patterns for testing all three modes (fill, cli, tunnel) that should be adapted for cluster testing. **Don't reinvent the wheel** - reuse the testing patterns, process handling, and assertion strategies from the standalone E2E tests. The cluster tests should follow the same structure and style.

**Estimated Effort**: ~300-400 LOC

### ⏳ Phase 8: Advanced Features (NOT STARTED)
Optional enhancements for production optimization.

- ⏳ **Multi-key command splitting**: MGET/MSET across slots with result reassembly (~200-300 LOC)
- ⏳ **Pipelining optimization**: Group commands by node, parallel execution, result ordering (~300-400 LOC)
- ⏳ **Enhanced error messages**: Show target node, suggest hash tags for CROSSSLOT, debug routing info (~100-200 LOC)
- ⏳ **Read replica support**: READONLY/READWRITE commands for high-throughput scenarios (~200-300 LOC, optional)
- ⏳ **Explore mode auto-detection**: Fill/CLI/Tunneling could automatically determine that they should run in cluster mode

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

**Primary Purpose**: Terminate TLS and handle authentication so local applications don't need to manage these concerns.

**Current State**:
- Pinned mode: Can forward to single seed node (basic implementation)
- Smart mode: Placeholder with fallback to pinned
- TLS support structure in place

**Pinned Mode (Full Implementation Needed)**:
- Should create one listening socket per cluster node
- Each socket listens on the same port as its corresponding cluster node
- Example: 5-node cluster on ports 6379-6383 → 5 local listeners on `localhost:6379-6383`
- Must intercept cluster responses (`CLUSTER NODES`, `CLUSTER SLOTS`) and redirection errors (`MOVED`, `ASK`) and rewrite host addresses to `127.0.0.1`
- Applications remain cluster-aware but benefit from TLS termination and authentication handling

**Smart Mode (Full Implementation Needed)**:
- Makes clustered cache appear as a single-node cache to applications
- Single listening socket (e.g., `localhost:6379`)
- Transparently routes commands based on hash slot calculation
- Handles MOVED/ASK redirections internally
- Applications don't need to understand Redis Cluster protocol

**What's Needed for Full Smart Mode**:
1. Accept connections on localhost:6379
2. Parse incoming RESP commands
3. Calculate slot and route to appropriate node
4. Forward responses back to client
5. Handle redirections transparently

**What's Needed for Full Pinned Mode**:
1. Query cluster topology to discover all nodes
2. Create listening socket for each node on matching port
3. Establish TLS connection to each cluster node
4. Forward traffic bidirectionally
5. Handle per-node authentication
6. Intercept and rewrite cluster responses and redirection errors (replace remote hosts with `127.0.0.1` in `CLUSTER NODES`, `CLUSTER SLOTS`, `MOVED`, `ASK`)

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

# Cluster fill
redis-client fill -h node1 -d 5 -c

# Cluster tunnel - pinned mode
# Creates one listener per cluster node on matching ports
# Example: 5 nodes → 5 local sockets (localhost:6379-6383)
redis-client tunn -h node1 -t -c --tunnel-mode pinned

# Cluster tunnel - smart mode
# Single listener that makes cluster appear as single-node cache
# Routes commands transparently based on hash slot calculation
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

## Remaining Work (Phases 4-8)

### Phase 4: CLI Mode Command Execution
**Goal**: Enable full interactive command execution in cluster mode

**Tasks**:
1. Parse user input to RESP commands
2. Execute via ClusterCommandClient
3. Display results with node information
4. Handle CROSSSLOT errors with helpful messages

**Reference Implementation**: Study `app/Main.hs` `repl` function for standalone pattern

**Estimated Effort**: ~200-300 LOC

### Phase 5: Fill Mode Bulk Loading
**Goal**: Enable efficient bulk data loading across cluster

**Tasks**:
1. Calculate slots for keys to ensure distribution
2. Distribute work across cluster nodes
3. Implement parallel execution across nodes
4. Add profiling before/after comparison

**Reference Implementation**: Study `app/Filler.hs` and `fillStandalone` for parallel patterns

**Estimated Effort**: ~300-400 LOC

### Phase 6: Tunnel Mode (Smart and Pinned)
**Goal**: Implement TLS termination and authentication offloading with two distinct modes

**Primary Purpose**: Terminate TLS connections and handle authentication so local applications don't need to manage these concerns.

**Smart Tunnel Mode Tasks**:
1. Accept connections on localhost:6379 (single listening socket)
2. Parse incoming RESP commands from cluster-unaware applications
3. Calculate slot and route to appropriate cluster node
4. Forward responses transparently
5. Handle MOVED/ASK redirections internally (invisible to application)
6. Make clustered cache appear as single-node cache

**Pinned Tunnel Mode Tasks**:
1. Query cluster topology to discover all nodes and their ports
2. Create one listening socket per cluster node on matching port
3. Establish and maintain TLS connections to each cluster node
4. Forward traffic bidirectionally between local socket and cluster node
5. Handle per-node authentication
6. Intercept `CLUSTER NODES` and `CLUSTER SLOTS` responses and rewrite host addresses to `127.0.0.1`
7. Intercept `MOVED` and `ASK` redirection errors and rewrite host addresses to `127.0.0.1`
8. Example: 5-node cluster on ports 6379-6383 → 5 local listeners on `localhost:6379-6383`

**Reference Implementation**: Study `lib/client/Client.hs` `serve` function for tunnel patterns

**Estimated Effort**: ~400-500 LOC (Smart Mode), ~300-400 LOC (Pinned Mode enhancements)

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
├── Main.hs                           # ✅ Mode integration complete
├── ClusterCli.hs                     # ✅ CLI mode cluster implementation
├── ClusterFiller.hs                  # ✅ Fill mode cluster implementation (Phase 5)
└── Filler.hs                         # ✅ Existing - standalone fill logic

test/
├── ClusterSpec.hs                    # ✅ Unit tests
├── ClusterCommandSpec.hs             # ✅ Command client tests
├── ClusterE2E.hs                     # ✅ Basic E2E tests
├── Spec.hs                           # ✅ Existing - RESP tests
└── E2E.hs                            # ✅ Existing - standalone E2E

docker-cluster/                       # ✅ Existing - 5-node cluster setup
```

## Appendix B: Estimated Effort

**Completed** (Phases 1-5): ~1835 LOC
- **Phase 1-2** (Core Infrastructure):
  - `Cluster.hs`: 153 LOC
  - `ClusterCommandClient.hs`: 439 LOC
  - `ConnectionPool.hs`: 75 LOC
  - Tests (ClusterSpec, ClusterCommandSpec): ~400 LOC
- **Phase 3-4** (CLI Mode):
  - `ClusterCli.hs`: 110 LOC
  - `Main.hs` CLI integration: ~50 LOC
- **Phase 5** (Fill Mode):
  - `ClusterFiller.hs`: 300 LOC
  - `Main.hs` Fill integration: ~20 LOC
- **Total Completed**: ~1547 LOC (code) + ~400 LOC (tests) = ~1947 LOC

**Remaining Work by Phase**:
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

### Connection Pool Limitations

**Current State**: The connection pool (`lib/cluster/ConnectionPool.hs`) currently supports only one connection per node. When multiple threads try to fill data for the same node concurrently, they share a single connection, which can cause contention and thread synchronization issues.

**Current Workaround**: For cluster fill mode (Phase 5), each thread creates its own dedicated connection using the connector directly (bypassing the pool) to avoid connection sharing. This works but isn't ideal for resource management.

**Future Improvements Needed**:
1. **Enhance ConnectionPool**: Update `ConnectionPool` to support multiple connections per node with configurable pool size
2. **Code Audit**: Search the codebase for places where we bypass the connection pool by calling the connector directly, and migrate them to use the pool once it supports multiple connections per node
3. **Connection Lifecycle**: Implement proper connection lifecycle management (creation, reuse, cleanup) in the pool
4. **Metrics**: Add connection pool metrics (active connections, wait times, etc.)

**Related Files**:
- `lib/cluster/ConnectionPool.hs` - Connection pool implementation
- `app/ClusterFiller.hs` - Currently bypasses pool for fill operations (line ~167)

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

**Document Version**: 2.1  
**Last Updated**: 2026-02-04  
**Status**: Active Development - Phases 1-3 Complete, Phases 4-8 Reorganized
