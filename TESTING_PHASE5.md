# Testing Plan for Phase 5: Cluster Fill Mode

## Overview
This document outlines the testing procedure for the Phase 5 cluster fill mode implementation.

## Implementation Summary

### Changes Made
- Modified `fillCluster` function in `app/Main.hs` to implement actual cluster fill functionality
- Replaced placeholder messages with working implementation that:
  - Uses `ClusterCommandClient` for automatic command routing
  - Supports both serial and parallel modes
  - Handles TLS and plaintext connections
  - Reuses existing `fillCacheWithData` and `fillCacheWithDataMB` functions

### Key Features
1. **Automatic Slot Routing**: Commands are automatically routed to correct nodes based on key hash slots
2. **Parallel Execution**: Multiple connections run in parallel with seed spacing to avoid collisions
3. **Fire-and-Forget Mode**: Uses `CLIENT REPLY OFF` for maximum throughput
4. **Resource Management**: Each thread creates and cleans up its own cluster client

## Prerequisites

### 1. Build the Project
```bash
make setup  # Install dependencies (libreadline-dev)
cabal build # Build the project
```

### 2. Start Redis Cluster
```bash
make redis-cluster-start
```

This will:
- Start a 5-node Redis cluster using Docker Compose
- Initialize the cluster with `make_cluster.sh`
- Distribute slots across master nodes

### 3. Verify Cluster is Running
```bash
docker ps | grep redis-cluster
# Should show 5 containers running on ports 6379-6383

# Check cluster status
redis-cli -c -p 6379 cluster nodes
redis-cli -c -p 6379 cluster info
```

## Test Cases

### Test 1: Basic Flush (Baseline)
**Purpose**: Verify cluster connection and flush works

```bash
cabal run redis-client -- fill -h localhost -c -f
```

**Expected Output**:
```
Flushing cluster cache (seed node: 'localhost')
```

**Verification**:
```bash
redis-cli -c -p 6379 dbsize
# Should return 0
```

### Test 2: Small Fill (Serial Mode)
**Purpose**: Test basic fill functionality with serial mode

```bash
# Fill 100MB in serial mode
cabal run redis-client -- fill -h localhost -c -d 0.1 -s -f
```

**Expected Output**:
```
Flushing cluster cache (seed node: 'localhost')
Initialized shared random noise buffer: 128 MB
Filling cluster cache (seed node: 'localhost') with 0GB of data using serial mode
```

**Verification**:
```bash
# Check each master node has data
for port in 6379 6380 6381; do
  echo "Port $port:"
  redis-cli -p $port dbsize
done
```

### Test 3: Parallel Fill (Default Mode)
**Purpose**: Test parallel execution with multiple connections

```bash
# Fill 500MB with 2 parallel connections (default)
cabal run redis-client -- fill -h localhost -c -d 0.5 -f
```

**Expected Output**:
```
Flushing cluster cache (seed node: 'localhost')
Initialized shared random noise buffer: 128 MB
Filling cluster cache (seed node: 'localhost') with 0GB of data using 2 parallel connections
```

**Verification**:
```bash
# Check total keys across cluster
redis-cli -c -p 6379 dbsize

# Check distribution across nodes
for port in 6379 6380 6381; do
  echo "Port $port:"
  redis-cli -p $port dbsize
done

# All master nodes should have data
# Distribution should be relatively even
```

### Test 4: Custom Parallel Connections
**Purpose**: Test with more parallel connections

```bash
# Fill 1GB with 4 parallel connections
cabal run redis-client -- fill -h localhost -c -d 1 -n 4 -f
```

**Expected Output**:
```
Filling cluster cache (seed node: 'localhost') with 1GB of data using 4 parallel connections
```

**Verification**:
```bash
redis-cli -c -p 6379 dbsize
# Should have approximately 2M keys (1GB / 512 bytes per key)
```

### Test 5: Large Fill Test
**Purpose**: Test scalability with larger dataset

