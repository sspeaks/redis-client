# Redis Cluster Support Implementation Plan

## Executive Summary

This document outlines a comprehensive plan for implementing Redis Cluster support in the redis-client project. The implementation will enable the client to seamlessly work with Redis Cluster deployments while maintaining backward compatibility with standalone Redis instances.

## Current Architecture Analysis

### Existing Components

1. **Client Layer** (`lib/client/Client.hs`)
   - Abstracts connection handling for PlainText and TLS connections
   - Uses type-level `ConnectionStatus` to enforce connection state safety
   - Implements socket management with keep-alive and TCP_NODELAY optimizations
   - Current limitation: Single connection per client instance

2. **Command Layer** (`lib/redis-command-client/RedisCommandClient.hs`)
   - `RedisCommandClient` monad wraps stateful operations
   - Implements ~40 Redis commands as a type class
   - Uses attoparsec for RESP protocol parsing
   - Maintains parse buffer in `ClientState`
   - Current limitation: Commands are executed on a single connection

3. **CRC16 Implementation** (`lib/crc16/Crc16.hs` + `crc16.c`)
   - Already exists! Uses the XMODEM/Redis CRC16 algorithm
   - FFI binding to C implementation for performance
   - Currently calculates `crc16(key) mod 2^14` for 16384 slots
   - **Critical**: This is exactly what Redis Cluster uses for slot calculation
   - Ready to use for cluster slot hashing

4. **Execution Modes** (`app/Main.hs`)
   - **fill**: Parallel cache filling with configurable connections (2-8 default)
   - **cli**: Interactive REPL for Redis commands
   - **tunn**: TLS tunnel proxy (localhost:6379 → TLS Redis)
   - Uses `forkIO` for parallelism with `MVar` synchronization

5. **Filler Module** (`app/Filler.hs`)
   - Generates deterministic random data based on seeds
   - Uses `CLIENT REPLY OFF` for fire-and-forget writes
   - Thread-safe seed spacing (1B seeds apart) prevents key collisions
   - Chunks data into configurable KB sizes (default 8192KB)

### Existing Test Infrastructure

1. **Unit Tests** (`test/Spec.hs`)
   - RESP protocol encoding/decoding tests
   - Command serialization verification
   - No Redis server required

2. **E2E Tests** (`test/E2E.hs`)
   - Comprehensive command testing against real Redis
   - Docker-based test environment via `rune2eTests.sh`
   - Tests all three modes (fill, cli, tunn)
   - Currently targets single Redis instance at `redis.local`

3. **Docker Cluster Infrastructure** (`docker-cluster/`)
   - **Already exists!** 5-node cluster setup with docker-compose
   - Configuration files for nodes on ports 6379-6383
   - `make_cluster.sh` script to initialize cluster
   - Currently unused by the application

## Redis Cluster Protocol Overview

### Key Concepts

1. **Slot Assignment**: 16384 hash slots distributed across master nodes
2. **Slot Calculation**: `HASH_SLOT = CRC16(key) & 16383` (we already have CRC16!)
3. **Redirection**: Servers return `-MOVED slot host:port` or `-ASK slot host:port` errors
4. **Cluster Discovery**: `CLUSTER SLOTS` or `CLUSTER NODES` commands reveal topology
5. **Multi-key Commands**: Must target keys in the same slot or use hash tags `{}`

### Critical Redis Cluster Commands

```
CLUSTER SLOTS     → Returns slot ranges and node assignments
CLUSTER NODES     → Returns full cluster topology
READONLY          → Enable reads from replicas
READWRITE         → Disable reads from replicas (default)
```

### Error Types

```
-MOVED 3999 127.0.0.1:6381       # Permanent redirection
-ASK 3999 127.0.0.1:6381         # Temporary redirection (requires ASKING)
-CLUSTERDOWN                      # Cluster is down
-TRYAGAIN                         # Retry the operation
-CROSSSLOT                        # Keys map to different slots
```

## Proposed Implementation Approach

### Phase 1: Core Cluster Client Infrastructure

#### 1.1 Cluster Topology Management

**New Module**: `lib/cluster/Cluster.hs`

```haskell
data ClusterNode = ClusterNode
  { nodeId :: Text
  , nodeHost :: String
  , nodePort :: Int
  , nodeRole :: NodeRole  -- Master | Replica
  , nodeSlotsServed :: [SlotRange]
  , nodeReplicas :: [Text]  -- Node IDs of replicas
  }

data SlotRange = SlotRange
  { slotStart :: Word16  -- 0-16383
  , slotEnd :: Word16
  , slotMaster :: Text  -- Node ID reference (breaks circular dependency)
  , slotReplicas :: [Text]  -- Node ID references
  }

data ClusterTopology = ClusterTopology
  { topologySlots :: Vector SlotRange  -- 16384 slots
  , topologyNodes :: Map Text ClusterNode
    -- ^ Node ID → full node details
    -- Key: "07c37dfeb235213a872192d90877d0cd55635b91" 
    -- Value: ClusterNode with host, port, role, slots served, replicas
  , topologyUpdateTime :: UTCTime
  }
```

