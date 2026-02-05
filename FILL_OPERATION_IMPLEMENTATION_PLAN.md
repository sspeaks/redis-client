# Fill Operation Configuration & Performance - Implementation Plan

## Current Status

**Completed**: 
- Core fill functionality for both standalone and cluster modes
- **Phase 1: Key Size Configuration** ✅ (Completed 2026-02-05)
  - Added `--key-size` flag with validation (1-65536 bytes, default: 512)
  - Implemented in both standalone and cluster modes
  - Fixed critical under-fill bug for non-default key sizes
  - Added comprehensive E2E and unit tests
  - All tests passing
- **Phase 2: Value Size Configuration** ✅ (Completed 2026-02-05)
  - Added `--value-size` flag with validation (1-524288 bytes, default: 512)
  - Implemented in both standalone and cluster modes
  - Updated `bytesPerCommand` calculation to use `keySize + valueSize`
  - Added unit tests for value size support
  - Manual testing verified memory accuracy
  - All tests passing (97 tests total)

**Next Priority**: Phase 3 - Add Pipeline Depth Configuration  
**Document Version**: 2.2  
**Last Updated**: 2026-02-05

---

## Overview

This document outlines a multi-phase plan to enhance the fill operation with configurable parameters and systematic performance optimization. The fill operation currently works well but uses hardcoded values for key/value sizes and derives pipelining depth from environment variables. This plan will incrementally add configuration options, then use those options to conduct comprehensive performance benchmarking and optimization.

---

## What's Next?

### Phase 1: Add Key Size Configuration ✅
**Status**: ✅ COMPLETED (2026-02-05)  
**Prerequisites**: None  
**Actual Effort**: ~150 LOC (including bug fix and tests)

#### Goal
Add configurable key size parameter for fill mode to enable testing with different key sizes.

#### Context
Currently, fill mode uses a hardcoded key size of 512 bytes. Different use cases require different key sizes:
- Session cache: Small keys (64-128 bytes)
- Object cache: Medium keys (256-512 bytes)
- Document cache: Larger keys (1024+ bytes)

Adding key size configuration is the first step toward making fill mode more flexible and representative of real-world workloads.

#### Scope
- Add `--key-size BYTES` command-line flag
- Update `Filler.hs` to use configurable key size (standalone mode)
- Update `ClusterFiller.hs` to use configurable key size (cluster mode)
- Add parameter validation (range: 1-65536 bytes)
- Update help text with new flag
- Maintain backward compatibility (default: 512 bytes)

#### Key Files to Modify
- **`app/Main.hs`** - Add `--key-size` argument parsing
- **`app/Filler.hs`** - Update `fillCacheWithDataMB` to accept key size parameter
- **`app/ClusterFiller.hs`** - Update `fillNodeWithData` and `generateClusterChunk` to accept key size

#### Proposed Command-Line Flag
```
--key-size BYTES
  Size of each key in bytes
  Default: 512
  Range: 1-65536 bytes
```

#### Parameter Validation
```haskell
validateKeySize :: Int -> Either String Int
validateKeySize size
  | size < 1 = Left "Key size must be at least 1 byte"
  | size > 65536 = Left "Key size must not exceed 65536 bytes"
  | otherwise = Right size
```

#### Usage Examples
```bash
# Small keys (session cache simulation)
redis-client fill -h localhost -d 1 --key-size 64

# Medium keys (default behavior)
redis-client fill -h localhost -d 1 --key-size 512

# Large keys (document cache simulation)
redis-client fill -h localhost -d 1 --key-size 2048

# Cluster mode with custom key size
redis-client fill -h localhost -c -d 5 --key-size 256
```

#### Success Criteria
- ✅ `--key-size` flag works correctly in standalone mode
- ✅ `--key-size` flag works correctly in cluster mode
- ✅ Backward compatibility maintained (default: 512 bytes)
- ✅ Parameter validation works and provides clear error messages
- ✅ All existing tests pass
- ✅ Help text (`--help`) updated with new flag

#### Implementation Notes (Completed)

**Changes Made:**
- Added `keySize :: Int` field to `RunState` data type with named record syntax
- Implemented `--key-size` CLI flag with validation (1-65536 bytes)
- Updated `Filler.hs` to use configurable key size with accurate byte-based calculation
- Updated `ClusterFiller.hs` to use MB-based calculation (matching standalone)
- Created `FillHelpers.hs` module to eliminate code duplication between Filler and ClusterFiller
- Added comprehensive E2E tests (including memory accuracy tests for key sizes 64, 128, 256, 512)
- Added unit tests in `FillHelpersSpec.hs` (14 tests covering byte generation)