```bash
# Fill 5GB
cabal run redis-client -- fill -h localhost -c -d 5 -f
```

**Expected Output**:
```
Filling cluster cache (seed node: 'localhost') with 5GB of data using 2 parallel connections
```

**Verification**:
```bash
# Check memory usage and key distribution
redis-cli -c -p 6379 info memory
redis-cli -c -p 6379 dbsize

# Verify even distribution
for port in 6379 6380 6381; do
  echo "Port $port:"
  redis-cli -p $port info memory | grep used_memory_human
  redis-cli -p $port dbsize
done
```

### Test 6: TLS Connection (if TLS is configured)
**Purpose**: Test cluster fill over TLS

```bash
cabal run redis-client -- fill -h localhost -c -t -d 0.5 -f
```

## Profiling Tests

### Before/After Comparison
**Purpose**: Compare performance before and after Phase 5 implementation

#### Profile Standalone Mode (Baseline)
```bash
make redis-start
cabal run --enable-profiling -- fill -h localhost -d 1 -f +RTS -p -RTS
mv redis-client.prof redis-client-standalone.prof
make redis-stop
```

#### Profile Cluster Mode (Phase 5)
```bash
make redis-cluster-start
cabal run --enable-profiling -- fill -h localhost -c -d 1 -f +RTS -p -RTS
mv redis-client.prof redis-client-cluster.prof
make redis-cluster-stop
```

#### Compare Profiles
```bash
diff redis-client-standalone.prof redis-client-cluster.prof
# Look for:
# - Similar memory usage patterns
# - No major performance regressions
# - Cluster overhead should be < 10%
```

## Unit Tests

Run existing unit tests to ensure no regressions:

```bash
cabal test ClusterSpec
cabal test ClusterCommandSpec
cabal test RespSpec
```

## E2E Tests

Run the cluster E2E test suite:

```bash
./runClusterE2ETests.sh
```

**Note**: This script may need to be created if it doesn't exist yet. It should follow the pattern of `rune2eTests.sh` but use the cluster setup.

## Success Criteria

### Functional Requirements
- [ ] Cluster connection works (flush succeeds)
- [ ] Data is distributed across all master nodes
- [ ] Serial mode works correctly
- [ ] Parallel mode works with default connections (2)
- [ ] Parallel mode works with custom connection count (4, 8)
- [ ] TLS connections work (if configured)
- [ ] Large datasets (5GB+) can be filled

### Performance Requirements
- [ ] Throughput is reasonable (MB/s comparable to standalone)
- [ ] Memory usage is stable (no leaks)
- [ ] Cluster overhead is < 10% vs standalone
- [ ] Even distribution across nodes (within 20% variance)

### Quality Requirements
- [ ] No crashes or exceptions
- [ ] Clean resource cleanup (no leaked connections)
- [ ] Unit tests pass
- [ ] E2E tests pass

## Cleanup

After testing:

```bash
make redis-cluster-stop
rm -f *.prof *.hp *.ps *.aux *.stat
```

## Troubleshooting

### Issue: "Could not resolve host" during build
**Solution**: Network connectivity issue. Wait and retry or use cached packages.

### Issue: "Connection refused" when connecting to cluster
**Solution**: Ensure cluster is running with `make redis-cluster-start`

### Issue: Data not distributed across nodes
**Solution**: Verify cluster is properly initialized with `redis-cli -c -p 6379 cluster nodes`

### Issue: Out of memory errors
**Solution**: 
- Use smaller test dataset
- Increase Docker memory limits
- Use `-f` flag to flush before filling

## Next Steps

After successful testing:
1. Run code review with `code_review` tool
2. Run security scan with `codeql_checker` tool  
3. Update CLUSTERING_IMPLEMENTATION_PLAN.md to mark Phase 5 as complete
4. Consider implementing Phase 6 (Tunnel Mode) or Phase 7 (Comprehensive E2E Testing)