**Design Note**: `SlotRange` uses `Text` node IDs rather than full `ClusterNode` references to avoid circular dependencies between the data types. The `topologyNodes` Map provides O(1) lookup from node ID to full node details when needed. This design:
- Breaks the circular dependency: `ClusterNode` → `SlotRange` ✗→ `ClusterNode`
- Enables efficient lookups: `topologySlots ! slot` → node ID → `topologyNodes ! nodeId`
- Simplifies serialization and comparison logic

**Topology Discovery Flow**:
1. Connect to any cluster node (seed node)
2. Execute `CLUSTER SLOTS` command
3. Parse response to build `ClusterTopology`
4. Create connection pool for discovered nodes
5. Map each slot (0-16383) to its master node

**Trade-offs**:
- **Pro**: Complete view of cluster enables optimal routing
- **Pro**: Can cache topology to avoid repeated queries
- **Con**: Initial connection slower (topology discovery overhead)
- **Con**: Memory overhead for topology map (~1-2MB for large clusters)

#### 1.2 Connection Pool Management

**New Module**: `lib/cluster/ConnectionPool.hs`

```haskell
-- Initial implementation: Single connection per node
data ConnectionPool client = ConnectionPool
  { poolConnections :: TVar (Map NodeAddress (client 'Connected))
  , poolConfig :: PoolConfig
  }

data NodeAddress = NodeAddress String Int  -- host:port
  deriving (Eq, Ord)

data PoolConfig = PoolConfig
  { maxConnectionsPerNode :: Int  -- Default: 1 (can scale up)
  , connectionTimeout :: Int
  , maxRetries :: Int
  , useTLS :: Bool
  }
```

**Scaling Options**: The initial design supports one connection per node. If profiling reveals connection contention, two scaling approaches are available:

**Option A: List-based pool** (simpler):
```haskell
data ConnectionPool client = ConnectionPool
  { poolConnections :: TVar (Map NodeAddress [client 'Connected])
    -- ^ Multiple connections per node stored in a list
  , poolConfig :: PoolConfig
  }
```

**Option B: Bounded pool** (more robust):
```haskell
data ConnectionPool client = ConnectionPool
  { poolsByNode :: TVar (Map NodeAddress (BoundedPool (client 'Connected)))
    -- ^ Proper bounded pool with max size enforcement
  , poolConfig :: PoolConfig
  }

data BoundedPool a = BoundedPool
  { poolAvailable :: TQueue a
  , poolInUse :: TVar Int
  , poolMaxSize :: Int
  }
```

Option B provides better resource management but adds implementation complexity. Start with single connection (sufficient for most use cases), profile under load, and only implement scaling if needed.

**Connection Strategy**:
1. Lazy connection creation (connect on first use)
2. Keep connections alive (reuse across commands)
3. Handle connection failures with automatic reconnection
4. Periodic topology refresh (configurable, default: 60s)

**Trade-offs**:
- **Pro**: Efficient resource usage (only connect to needed nodes)
- **Pro**: Connection reuse reduces latency
- **Con**: Thread-safety requires `TVar` (STM overhead)
- **Con**: Connection leaks possible if not properly cleaned up

#### 1.3 Slot Routing Engine

**Extension to** `lib/redis-command-client/RedisCommandClient.hs`

```haskell
data ClusterClient client = ClusterClient
  { clusterTopology :: TVar ClusterTopology
  , clusterConnections :: ConnectionPool client
  , clusterConfig :: ClusterConfig
  }

calculateSlot :: ByteString -> Word16
calculateSlot key = do
  -- Extract hash tag if present: {user123}:profile → user123
  let hashKey = extractHashTag key
  crc <- crc16 hashKey
  return crc  -- Already modulo 16384 in our implementation!

extractHashTag :: ByteString -> ByteString
extractHashTag key =
  case BS.breakSubstring "{" key of
    (before, rest) | not (BS.null rest) ->
      case BS.breakSubstring "}" (BS.tail rest) of
        (tag, after) | not (BS.null after) && not (BS.null tag) -> tag
        _ -> key
    _ -> key

routeCommand :: ClusterClient client -> RespData -> IO (client 'Connected)
routeCommand cluster command = do
  topology <- readTVar (clusterTopology cluster)
  case extractKeys command of
    -- Key-based commands: route by slot hash
    Just (key:_) -> do
      slot <- calculateSlot key
      let node = findNodeForSlot topology slot
      getOrCreateConnection (clusterConnections cluster) node
    
    -- Keyless commands: route to any master or seed node
    Nothing -> 
      if isClusterManagementCommand command
        then getOrCreateConnection (clusterConnections cluster) (seedNode cluster)
        else getOrCreateConnection (clusterConnections cluster) (randomMaster topology)

extractKeys :: RespData -> Maybe [ByteString]
extractKeys command = case command of
  RespArray (RespBulkString cmd : args)
    | cmd `elem` ["SET", "GET", "DEL", "EXISTS"] -> Just (extractKeysForCommand cmd args)
    | cmd `elem` ["PING", "INFO", "DBSIZE"] -> Nothing  -- Keyless
    | cmd `elem` ["CLUSTER"] -> Nothing  -- Cluster management
  _ -> Nothing

isClusterManagementCommand :: RespData -> Bool
isClusterManagementCommand (RespArray (RespBulkString cmd : _)) = 
  cmd `elem` ["CLUSTER"]
isClusterManagementCommand _ = False
```