**Critical Bug Fixed:**
The original implementation had a severe calculation bug where it assumed `1 KB = 1 command`, which only held true when `keySize=512`. This caused:
- keySize=128: Only 62.5% of target filled
- keySize=64: Only 56.25% of target filled
- keySize=256: Only 75% of target filled

**Fix Applied:**
Implemented proper `bytesPerCommand` calculation using remainder logic:
```haskell
let bytesPerCommand = keySize + 512
    totalBytesNeeded = mb * 1024 * 1024
    totalCommandsNeeded = (totalBytesNeeded + bytesPerCommand - 1) `div` bytesPerCommand
    fullChunks = totalCommandsNeeded `div` chunkKilos
    remainderCommands = totalCommandsNeeded `mod` chunkKilos
```

This ensures accurate filling (±0.1%) for all key sizes by calculating based on actual data bytes.

**Test Results:**
- All unit tests pass: 92 examples, 0 failures
- All cluster E2E tests pass: 26 examples with ±0.1% tolerance
- Memory accuracy verified for key sizes: 64, 128, 256, 512 bytes
- Backward compatibility confirmed (keySize=512 default)

---

### Phase 2: Add Value Size Configuration
**Status**: ✅ COMPLETED (2026-02-05)  
**Prerequisites**: Phase 1 complete ✅  
**Actual Effort**: ~50 LOC (including tests)

#### Implementation Approach (Completed)

Successfully implemented following the pattern from Phase 1:

1. **Added `valueSize` field to `RunState`** ✅
2. **Updated `bytesPerCommand` calculations** in both `Filler.hs` and `ClusterFiller.hs` ✅:
   ```haskell
   let bytesPerCommand = keySize + valueSize  -- Updated from hardcoded 512
   ```
3. **Updated value generation** to use `generateBytes` with configurable size ✅
4. **Validated memory accuracy** with manual testing ✅
5. **Added unit tests** for value size support ✅

#### Goal
Add configurable value size parameter for fill mode to enable testing with different value sizes.

#### Context
Previously, fill mode used a hardcoded value size of 512 bytes. Different use cases require different value sizes:
- Session cache: Small values (128-512 bytes)
- Object cache: Large values (4096-16384 bytes)
- File/blob cache: Very large values (up to 512 KB)

Value size significantly impacts throughput and memory usage, making this an important tuning parameter.

#### Scope
- Add `--value-size BYTES` command-line flag
- Update `Filler.hs` to use configurable value size (standalone mode)
- Update `ClusterFiller.hs` to use configurable value size (cluster mode)
- Add parameter validation (range: 1-524288 bytes)
- Update help text with new flag
- Maintain backward compatibility (default: 512 bytes)

#### Key Files Modified
- **`app/Main.hs`** - Added `--value-size` argument parsing with validation
- **`app/Filler.hs`** - Updated `fillCacheWithDataMB` and `genRandomSet` to accept value size parameter
- **`app/ClusterFiller.hs`** - Updated `fillNodeWithData` and `generateClusterChunk` to accept value size
- **`lib/redis-command-client/RedisCommandClient.hs`** - Added `valueSize` field to `RunState`
- **`test/FillHelpersSpec.hs`** - Added 5 new unit tests for value size support

#### Command-Line Flag
```
--value-size BYTES
  Size of each value in bytes
  Default: 512
  Range: 1-524288 bytes (512 KB max)
```

#### Parameter Validation (Implemented)
```haskell
-- In app/Main.hs options list
Option [] ["value-size"] (ReqArg (\arg opt -> do
    let size = read arg :: Int
    if size < 1
      then ioError (userError "Value size must be at least 1 byte")
      else if size > 524288
        then ioError (userError "Value size must not exceed 524288 bytes")
        else return $ opt {valueSize = size}) "BYTES") 
  "Size of each value in bytes (default: 512, range: 1-524288)"
```

#### Usage Examples
```bash
# Small values (session cache simulation)
redis-client fill -h localhost -d 1 --key-size 64 --value-size 128

# Large values (object cache simulation)
redis-client fill -h localhost -d 1 --key-size 256 --value-size 8192

# Very large values (blob cache simulation)
redis-client fill -h localhost -d 1 --key-size 512 --value-size 65536

# Cluster mode with custom sizes
redis-client fill -h localhost -c -d 5 --key-size 512 --value-size 2048
```

#### Success Criteria (All Met)
- ✅ `--value-size` flag works correctly in standalone mode
- ✅ `--value-size` flag works correctly in cluster mode
- ✅ Backward compatibility maintained (default: 512 bytes)
- ✅ Parameter validation works and provides clear error messages
- ✅ All existing tests pass
- ✅ Help text (`--help`) updated with new flag