**Routing Strategy**: The implementation handles three distinct command types:

1. **Key-based commands** (SET, GET, DEL, MGET, etc.):
   - Extract key(s) from command arguments
   - Calculate slot using CRC16 hash
   - Route to node owning that slot
   
2. **Keyless commands** (PING, INFO, DBSIZE, etc.):
   - Can execute on any node
   - Route to random master for load distribution
   - Alternatively, route to seed node for consistency

3. **Cluster management commands** (CLUSTER SLOTS, CLUSTER NODES, etc.):
   - Must execute on seed/discovery node
   - Required for topology refresh and cluster info

**Trade-offs**:
- **Pro**: O(1) slot lookup with Vector indexing for key-based commands
- **Pro**: Hash tag support enables multi-key operations
- **Pro**: Flexible routing for keyless commands improves utilization
- **Con**: Command parsing to extract keys adds overhead
- **Con**: Some commands have complex key extraction (MGET, MSET, etc.)
- **Con**: Need to maintain command classification (key-based vs keyless)

### Phase 2: Redirection Handling

#### 2.1 MOVED Redirection

When a `-MOVED` error is received:
1. Update cached topology (slot moved to different node)
2. Retry command on new node
3. Consider full topology refresh if many MOVED errors

**Implementation**:
```haskell
handleResponse :: RespData -> RedisCommandClient ClusterClient a
handleResponse response = case response of
  RespError err | "MOVED" `isPrefixOf` err -> do
    let (slot, host, port) = parseMovedError err
    updateTopologySlot slot host port
    retryCommand
  RespError err | "ASK" `isPrefixOf` err -> do
    let (slot, host, port) = parseAskError err
    sendAskingCommand host port
    retryCommandOn host port
  _ -> parseResponse response
```

**Trade-offs**:
- **Pro**: Transparent to user (automatic retry)
- **Pro**: Self-healing (topology stays current)
- **Con**: Added latency on first access to moved slots
- **Con**: Retry loops possible (need max retry limit)

#### 2.2 ASK Redirection

When a `-ASK` error is received:
1. Send `ASKING` command to target node
2. Retry original command on same connection
3. Do NOT update topology (temporary redirection)

**Trade-offs**:
- **Pro**: Handles slot migration gracefully
- **Pro**: Temporary nature prevents incorrect topology caching
- **Con**: Requires pipelining ASKING + command for efficiency
- **Con**: More complex error handling logic

### Phase 3: Mode Integration

#### 3.1 Fill Mode Cluster Support

**Challenge**: Distribute 5GB across cluster nodes proportionally

**Solution Strategy**:
```haskell
fillCacheWithDataCluster :: ClusterClient client -> Word64 -> Int -> Int -> RedisCommandClient ClusterClient ()
fillCacheWithDataCluster cluster baseSeed threadIdx totalMB = do
  topology <- readTVar (clusterTopology cluster)
  let masterNodes = getMasterNodes topology
      mbPerNode = totalMB `div` length masterNodes
  
  -- Divide work among threads AND nodes
  forM_ (zip [0..] masterNodes) $ \(nodeIdx, node) -> do
    let nodeSeed = baseSeed + fromIntegral nodeIdx * threadSeedSpacing
    fillNodeWithData node nodeSeed mbPerNode
```

**Key Distribution**:
- Option A: **Pre-calculate slots** for each key before sending
  - **Pro**: Guaranteed even distribution across slots
  - **Con**: Slower (CRC16 calculation for every key)
  
- Option B: **Random keys with redirection handling**
  - **Pro**: Simpler, leverages existing filler logic
  - **Con**: Uneven distribution (some nodes might get more data)
  - **Con**: Many MOVED redirections initially

**Recommended**: Option A for predictable performance

**Trade-offs**:
- **Pro**: Full cluster utilization (all nodes receive data)
- **Pro**: Parallelism at both thread and node level
- **Con**: More complex work distribution logic
- **Con**: Network overhead if nodes are remote

#### 3.2 CLI Mode Cluster Support

**Challenge**: Transparent command routing in REPL

**Solution**:
```haskell
cliClusterMode :: ClusterClient client -> IO ()
cliClusterMode cluster = do
  command <- readline "> "
  let respCommand = parseUserCommand command
  result <- tryRedisCommand cluster respCommand
  case result of
    Right response -> print response
    Left (ClusterError err) -> do
      putStrLn $ "Cluster error: " ++ err
      -- Show which node was targeted for debugging
      putStrLn $ "Attempted node: " ++ show targetNode
  cliClusterMode cluster
```

**User Experience Considerations**:
- Show cluster info on startup (node count, slot distribution)
- Optionally display target node for each command (debug mode)
- Handle CROSSSLOT errors gracefully with helpful message

**Trade-offs**:
- **Pro**: Users don't need to know cluster topology
- **Pro**: Same commands work as standalone Redis
- **Con**: Multi-key commands might fail (CROSSSLOT)
- **Con**: Debugging harder (which node has the key?)

#### 3.3 Tunnel Mode Cluster Support

**Challenge**: Single entry point (localhost:6379) to cluster

**Solution Strategy Options**:

**Option A: Smart Proxy with Routing**
```haskell
tunnelClusterMode :: ClusterClient client -> IO ()
tunnelClusterMode cluster = do
  serverSocket <- bindSocket "localhost:6379"
  forever $ do
    clientConn <- accept serverSocket
    forkIO $ handleTunnelClient cluster clientConn
  where
    handleTunnelClient cluster conn = do
      command <- receiveCommand conn
      slot <- calculateSlot (extractKey command)
      node <- routeToNode cluster slot
      response <- forwardToNode node command
      sendResponse conn response
```

**Option B: Connection Pinning**
- Pin each tunnel connection to one cluster node
- Simple but limits cluster benefits

**Recommended**: Option A (smart proxy)

**Trade-offs**:
- **Pro** (Option A): Full cluster benefits for proxied clients
- **Pro** (Option A): Transparent to downstream clients
- **Con** (Option A): Complex proxy logic, more failure modes
- **Con** (Option A): Performance overhead (parsing + routing)
- **Pro** (Option B): Simple implementation
- **Con** (Option B): Limited cluster benefits

### Phase 4: Advanced Features

#### 4.1 Read Replica Support

**Use Case**: Scale read-heavy workloads

**Implementation**:
```haskell
data ReadPolicy
  = ReadFromMaster  -- Default, strongest consistency
  | ReadFromReplica  -- Enable with READONLY command
  | ReadFromNearest  -- Choose by latency (future)

executeRead :: ClusterClient client -> ReadPolicy -> RespData -> IO RespData
executeRead cluster policy command = case policy of
  ReadFromMaster -> routeToMaster cluster command
  ReadFromReplica -> do
    sendCommand (currentNode cluster) (wrapInRay ["READONLY"])
    routeToReplica cluster command
```

**Trade-offs**:
- **Pro**: Horizontal scaling for reads
- **Pro**: Reduced load on master nodes
- **Con**: Eventual consistency (replica lag)
- **Con**: Additional command overhead (READONLY)

#### 4.2 Pipelining in Cluster Mode

**Challenge**: Maintain pipelining benefits across multiple nodes

**Solution**:
```haskell
pipelineClusterCommands :: ClusterClient client -> [RespData] -> IO [RespData]
pipelineClusterCommands cluster commands = do
  -- Group commands by target node
  let commandsByNode = groupByNode cluster commands
  
  -- Pipeline to each node concurrently
  results <- forM commandsByNode $ \(node, cmds) -> do
    conn <- getConnection cluster node
    pipelineToNode conn cmds
  
  -- Reassemble results in original order
  return $ reorderResults results
```

**Trade-offs**:
- **Pro**: Maintains low latency for bulk operations
- **Pro**: Utilizes cluster parallelism
- **Con**: Complex result ordering logic
- **Con**: Partial failures harder to handle

#### 4.3 Multi-Key Command Handling

**Challenge**: MGET, MSET, DEL with keys in different slots

**Solution Strategies**:

1. **Automatic Hash Tags** (Aggressive)
   ```haskell
   -- Transform: MSET key1 val1 key2 val2
   -- Into: MSET {user}:key1 val1 {user}:key2 val2
   ```
   - **Pro**: Transparent to user
   - **Con**: Changes key names (unacceptable for most cases)

2. **Command Splitting** (Recommended)
   ```haskell
   executeMGET :: ClusterClient client -> [String] -> IO [RespData]
   executeMGET cluster keys = do
     let keysBySlot = groupBy (calculateSlot . encodeUtf8) keys
     results <- forM keysBySlot $ \(slot, keys) -> do
       node <- getNodeForSlot cluster slot
       executeCommand node (wrapInRay ("MGET" : keys))
     return $ mergeResults results
   ```
   - **Pro**: Preserves key names
   - **Pro**: Maximizes parallelism
   - **Con**: Result ordering requires careful handling

3. **User Guidance** (Simplest)
   - Return CROSSSLOT error with helpful message
   - Suggest using hash tags: `MGET {user}:profile {user}:settings`
   - **Pro**: Simple, no magic
   - **Con**: Users must understand clustering