#### Test Results
- All unit tests pass: 97 examples, 0 failures (19 in FillHelpersSpec)
- Manual memory accuracy testing:
  - key=256, value=1024: Expected 838,861 keys → Got 838,862 keys ✓
  - key=512, value=512: Expected 1,048,576 keys → Got 1,048,576 keys ✓
  - key=64, value=128: Expected 5,592,405 keys → Got 5,592,406 keys ✓
  - key=512, value=8192: Expected 123,362 keys → Got 123,362 keys ✓
- Backward compatibility verified (default valueSize=512)
- Code review: No critical issues found
- CodeQL security scan: No vulnerabilities detected
- ✅ All existing tests pass
- ✅ Help text (`--help`) updated with new flag

---

### Phase 3: Add Pipeline Depth Configuration
**Status**: NOT STARTED  
**Prerequisites**: Phase 2 complete  
**Estimated Effort**: ~20-30 LOC

#### Goal
Add configurable pipeline depth parameter for fill mode to enable fine-tuning of command batching for optimal performance.

#### Context
Currently, fill mode derives the number of commands per pipeline batch from the `REDIS_CLIENT_FILL_CHUNK_KB` environment variable (default: 8192 KB) and the key/value sizes. Explicit control over pipelining depth allows users to:
- Optimize for low-latency networks (higher pipeline depth)
- Reduce memory usage (lower pipeline depth)
- Match Redis server capabilities
- Fine-tune throughput independent of data sizes

#### Scope
- Add `--pipeline-depth NUM` command-line flag
- Update `Filler.hs` to use explicit pipeline depth (standalone mode)
- Update `ClusterFiller.hs` to use explicit pipeline depth (cluster mode)
- Add parameter validation (range: 1-100000 commands)
- Implement flag precedence: `--pipeline-depth` overrides `REDIS_CLIENT_FILL_CHUNK_KB`
- Update help text with new flag
- Maintain backward compatibility with environment variable

#### Key Files to Modify
- **`app/Main.hs`** - Add `--pipeline-depth` argument parsing
- **`app/Filler.hs`** - Update `fillCacheWithDataMB` to accept pipeline depth parameter
- **`app/ClusterFiller.hs`** - Update `fillNodeWithData` and `generateClusterChunk` to accept pipeline depth

#### Proposed Command-Line Flag
```
--pipeline-depth NUM
  Number of SET commands per pipeline batch
  Default: derived from REDIS_CLIENT_FILL_CHUNK_KB (typically ~8000-16000)
  Range: 1-100000 commands
  If specified, overrides chunk size calculation from environment variable
```

#### Parameter Validation
```haskell
validatePipelineDepth :: Int -> Either String Int
validatePipelineDepth depth
  | depth < 1 = Left "Pipeline depth must be at least 1"
  | depth > 100000 = Left "Pipeline depth must not exceed 100000"
  | otherwise = Right depth
```

#### Flag Precedence Logic
```haskell
determinePipelineDepth :: Maybe Int -> Maybe Int -> Int -> Int -> Int
determinePipelineDepth explicitDepth envChunkKB keySize valueSize =
  case explicitDepth of
    Just depth -> depth  -- Explicit flag takes precedence
    Nothing -> calculateFromChunk envChunkKB keySize valueSize
  where
    calculateFromChunk chunkKB kSize vSize =
      let chunkBytes = chunkKB * 1024
          commandSize = kSize + vSize + 60  -- RESP protocol overhead
      in max 1 (chunkBytes `div` commandSize)
```

#### Usage Examples
```bash
# Explicit pipeline depth (low latency network)
redis-client fill -h localhost -d 1 --pipeline-depth 5000

# Combination with key/value sizes
redis-client fill -h localhost -d 1 --key-size 512 --value-size 2048 --pipeline-depth 2000

# Cluster mode with tuned parameters
redis-client fill -h localhost -c -d 5 --key-size 256 --value-size 4096 --pipeline-depth 3000 -n 8

# Backward compatibility (using environment variable)
REDIS_CLIENT_FILL_CHUNK_KB=4096 redis-client fill -h localhost -d 1

# Explicit flag overrides environment variable
REDIS_CLIENT_FILL_CHUNK_KB=4096 redis-client fill -h localhost -d 1 --pipeline-depth 1000
```

#### Success Criteria
- ✅ `--pipeline-depth` flag works correctly in standalone mode
- ✅ `--pipeline-depth` flag works correctly in cluster mode
- ✅ Flag precedence works correctly (explicit flag overrides environment variable)
- ✅ `REDIS_CLIENT_FILL_CHUNK_KB` environment variable still works when flag not specified
- ✅ Parameter validation works and provides clear error messages
- ✅ All existing tests pass
- ✅ Help text (`--help`) updated with new flag and precedence rules
- ✅ README updated with examples