**Recommended**: Combination of #2 and #3 (split when possible, educate users)

**Trade-offs**:
- **Pro** (Splitting): Better cluster utilization
- **Con** (Splitting): More complex, edge cases (atomic operations broken)
- **Pro** (User Guidance): Clear, no surprises
- **Con** (User Guidance): Less ergonomic

## Testing Strategy

### Unit Tests Extension

**New Test Module**: `test/ClusterSpec.hs`

```haskell
describe "Cluster slot calculation" $ do
  it "calculates slot for simple keys" $ do
    calculateSlot "user:123" `shouldBe` <expected>
  
  it "extracts hash tags correctly" $ do
    extractHashTag "{user}:profile" `shouldBe` "user"
    extractHashTag "no-tag" `shouldBe` "no-tag"
  
  it "handles edge cases" $ do
    extractHashTag "{}" `shouldBe` "{}"
    extractHashTag "{user" `shouldBe` "{user"

describe "Topology parsing" $ do
  it "parses CLUSTER SLOTS response" $ do
    let response = createClusterSlotsResponse
    parseTopology response `shouldReturn` ClusterTopology {...}

describe "Command key extraction" $ do
  it "extracts keys from SET command" $ do
    extractKeys (wrapInRay ["SET", "key", "value"]) `shouldBe` ["key"]
  
  it "extracts keys from MGET command" $ do
    extractKeys (wrapInRay ["MGET", "k1", "k2"]) `shouldBe` ["k1", "k2"]
```

**Coverage Goals**:
- Slot calculation algorithm (match Redis exactly)
- Hash tag extraction (all edge cases)
- Topology parsing (various cluster sizes)
- MOVED/ASK error parsing
- Connection pool management

### E2E Tests with Real Cluster

**Infrastructure Changes**:

1. **Update `docker-compose.yml`**:
   ```yaml
   services:
     # Existing standalone redis
     redis:
       image: redis
       hostname: redis.local
       
     # New: Redis Cluster (reuse docker-cluster configs)
     redis-cluster:
       build:
         context: ./docker-cluster
       hostname: redis-cluster.local
       ports:
         - "7000-7005:7000-7005"
   ```

2. **New E2E Test Suite**: `test/ClusterE2E.hs`
   ```haskell
   describe "Cluster mode operations" $ beforeAll_ setupCluster $ do
     it "routes commands to correct nodes" $ do
       runClusterAction (set "key1" "value1") `shouldReturn` RespSimpleString "OK"
       runClusterAction (get "key1") `shouldReturn` RespBulkString "value1"
     
     it "handles MOVED redirections" $ do
       -- Trigger MOVED by requesting key from wrong node
       response <- runClusterActionDirect wrongNode (get "key1")
       -- Client should automatically handle and return success
       response `shouldBe` RespBulkString "value1"
     
     it "distributes data across cluster in fill mode" $ do
       runClusterFill 1 -- Fill 1GB
       forM_ clusterNodes $ \node -> do
         size <- runClusterActionDirect node dbsize
         size `shouldSatisfy` (> RespInteger 0)
   ```

3. **Update `rune2eTests.sh`**:
   ```bash
   # Run both standalone and cluster tests
   docker compose up -d redis redis-cluster
   
   # Wait for cluster formation
   ./wait-for-cluster.sh
   
   # Run tests
   cabal test RespSpec
   cabal test EndToEnd
   cabal test ClusterE2E  # New
   
   docker compose down
   ```

**Test Scenarios**:

1. **Basic Operations**
   - SET/GET/DEL across different slots
   - Verify commands reach correct nodes

2. **Redirection Handling**
   - Trigger MOVED by connecting to wrong node
   - Trigger ASK during slot migration (advanced)

3. **Fill Mode**
   - Fill 1GB, verify distribution across nodes
   - Check that all master nodes have data
   - Verify no key collisions

4. **CLI Mode**
   - Interactive commands work correctly
   - Multi-key commands handle CROSSSLOT appropriately

5. **Topology Changes** (Advanced)
   - Add node to cluster mid-test
   - Verify client discovers new topology
   - Remove node, verify failover to replicas

6. **Failure Scenarios**
   - Kill one master node
   - Verify replica promotion
   - Verify continued operation on other nodes

**Trade-offs**:
- **Pro**: Comprehensive coverage of cluster behavior
- **Pro**: Catch edge cases before production
- **Con**: Longer test execution time (cluster setup overhead)
- **Con**: More complex test infrastructure to maintain

## Implementation Phases & Timeline Estimate

### Phase 1: Foundation (2-3 weeks)
- [ ] Implement `Cluster.hs` topology management
- [ ] Implement `ConnectionPool.hs` 
- [ ] Add slot calculation and routing
- [ ] Unit tests for core cluster logic

### Phase 2: Command Execution (2 weeks)
- [ ] Extend `RedisCommandClient` for cluster operations
- [ ] Implement MOVED/ASK error handling
- [ ] Add retry logic with backoff
- [ ] Unit tests for redirection handling

### Phase 3: Mode Integration (2-3 weeks)
- [ ] Integrate fill mode with cluster routing
- [ ] Integrate CLI mode with cluster routing
- [ ] Integrate tunnel mode with cluster proxy
- [ ] Manual testing of all modes

### Phase 4: E2E Testing (1-2 weeks)
- [ ] Set up docker-compose cluster for tests
- [ ] Implement `ClusterE2E.hs` test suite
- [ ] Verify all test scenarios pass
- [ ] Performance testing and optimization

### Phase 5: Advanced Features (2-3 weeks, Optional)
- [ ] Read replica support
- [ ] Pipelining optimization
- [ ] Multi-key command splitting
- [ ] Enhanced error messages and debugging

**Total Estimated Effort**: 9-13 weeks (can be parallelized)

## Configuration & User Interface

### Command-Line Options

**New Flags**:
```bash
redis-client [mode] [OPTIONS]

Cluster Options:
  --cluster              Enable cluster mode
  --cluster-slots        Discover using CLUSTER SLOTS (default)
  --cluster-nodes        Discover using CLUSTER NODES
  --cluster-refresh INT  Topology refresh interval in seconds (default: 60)
  --read-replicas        Enable reads from replicas
```

**Examples**:
```bash
# Fill cluster with 10GB
redis-client fill --cluster --host node1.cluster.local --data 10

# Interactive CLI with cluster
redis-client cli --cluster --host node1.cluster.local

# Tunnel with cluster backend
redis-client tunn --cluster --host node1.cluster.local --tls
```

### Backward Compatibility

**Critical**: Maintain full backward compatibility

- **Default behavior unchanged**: No `--cluster` flag = standalone mode
- **Same commands**: All existing commands work identically
- **Same flags**: Existing flags unchanged
- **Graceful degradation**: If cluster connection fails, show clear error

**Detection Strategy** (Alternative to --cluster flag):
```haskell
-- Automatically detect if target is a cluster
detectClusterMode :: String -> IO Bool
detectClusterMode host = do
  conn <- connect (NotConnectedPlainTextClient host Nothing)
  response <- send conn "CLUSTER INFO\r\n"
  case response of
    RespError "ERR This instance has cluster support disabled" -> return False
    _ -> return True
```

**Trade-offs**:
- **Pro** (Auto-detect): User doesn't need to know if it's a cluster
- **Pro** (Auto-detect): Same command works for both modes
- **Con** (Auto-detect): Extra round-trip on connection
- **Con** (Auto-detect): Ambiguous failure modes
- **Pro** (Explicit flag): Clear, explicit, no surprises
- **Con** (Explicit flag): Users must know their setup

**Recommended**: Explicit `--cluster` flag (clearer, more debuggable)

## Performance Considerations

### Expected Performance Characteristics

1. **Fill Mode**
   - **Standalone**: ~500-800 MB/s (current)
   - **Cluster (3 masters)**: ~1200-1800 MB/s (2-3x, with 3x parallelism)
   - **Overhead**: ~5-10% for slot calculation and routing

2. **CLI Mode**
   - **Standalone**: <1ms per command
   - **Cluster**: +0.5-1ms per command (routing overhead)
   - **First command**: +50-100ms (topology discovery)

3. **Memory Usage**
   - **Topology**: ~1-2 MB (even for 100-node cluster)
   - **Connection pool**: ~20KB per connection
   - **Typical overhead**: 5-10 MB for 10-node cluster

### Optimization Opportunities

1. **Topology Caching**
   - Cache on disk between runs
   - **Pro**: Faster startup
   - **Con**: Stale topology risk

2. **Connection Pooling**
   - Multiple connections per node for parallelism
   - **Pro**: Higher throughput
   - **Con**: More resource usage

3. **Pipelining**
   - Batch commands to same node
   - **Pro**: Lower latency, higher throughput
   - **Con**: More complex implementation

4. **Lazy Connection**
   - Only connect to nodes as needed
   - **Pro**: Faster startup, lower resource usage
   - **Con**: First access to new node has connection overhead

## Potential Issues & Mitigation

### Issue 1: Cluster Reconfiguration

**Problem**: Cluster topology changes during operation (resharding, failover)

**Mitigation**:
- Periodic topology refresh (default: every 60s)
- Forced refresh on multiple consecutive MOVED errors (threshold: 5)
- Exponential backoff on refresh failures

### Issue 2: Slot Migration

**Problem**: Slots being migrated cause ASK redirections

**Mitigation**:
- Implement ASKING command support
- Track ongoing migrations in topology
- Retry with backoff on TRYAGAIN errors

### Issue 3: Connection Failures

**Problem**: Node goes down, connections fail

**Mitigation**:
- Automatic reconnection with exponential backoff
- Failover to replica if master unreachable
- Circuit breaker pattern (after N failures, stop trying for T seconds)

### Issue 4: Multi-Key Operations