---

### Phase 4: Update Documentation
**Status**: NOT STARTED  
**Prerequisites**: Phases 1-3 complete  
**Estimated Effort**: ~10-20 LOC (documentation only)

#### Goal
Comprehensively document all new configuration flags with examples and best practices.

#### Scope
- Update README.md with detailed examples
- Document flag combinations and use cases
- Add troubleshooting section for common issues
- Document performance implications of different settings
- Update help text with clear descriptions

#### Documentation Sections to Add/Update

**README.md additions:**
```markdown
### Fill Mode Configuration

The fill operation supports fine-grained configuration to match different workload characteristics:

#### Basic Usage
```bash
# Fill with default settings (512 byte keys/values)
redis-client fill -h localhost -d 5

# Custom key and value sizes
redis-client fill -h localhost -d 5 --key-size 256 --value-size 4096

# Custom pipeline depth
redis-client fill -h localhost -d 5 --pipeline-depth 2000
```

#### Configuration Flags

- `--key-size BYTES` - Key size in bytes (default: 512, range: 1-65536)
- `--value-size BYTES` - Value size in bytes (default: 512, range: 1-524288)
- `--pipeline-depth NUM` - Commands per pipeline batch (default: calculated from chunk size)

#### Use Case Examples

**Session Cache Simulation** (small keys/values):
```bash
redis-client fill -h localhost -c -d 10 --key-size 64 --value-size 256 --pipeline-depth 5000
```

**Object Cache Simulation** (large values):
```bash
redis-client fill -h localhost -c -d 10 --key-size 256 --value-size 8192 --pipeline-depth 1000
```

**Maximum Throughput** (tuned parameters):
```bash
redis-client fill -h localhost -c -d 10 --key-size 1024 --value-size 4096 --pipeline-depth 2000 -n 8
```

**Memory Efficient** (lower pipeline depth):
```bash
redis-client fill -h localhost -c -d 10 --key-size 128 --value-size 512 --pipeline-depth 500 -n 2
```

#### Configuration Guidelines

- **Pipeline depth**: Higher values (2000-5000) for low-latency networks, lower values (500-1000) for high-latency or memory-constrained environments
- **Key/value sizes**: Match your production workload characteristics
- **Thread count** (`-n`): Start with 2-4 per node, increase to 8-16 for maximum throughput if memory allows
```

#### Success Criteria
- ✅ README updated with comprehensive examples
- ✅ Help text clear and complete
- ✅ Use cases documented for common scenarios
- ✅ Troubleshooting guidance provided
- ✅ Performance implications explained

---

### Phase 5: Performance Baseline Establishment
**Status**: NOT STARTED  
**Prerequisites**: Phase 4 complete  
**Estimated Effort**: ~30-50 LOC + profiling time

#### Goal
Establish performance baselines using the new configuration options to understand current behavior and identify optimization opportunities.

#### Context
With configurable parameters now available, we can systematically measure performance across different configurations. This baseline data will:
- Identify current bottlenecks (CPU, network, memory, Redis processing)
- Establish performance expectations for different workload types
- Guide optimization efforts in subsequent phases
- Provide comparison data for measuring improvements

#### Scope
- Create baseline benchmark script
- Measure performance with various key/value size combinations
- Test different pipeline depths
- Compare standalone vs cluster mode performance
- Profile CPU usage and identify hot paths
- Measure memory usage patterns
- Document baseline results

#### Profiling Tools and Techniques

**1. Haskell Profiling (CPU & Memory)**
```bash
# Time-based profiling with -p flag
cabal run --enable-profiling -- fill -h localhost -f -d 1 \
  --key-size 512 --value-size 512 +RTS -p -RTS

# Heap profiling to detect memory leaks
cabal run --enable-profiling -- fill -h localhost -f -d 1 \
  --key-size 512 --value-size 512 +RTS -h -RTS
hp2ps -e18in -c redis-client.hp

# Memory allocation profiling
cabal run --enable-profiling -- fill -h localhost -f -d 1 \
  --key-size 512 --value-size 512 +RTS -hc -RTS

# Use Speedscope for interactive flamegraph analysis
# Upload .prof file to https://www.speedscope.app/
```

**2. System Resource Monitoring**
```bash
# Monitor CPU, memory, and I/O during fill operation
# Run in separate terminal:
top -p $(pgrep redis-client)

# Detailed system statistics
vmstat 1

# I/O statistics
iostat -x 1

# Memory usage tracking
watch -n 1 'free -h && ps aux | grep redis-client | head -1'
```