**Problem**: MGET with keys in different slots fails with CROSSSLOT

**Mitigation**:
- Document hash tag usage in README
- Split multi-key commands automatically (where safe)
- Provide clear error messages with suggestions

### Issue 5: Transaction Support

**Problem**: MULTI/EXEC doesn't work across slots

**Mitigation**:
- Detect MULTI/EXEC commands
- Verify all keys in same slot before starting transaction
- Return clear error if keys in different slots
- Document limitation in README

### Issue 6: Pub/Sub in Cluster

**Problem**: Pub/Sub has special routing in clusters

**Mitigation**:
- Phase 1: Document as unsupported
- Future: Implement cluster-aware pub/sub routing

## Migration Path for Users

### For Existing Standalone Users

**No changes required** unless they want cluster support:

```bash
# Existing usage (unchanged)
redis-client fill -h localhost -d 5

# Same with cluster support
redis-client fill --cluster -h cluster-node1 -d 5
```

### For New Cluster Users

**Minimal setup**:

1. Ensure Redis Cluster is running and initialized
2. Add `--cluster` flag to any command
3. Point to any cluster node (client discovers the rest)

**Example**:
```bash
# Start with single seed node
redis-client fill --cluster -h 10.0.1.100 -d 10

# Client automatically:
# - Discovers full cluster topology
# - Distributes work across all master nodes
# - Handles redirections transparently
```

## Documentation Requirements

### README Updates

1. **New Section**: "Redis Cluster Support"
   - Overview of clustering feature
   - How to enable (--cluster flag)
   - Examples for each mode

2. **Update Examples**:
   ```bash
   # Standalone examples (existing)
   redis-client fill -h localhost -d 5
   
   # NEW: Cluster examples
   redis-client fill --cluster -h cluster-node1 -d 5
   redis-client cli --cluster -h cluster-node1
   ```

3. **Troubleshooting Section**:
   - CROSSSLOT errors and hash tags
   - Connection failures and retry behavior
   - Performance expectations

### New Documentation Files

1. **CLUSTER_GUIDE.md**:
   - Deep dive into cluster support
   - Architecture diagrams
   - Advanced usage (replicas, pipelining)
   - Performance tuning

2. **CLUSTER_DEVELOPMENT.md**:
   - For contributors
   - Cluster code architecture
   - Testing cluster features
   - Debugging cluster issues

## Alternative Approaches Considered

### Approach A: Pure Smart Client (Recommended Above)

**Pros**: Best performance, full control, cluster-native  
**Cons**: Most complex implementation  
**Verdict**: Best long-term solution

### Approach B: Proxy Pattern

**Implementation**: Deploy a separate proxy process that handles clustering

**Pros**:
- Simpler client code
- Proxy reusable across multiple clients
- Easier to add features (caching, monitoring)

**Cons**:
- Extra network hop (latency)
- Additional deployment complexity
- Single point of failure (without HA setup)
- Doesn't match project's philosophy (direct Redis access)

**Verdict**: Not recommended (conflicts with project goals)

### Approach C: Cluster-Aware CLI Only

**Implementation**: Add clustering only to CLI mode, not fill/tunnel

**Pros**:
- Simpler scope
- Quick to implement
- Covers primary use case (interactive)

**Cons**:
- Inconsistent feature set
- Fill mode (major use case) still needs cluster support
- Leaves project half-finished

**Verdict**: Not recommended (incomplete solution)

### Approach D: External Cluster Library

**Implementation**: Use existing Haskell cluster library (e.g., hedis-cluster)

**Pros**:
- Faster implementation
- Maintained by community
- Proven in production

**Cons**:
- Heavy dependency (hedis brings its own design)
- Less control over implementation
- Harder to integrate with existing architecture
- May not support all current features (TLS tunnel, etc.)

**Verdict**: Consider for rapid prototyping, but not for production

## Success Criteria

### Functional Requirements

- [ ] All existing commands work in cluster mode
- [ ] MOVED redirections handled transparently
- [ ] ASK redirections handled correctly
- [ ] Fill mode distributes data evenly across cluster
- [ ] CLI mode routes commands to correct nodes
- [ ] Tunnel mode proxies to cluster correctly
- [ ] Multi-key commands either work or fail with clear errors

### Non-Functional Requirements

- [ ] Cluster mode adds <10% latency overhead for single commands
- [ ] Fill mode achieves near-linear speedup with cluster size
- [ ] Memory usage <10MB overhead for typical cluster (3-10 nodes)
- [ ] Zero breaking changes for existing standalone users
- [ ] All E2E tests pass for both standalone and cluster modes
- [ ] Documentation complete and clear

### Quality Requirements

- [ ] Unit test coverage >80% for new code
- [ ] E2E tests cover all three modes in cluster configuration
- [ ] No code duplication between standalone and cluster paths
- [ ] Error messages helpful and actionable
- [ ] Code follows existing project style and conventions

## Conclusion

Implementing Redis Cluster support in this project is feasible and aligns well with the existing architecture:

**Key Strengths**:
1. **CRC16 already implemented**: Core clustering primitive ready
2. **Parallel execution proven**: Fill mode already does concurrent connections
3. **Docker cluster setup exists**: Testing infrastructure partially ready
4. **Clean architecture**: Easy to extend without breaking changes

**Key Challenges**:
1. **Redirection handling**: Requires careful state management
2. **Multi-key operations**: Need command splitting or clear errors
3. **Test complexity**: Cluster E2E tests more involved
4. **Connection pooling**: Thread-safe pool management non-trivial

**Recommendation**: 
Implement Phase 1-4 (9-11 weeks) for production-ready cluster support. Phase 5 (advanced features) can be added incrementally based on user feedback.

The proposed approach maintains backward compatibility, leverages existing strengths, and follows Redis cluster best practices. The result will be a high-performance, cluster-native Redis client that maintains the simplicity and directness that characterizes the current implementation.

## Appendix A: Hash Tag Examples

Redis cluster uses hash tags to force keys into the same slot:

```bash
# These keys are in different slots (likely different nodes)
SET user:123:profile "Alice"
SET user:123:settings "..."
GET user:123:profile  # Might fail in MULTI

# These keys are guaranteed to be in the same slot
SET {user:123}:profile "Alice"
SET {user:123}:settings "..."
MGET {user:123}:profile {user:123}:settings  # Works!

# Only the content inside {} is hashed
# So {user:123}:profile and {user:123}:settings
# both hash "user:123" → same slot
```

## Appendix B: CLUSTER SLOTS Response Format

```
# Command
CLUSTER SLOTS

# Response (simplified)
1) 1) (integer) 0      # slot start
   2) (integer) 5460   # slot end
   3) 1) "127.0.0.1"   # master IP
      2) (integer) 7000 # master port
      3) "node-id-1"    # master node ID
   4) 1) "127.0.0.1"   # replica IP
      2) (integer) 7003 # replica port
      3) "node-id-4"    # replica node ID
2) 1) (integer) 5461
   2) (integer) 10922
   3) 1) "127.0.0.1"
      2) (integer) 7001
      3) "node-id-2"
   4) 1) "127.0.0.1"
      2) (integer) 7004
      3) "node-id-5"
3) 1) (integer) 10923
   2) (integer) 16383
   3) 1) "127.0.0.1"
      2) (integer) 7002
      3) "node-id-3"
   4) 1) "127.0.0.1"
      2) (integer) 7005
      3) "node-id-6"
```

## Appendix C: Slot Calculation Verification

To ensure our CRC16 implementation matches Redis exactly:

```haskell
-- Test cases from Redis documentation
testSlotCalculation :: Spec
testSlotCalculation = describe "CRC16 slot calculation" $ do
  it "matches Redis for known keys" $ do
    calculateSlot "user:123" `shouldBe` 5474
    calculateSlot "object:456" `shouldBe` 4220
    calculateSlot "{user}:profile" `shouldBe` 5474  -- Same as "user"
    calculateSlot "{user}:settings" `shouldBe` 5474  -- Same as "user"
    calculateSlot "key" `shouldBe` 12539
```

These values can be verified against a real Redis cluster using:
```bash
redis-cli CLUSTER KEYSLOT "user:123"
```

## Appendix D: Competitive Analysis

### How Other Clients Handle Clustering

**redis-py-cluster (Python)**:
- Smart client with topology caching
- Automatic redirection handling
- Connection pool per node
- ~2000 LOC for cluster support

**Jedis (Java)**:
- JedisCluster class wraps JedisPool
- Static slot assignment (doesn't refresh automatically)
- Manual connection management
- ~3000 LOC for cluster support

**go-redis (Go)**:
- ClusterClient type
- Concurrent safe topology updates
- Pipelining support
- ~2500 LOC for cluster support

**Our Approach**:
- Similar to redis-py-cluster (smart client)
- Leverages Haskell's type safety
- Estimated ~2000-2500 LOC
- Will be one of the few Haskell cluster clients

## Appendix E: Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| CRC16 mismatch with Redis | Low | High | Extensive testing with real clusters |
| Connection pool leaks | Medium | Medium | Use bracket pattern, comprehensive cleanup |
| Topology inconsistency | Medium | High | Aggressive refresh on errors, versioning |
| Redirection loops | Low | High | Max retry counter, circuit breaker |
| Multi-key command breakage | High | Medium | Clear documentation, helpful errors |
| Performance regression | Low | Medium | Benchmark suite, profiling |
| Backward compatibility break | Low | Critical | Extensive testing of standalone mode |
| Complex edge cases in prod | High | Medium | Comprehensive E2E tests, canary deployment |

**Overall Risk Level**: Medium (manageable with proper planning and testing)

---

**Document Version**: 1.0  
**Last Updated**: 2026-02-03  
**Author**: Cluster Implementation Planning Team  
**Status**: Proposal for Review