**3. Network Monitoring**
```bash
# Monitor network bandwidth utilization
iftop -i lo  # For localhost testing

# Network throughput and saturation
sar -n DEV 1  # Linux performance monitoring

# Packet-level analysis (if needed)
tcpdump -i lo port 6379 -w redis_traffic.pcap
```

**4. Redis Server Monitoring**
```bash
# Redis statistics during fill
redis-cli --stat

# Detailed INFO output
redis-cli INFO stats > redis_stats_before.txt
# Run fill operation
redis-cli INFO stats > redis_stats_after.txt

# Monitor commands per second
redis-cli --intrinsic-latency 100
```

**5. Memory Leak Detection**
```bash
# Use Valgrind for memory leak detection (if available)
valgrind --leak-check=full --show-leak-kinds=all \
  cabal run redis-client -- fill -h localhost -f -d 1

# GHC's built-in memory profiling
cabal run --enable-profiling -- fill -h localhost -f -d 1 \
  +RTS -hT -RTS  # Profile by closure type
```

**6. Bottleneck Identification Tools**
```bash
# CPU profiling with perf (Linux)
perf record -g cabal run redis-client -- fill -h localhost -f -d 1
perf report

# System call tracing to identify blocking operations
strace -c -p $(pgrep redis-client)

# Network latency measurement
ping localhost  # Baseline latency
```

#### Benchmark Test Matrix

Test the following combinations for baseline:

**Key Sizes**: 64, 256, 512, 1024, 2048 bytes  
**Value Sizes**: 512, 2048, 4096, 8192 bytes  
**Pipeline Depths**: 500, 1000, 2000, 5000 commands  
**Thread Counts**: 2, 4, 8 per node (cluster mode)  
**Modes**: Standalone, 3-node cluster, 5-node cluster

**Priority tests** (~20 combinations): Focus on common configurations first.

#### Baseline Benchmark Script Structure
```bash
#!/bin/bash
# benchmark/baseline-performance.sh

RESULTS_DIR="benchmark/baseline-results"
mkdir -p "$RESULTS_DIR"

echo "=== Fill Mode Baseline Performance Benchmarking ==="
echo "Results will be saved to $RESULTS_DIR"

# Test configurations (subset for baseline)
KEY_SIZES=(64 512 1024)
VALUE_SIZES=(512 2048 8192)
PIPELINE_DEPTHS=(1000 2000 5000)

# Standalone baseline tests
echo "=== Standalone Mode Baseline ==="
make redis-start

for key_size in "${KEY_SIZES[@]}"; do
  for value_size in "${VALUE_SIZES[@]}"; do
    for pipeline in "${PIPELINE_DEPTHS[@]}"; do
      echo "Testing: key=$key_size value=$value_size pipeline=$pipeline"
      
      # Profile with timing and memory tracking
      /usr/bin/time -v cabal run --enable-profiling -- fill \
        -h localhost -f -d 1 \
        --key-size "$key_size" \
        --value-size "$value_size" \
        --pipeline-depth "$pipeline" \
        +RTS -p -RTS \
        2>&1 | tee "$RESULTS_DIR/standalone_k${key_size}_v${value_size}_p${pipeline}.log"
      
      # Save profile data
      mv redis-client.prof "$RESULTS_DIR/standalone_k${key_size}_v${value_size}_p${pipeline}.prof"
      
      sleep 5  # Cool down between tests
    done
  done
done

make redis-stop

# Cluster baseline tests
echo "=== Cluster Mode Baseline (5 nodes) ==="
make redis-cluster-start

THREAD_COUNTS=(2 4)

for key_size in "${KEY_SIZES[@]}"; do
  for value_size in "${VALUE_SIZES[@]}"; do
    for pipeline in "${PIPELINE_DEPTHS[@]}"; do
      for threads in "${THREAD_COUNTS[@]}"; do
        echo "Testing: key=$key_size value=$value_size pipeline=$pipeline threads=$threads"
        
        /usr/bin/time -v cabal run --enable-profiling -- fill \
          -h localhost -c -f -d 1 \
          --key-size "$key_size" \
          --value-size "$value_size" \
          --pipeline-depth "$pipeline" \
          -n "$threads" \
          +RTS -p -RTS \
          2>&1 | tee "$RESULTS_DIR/cluster_k${key_size}_v${value_size}_p${pipeline}_t${threads}.log"
        
        mv redis-client.prof "$RESULTS_DIR/cluster_k${key_size}_v${value_size}_p${pipeline}_t${threads}.prof"
        
        sleep 5
      done
    done
  done
done

make redis-cluster-stop

echo "=== Baseline benchmarking complete ==="
echo "Results saved to $RESULTS_DIR"
echo ""
echo "Next steps:"
echo "1. Analyze .prof files for CPU hotspots"
echo "2. Review .log files for throughput metrics"
echo "3. Check for memory leaks in profiling data"
echo "4. Compare standalone vs cluster overhead"
```

#### Metrics to Collect

**Throughput Metrics:**
- MB/s written to Redis
- Keys per second
- Total time to complete fill operation
- Commands per second

**Resource Usage:**
- Peak memory consumption (RSS)
- CPU utilization percentage
- Network bandwidth utilization (MB/s)
- Network saturation indicators

**Latency Metrics:**
- Average latency per command
- P50, P95, P99 latency percentiles
- Cluster overhead (cluster time / standalone time)

**Bottleneck Indicators:**
- CPU-bound: High CPU usage (>80%), profiling shows computation hotspots
- Network-bound: Low CPU usage, high network utilization, bandwidth near capacity
- Redis-bound: Low CPU/network usage, high Redis CPU on server
- Memory-bound: High memory allocation rate, garbage collection pressure

#### Success Criteria
- ✅ Baseline benchmarks completed for standalone mode
- ✅ Baseline benchmarks completed for cluster mode (3 and 5 nodes)
- ✅ CPU profiles identify top 5 performance hotspots
- ✅ Memory profiles show no significant leaks
- ✅ Network saturation measured and documented
- ✅ Bottleneck type identified (CPU, network, Redis, or balanced)
- ✅ Cluster overhead quantified (<20% expected)
- ✅ Results documented in PERFORMANCE.md
- ✅ Baseline data available for comparison in Phase 6

#### Expected Findings
- Identify whether fill is CPU-bound, network-bound, or Redis-bound
- Understand impact of key/value sizes on throughput
- Determine optimal pipeline depth range for different scenarios
- Establish that current implementation has no memory leaks
- Quantify cluster mode overhead
- Identify specific code paths that dominate execution time

---

### Phase 6: Performance Optimization Based on Baseline
**Status**: NOT STARTED  
**Prerequisites**: Phase 5 complete  
**Estimated Effort**: ~30-100 LOC (depending on findings)

#### Goal
Address performance bottlenecks identified in Phase 5 baseline analysis.

#### Context
Phase 5 will identify specific bottlenecks and optimization opportunities. This phase implements targeted improvements based on those findings. The exact work will depend on Phase 5 results, but common optimization areas include:

- **If CPU-bound**: Optimize hot code paths, reduce allocations, improve algorithms
- **If network-bound**: Optimize pipelining, reduce protocol overhead, batch more efficiently
- **If memory-bound**: Reduce allocation rate, improve GC behavior, optimize data structures
- **If Redis-bound**: May be inherent Redis limits; focus on client-side optimizations

#### Potential Optimization Areas

**1. Reduce Memory Allocations**
```haskell
-- Example: Use strict ByteStrings throughout, avoid lazy evaluation
-- Example: Use builders for RESP protocol generation
-- Example: Reuse buffers where possible
```

**2. Improve Pipelining Efficiency**
```haskell
-- Example: Batch RESP protocol generation
-- Example: Optimize chunk size calculation
-- Example: Reduce intermediate data structures
```

**3. Optimize String/ByteString Operations**
```haskell
-- Example: Use more efficient ByteString construction
-- Example: Minimize copies
-- Example: Use pinned memory for large buffers
```

**4. Parallel Processing Improvements**
```haskell
-- Example: Better thread load balancing
-- Example: Reduce lock contention
-- Example: Optimize thread pool utilization
```

#### Scope
- Implement optimizations based on Phase 5 findings
- Re-run profiling to measure improvement
- Ensure no regressions in functionality
- Document optimizations and their impact
- Update baseline metrics

#### Implementation Strategy
1. Prioritize optimizations by expected impact
2. Implement one optimization at a time
3. Profile after each change to measure impact
4. Keep optimizations that show >5% improvement
5. Revert optimizations that show no improvement or regressions

#### Success Criteria
- ✅ Implemented at least 2-3 optimizations based on baseline findings
- ✅ Achieved measurable performance improvement (target: >10% throughput increase)
- ✅ No functionality regressions
- ✅ All tests still pass
- ✅ Profiling confirms reduced CPU usage or improved throughput
- ✅ Optimizations documented with before/after metrics

---

### Phase 7: Comprehensive Performance Testing
**Status**: NOT STARTED  
**Prerequisites**: Phase 6 complete  
**Estimated Effort**: ~20-30 LOC + extensive testing time

#### Goal
Systematically test all parameter combinations to identify optimal configurations for different use cases.

#### Context
With configuration options available and optimizations implemented, systematically explore the parameter space to find optimal settings for:
- Maximum throughput
- Memory efficiency
- Session cache workload
- Object cache workload
- Balanced performance

#### Scope
- Execute comprehensive benchmark matrix
- Analyze results to identify optimal configurations
- Document recommended settings for each use case
- Update documentation with findings
- Create comparison charts/tables

#### Test Matrix (Comprehensive)

**Key Sizes**: 64, 128, 256, 512, 1024, 2048 bytes (6 values)  
**Value Sizes**: 256, 512, 1024, 2048, 4096, 8192, 16384 bytes (7 values)  
**Pipeline Depths**: 100, 500, 1000, 2000, 5000, 10000 commands (6 values)  
**Thread Counts**: 1, 2, 4, 8, 16 per node (5 values)  
**Cluster Sizes**: Standalone, 3-node, 5-node (3 values)

**Total possible combinations**: 6 × 7 × 6 × 5 × 3 = 3,780 tests

**Practical approach**: Test ~100-150 high-priority combinations focusing on:
- Common workload patterns
- Extreme values (min/max)
- Balanced configurations

#### Analysis Approach
1. **Extract metrics** from benchmark logs (throughput, memory, time)
2. **Identify top performers** for each use case
3. **Analyze patterns**: Which parameters have most impact?
4. **Document trade-offs**: Throughput vs memory, speed vs stability
5. **Create recommendations**: Simple guidelines for users

#### Expected Optimal Configurations

**Maximum Throughput:**
- Key size: 1024 bytes (hypothesis)
- Value size: 4096 bytes (hypothesis)
- Pipeline depth: 2000-5000 commands
- Threads: 8-16 per node
- Expected improvement: 30-50% over defaults

**Memory Efficient:**
- Key size: 64-128 bytes
- Value size: 512-1024 bytes
- Pipeline depth: 500-1000 commands
- Threads: 2 per node
- Expected memory: 50% of default

**Session Cache Simulation:**
- Key size: 64 bytes
- Value size: 256 bytes
- Pipeline depth: 5000-10000 commands
- Threads: 4-8 per node

**Object Cache Simulation:**
- Key size: 256 bytes
- Value size: 8192-16384 bytes
- Pipeline depth: 500-1000 commands
- Threads: 2-4 per node

#### Success Criteria
- ✅ Comprehensive benchmark results documented
- ✅ Optimal configurations identified for at least 4 use cases
- ✅ Performance improvement >20% demonstrated for at least one use case
- ✅ PERFORMANCE.md created with detailed results
- ✅ README updated with recommended configurations
- ✅ Clear guidelines provided for parameter selection

---

### Phase 8: Preset Profiles (Optional Enhancement)
**Status**: NOT STARTED  
**Prerequisites**: Phase 7 complete  
**Estimated Effort**: ~30-50 LOC

#### Goal
Add preset configuration profiles based on Phase 7 findings to simplify user experience.

#### Context
Phase 7 will identify optimal configurations for different scenarios. Presets package these configurations for easy use without requiring users to remember complex flag combinations.

#### Scope
- Add `--preset PROFILE` flag to fill mode
- Implement preset profiles based on Phase 7 findings
- Presets set defaults for `--key-size`, `--value-size`, `--pipeline-depth`, and `-n`
- Users can override preset values with explicit flags
- Document presets in README and help text

#### Proposed Presets (based on Phase 7 results)
```
--preset fast
  Optimized for maximum throughput
  Estimated settings: --key-size 1024 --value-size 4096 --pipeline-depth 2000 -n 8
  
--preset balanced
  Good throughput with moderate memory usage
  Estimated settings: --key-size 512 --value-size 2048 --pipeline-depth 1000 -n 4
  
--preset memory-efficient
  Minimizes memory usage
  Estimated settings: --key-size 128 --value-size 512 --pipeline-depth 1000 -n 2
  
--preset session-cache
  Simulates session cache workload (small keys/values)
  Estimated settings: --key-size 64 --value-size 256 --pipeline-depth 5000 -n 4
  
--preset object-cache
  Simulates object cache workload (large values)
  Estimated settings: --key-size 256 --value-size 8192 --pipeline-depth 1000 -n 4
```

Note: Exact parameter values will be determined by Phase 7 results.

#### Implementation Notes
- Presets apply defaults but can be overridden:
  ```bash
  # Use fast preset but override thread count
  redis-client fill -h localhost -c -d 10 --preset fast -n 16
  ```
- Add preset validation
- Update help text with preset descriptions
- Document in README with examples

#### Key Files to Modify
- **`app/Main.hs`** - Add `--preset` flag and preset logic
- **`README.md`** - Document presets with examples

#### Usage Examples
```bash
# Use fast preset for maximum throughput
redis-client fill -h localhost -c -d 10 --preset fast

# Use session-cache preset for testing
redis-client fill -h localhost -c -d 5 --preset session-cache

# Use preset with overrides
redis-client fill -h localhost -c -d 10 --preset balanced -n 16

# Mix preset with additional flags
redis-client fill -h localhost -c -d 10 --preset fast --flush
```

#### Success Criteria
- ✅ All presets work correctly
- ✅ Presets can be overridden by explicit flags
- ✅ Clear error message for invalid preset names
- ✅ Help text and README document all presets
- ✅ Tests verify preset behavior
- ✅ User experience significantly improved (fewer flags to remember)

---

## Implementation Timeline

**Estimated Total Effort**: 180-320 LOC + significant testing/benchmarking time

### Recommended Order
1. **Phase 1** (3-5 days) - Add key size configuration
2. **Phase 2** (3-5 days) - Add value size configuration
3. **Phase 3** (3-5 days) - Add pipeline depth configuration
4. **Phase 4** (2-3 days) - Update documentation
5. **Phase 5** (1-2 weeks) - Establish baseline and learn profiling tools
6. **Phase 6** (1-2 weeks) - Optimize based on findings
7. **Phase 7** (2-3 weeks) - Comprehensive performance testing
8. **Phase 8** (3-5 days) - Optional presets

**Total estimated time**: 6-10 weeks

### Dependencies
```
Phase 1 (Key Size)
    ↓
Phase 2 (Value Size)
    ↓
Phase 3 (Pipeline Depth)
    ↓
Phase 4 (Documentation)
    ↓
Phase 5 (Baseline + Profiling)
    ↓
Phase 6 (Optimization)
    ↓
Phase 7 (Comprehensive Testing)
    ↓
Phase 8 (Presets - Optional)
```

---

## Success Metrics

### Phase 1-3 (Configuration)
- All configuration flags implemented and working
- Backward compatibility maintained
- Parameter validation effective

### Phase 4 (Documentation)
- Clear, comprehensive documentation
- Examples for common use cases
- Troubleshooting guidance

### Phase 5 (Baseline)
- Baseline metrics established
- Bottlenecks identified using profiling tools
- No memory leaks detected

### Phase 6 (Optimization)
- Performance improvement >10% achieved
- No functionality regressions
- Optimizations documented

### Phase 7 (Testing)
- Optimal configurations identified for 4+ use cases
- Performance improvement >20% in at least one scenario
- Comprehensive results documented

### Phase 8 (Presets - Optional)
- Convenient presets simplify UX
- User adoption improved

---

## Tools Reference

### Profiling & Performance Analysis
- **GHC Profiler** (`+RTS -p`): Time-based CPU profiling
- **Heap Profiler** (`+RTS -h`): Memory allocation profiling
- **hp2ps**: Convert heap profiles to PostScript
- **Speedscope**: Interactive flamegraph viewer (https://www.speedscope.app/)
- **Valgrind**: Memory leak detection
- **perf** (Linux): System-level performance profiling
- **strace**: System call tracing

### System Monitoring
- **top/htop**: Real-time process monitoring
- **vmstat**: Virtual memory statistics
- **iostat**: I/O statistics
- **sar**: System activity reporter
- **free**: Memory usage

### Network Analysis
- **iftop**: Network bandwidth monitoring
- **tcpdump**: Packet capture and analysis
- **redis-cli --stat**: Redis server statistics
- **redis-cli INFO**: Detailed Redis metrics

### Memory Leak Detection
- **GHC heap profiling** (`+RTS -hT`, `-hc`): Identify allocation sources
- **Valgrind massif**: Heap profiler
- **Continuous monitoring**: Watch memory usage during long-running fills

---

## Future Considerations

After completing this implementation plan, consider:
- **Connection pool enhancements** - Support multiple connections per node
- **Advanced pipelining** - Implement pipelining for other commands
- **Adaptive tuning** - Auto-detect optimal parameters based on runtime conditions
- **Real-world workload simulation** - More sophisticated data generation patterns
- **Benchmark automation** - CI/CD integration for continuous performance monitoring

---

## Notes

- This document focuses exclusively on fill operation configuration and performance
- Configuration is implemented first (Phases 1-4) before benchmarking (Phases 5-7)
- Phases 1-7 are recommended; Phase 8 is optional but enhances UX
- All phases maintain backward compatibility
- Performance improvements are estimates and will vary by environment
- Profiling and optimization are data-driven, based on actual measurements
