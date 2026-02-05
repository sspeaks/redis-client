# Fill Operation Configuration & Performance - Implementation Plan

## Current Status

**Completed**: Core fill functionality for both standalone and cluster modes  
**Next Priority**: Phase 1 - Performance Benchmarking & Profiling  
**Document Version**: 1.0  
**Last Updated**: 2026-02-05

---

## Overview

This document outlines a multi-phase plan to enhance the fill operation with configurable parameters and systematic performance optimization. The fill operation currently works well but uses hardcoded values for key/value sizes and derives pipelining depth from environment variables. This plan will add fine-grained control over these parameters and establish optimal configurations for various scenarios.

---

## What's Next?

### Phase 1: Performance Benchmarking & Profiling
**Status**: NOT STARTED  
**Prerequisites**: None (baseline phase)  
**Estimated Effort**: ~50-100 LOC + profiling time

#### Goal
Establish performance baselines for fill mode and understand current bottlenecks before implementing configuration enhancements.

#### Context
Before adding configuration parameters, we need to understand:
- Current fill mode throughput (MB/s, keys/s)
- Memory usage patterns during fill operations
- Performance differences between standalone and cluster modes
- Current bottlenecks (CPU, network, or Redis itself)
- Impact of existing `REDIS_CLIENT_FILL_CHUNK_KB` environment variable

This baseline will inform which parameters are most important to make configurable.

#### Scope
- Benchmark fill mode in standalone mode
- Benchmark fill mode in cluster mode
- Compare cluster vs standalone throughput
- Measure cluster mode latency overhead
- Profile current implementation to identify bottlenecks
- Measure memory usage with various cluster sizes
- Document performance characteristics
- Test impact of `REDIS_CLIENT_FILL_CHUNK_KB` values (1024, 2048, 4096, 8192 KB)

#### Implementation Notes
- Use `cabal run --enable-profiling -- {flags}` with `-p` RTS flag for profiling
- Profile before/after to detect any regressions
- Test with various data sizes: 1GB, 5GB, 10GB
- Test with various thread counts: 1, 2, 4, 8, 16 per node
- Document results in separate PERFORMANCE.md document or README section
- Use consistent hardware for all benchmarks (document specs)

#### Test Environment Setup
```bash
# Start local standalone Redis
make redis-start

# Profile standalone fill
cabal run --enable-profiling -- fill -h localhost -f -d 1 +RTS -p -RTS

# Start local cluster
make redis-cluster-start

# Profile cluster fill
cabal run --enable-profiling -- fill -h localhost -c -f -d 1 +RTS -p -RTS

# Clean up
make redis-cluster-stop
rm -f *.prof *.hp *.ps *.aux *.stat
```

#### Metrics to Collect
- **Throughput**: MB/s written to Redis
- **Keys per second**: Number of keys SET per second
- **Total time**: Time to complete fill operation
- **Memory usage**: Peak memory consumption during fill
- **CPU usage**: Profiling data showing hot paths
- **Network I/O**: If measurable, bandwidth utilization
- **Latency overhead**: Cluster vs standalone time difference

#### Success Criteria
- ✅ Baseline metrics documented for standalone mode
- ✅ Baseline metrics documented for cluster mode
- ✅ Performance comparison documented (cluster vs standalone overhead)
- ✅ Memory usage documented (various cluster sizes: 3, 5, 10 nodes)
- ✅ Profiling data identifies optimization opportunities
- ✅ Results documented in PERFORMANCE.md or README

#### Expected Findings
- Identify if current bottleneck is network, CPU, or Redis processing
- Determine if pipelining depth is optimal
- Understand impact of key/value sizes on throughput
- Establish that cluster mode overhead is acceptable (<10-20%)
- Identify most impactful parameters to make configurable

---

### Phase 2: Fill Mode Configuration Enhancement
**Status**: NOT STARTED  
**Prerequisites**: Phase 1 complete  
**Estimated Effort**: ~50-100 LOC

#### Goal
Add configurable parameters for fill mode to enable fine-tuning of key/value sizes and command batching for optimal performance.

#### Context
Currently, fill mode uses hardcoded values:
- **Key size**: 512 bytes (fixed in code)
- **Value size**: 512 bytes (fixed in code)
- **Chunk size**: Configurable via `REDIS_CLIENT_FILL_CHUNK_KB` environment variable (default: 8192 KB, range: 1024-8192 KB)
- **Number of commands per chunk**: Derived from chunk size and key/value size

To optimize fill performance for different cache configurations and network conditions, we need configurable control over:
1. **Key/Value size**: Affects network payload, Redis memory layout, and throughput
2. **Commands per pipeline**: Number of commands batched together (explicit pipelining depth control)

#### Why This Matters
- Different use cases require different key/value sizes (e.g., session cache vs object cache)
- Optimal pipelining depth varies with network latency and Redis configuration
- Current hardcoded values may not be optimal for all scenarios
- Users need ability to match their production workload characteristics

#### Scope
- Add command-line flags for key size and value size
- Add flag for explicit control of commands per pipeline batch
- Update `Filler.hs` to use configurable sizes (standalone mode)
- Update `ClusterFiller.hs` to use configurable sizes (cluster mode)
- Maintain backward compatibility with `REDIS_CLIENT_FILL_CHUNK_KB` environment variable
- Document new flags in README and help text
- Validate parameter ranges to prevent invalid values
- Add default values that match current behavior (512/512/8192)

#### Key Files to Modify
- **`app/Main.hs`** - Add new command-line arguments and help text
- **`app/Filler.hs`** - Update `fillCacheWithDataMB` to accept key size, value size, and pipeline depth parameters
- **`app/ClusterFiller.hs`** - Update `fillNodeWithData` and `generateClusterChunk` to accept and use configurable sizes
- **`README.md`** - Document new flags with examples

#### Proposed Command-Line Flags
```
--key-size BYTES
  Size of each key in bytes
  Default: 512
  Range: 1-65536 bytes
  
--value-size BYTES
  Size of each value in bytes
  Default: 512
  Range: 1-524288 bytes (512 KB max)
  
--pipeline-depth NUM
  Number of SET commands per pipeline batch
  Default: derived from chunk size
  Range: 1-100000 commands
  If specified, overrides chunk size calculation
```

#### Implementation Notes
- **Flag precedence**: If `--pipeline-depth` is set, it takes precedence over `REDIS_CLIENT_FILL_CHUNK_KB`
- **Chunk size calculation**: When pipeline depth is explicit, chunk size = `pipeline-depth * (key-size + value-size + protocol overhead)`
- **Protocol overhead**: Approximately 40-60 bytes per SET command for RESP protocol
- **Backward compatibility**: Existing behavior unchanged when new flags not specified
- **Validation**: Reject invalid combinations or values outside reasonable ranges
- **Error messages**: Provide clear error messages for invalid parameter values

#### Parameter Validation
```haskell
-- Validate key size
validateKeySize :: Int -> Either String Int
validateKeySize size
  | size < 1 = Left "Key size must be at least 1 byte"
  | size > 65536 = Left "Key size must not exceed 65536 bytes"
  | otherwise = Right size

-- Validate value size
validateValueSize :: Int -> Either String Int
validateValueSize size
  | size < 1 = Left "Value size must be at least 1 byte"
  | size > 524288 = Left "Value size must not exceed 524288 bytes"
  | otherwise = Right size

-- Validate pipeline depth
validatePipelineDepth :: Int -> Either String Int
validatePipelineDepth depth
  | depth < 1 = Left "Pipeline depth must be at least 1"
  | depth > 100000 = Left "Pipeline depth must not exceed 100000"
  | otherwise = Right depth
```

#### Usage Examples
```bash
# Small keys and values (session cache simulation)
redis-client fill -h localhost -d 1 --key-size 64 --value-size 128

# Large values (object cache simulation)
redis-client fill -h localhost -d 1 --key-size 256 --value-size 8192

# Custom pipelining depth (low latency network)
redis-client fill -h localhost -d 1 --pipeline-depth 5000

# Combination (cluster mode, tuned for throughput)
redis-client fill -h localhost -c -d 5 --key-size 512 --value-size 2048 --pipeline-depth 2000

# Backward compatibility (using environment variable)
REDIS_CLIENT_FILL_CHUNK_KB=4096 redis-client fill -h localhost -d 1
```

#### Success Criteria
- ✅ All new flags work correctly in standalone mode
- ✅ All new flags work correctly in cluster mode
- ✅ Backward compatibility maintained (existing behavior unchanged when flags not specified)
- ✅ `REDIS_CLIENT_FILL_CHUNK_KB` environment variable still works
- ✅ Parameter validation works and provides clear error messages
- ✅ All existing tests pass
- ✅ New unit tests added for parameter validation
- ✅ README updated with examples and documentation
- ✅ Help text (`--help`) updated with new flags

---

### Phase 3: Fill Mode Performance Optimization
**Status**: NOT STARTED  
**Prerequisites**: Phase 2 complete  
**Estimated Effort**: ~20-50 LOC (mostly testing/tuning)

#### Goal
Systematically tune fill mode parameters (key/value size, pipeline depth, thread count) to determine optimal values for maximum cache fill throughput.

#### Context
With Phase 2 adding configurable parameters, we can now empirically determine the best settings for different scenarios:
- Different cluster sizes (3, 5, 10 nodes)
- Different network conditions (local, cross-region)
- Different Redis configurations (memory limits, persistence settings)
- Different workload characteristics (small/large keys, small/large values)

This phase will establish recommended configurations for common use cases.

#### Scope
- Create comprehensive benchmark script to test various parameter combinations
- Execute systematic tests across parameter space
- Measure throughput (MB/s, keys/s) for each combination
- Profile memory usage for each combination
- Document optimal settings for different scenarios
- Update README with recommended configurations
- Consider adding preset profiles for common scenarios

#### Test Matrix
Test the following parameter combinations:

**Key Sizes**: 64, 128, 256, 512, 1024, 2048 bytes  
**Value Sizes**: 512, 1024, 2048, 4096, 8192, 16384 bytes  
**Pipeline Depths**: 100, 500, 1000, 2000, 5000, 10000 commands  
**Thread Counts**: 1, 2, 4, 8, 16 per node (cluster mode)  
**Cluster Sizes**: Standalone, 3-node, 5-node, 10-node clusters  

**Total combinations**: ~50-100 high-priority tests (not exhaustive)

#### Key Files
- **Create `benchmark/fill-performance.sh`** - Benchmark automation script
- **Create `benchmark/analyze-results.py`** - Results analysis script (optional)
- **Update `README.md`** or create **`PERFORMANCE.md`** - Document findings
- **Potentially update `app/Main.hs`** - Add preset profiles (e.g., `--preset fast`, `--preset balanced`, `--preset memory-efficient`)

#### Benchmark Script Structure
```bash
#!/bin/bash
# benchmark/fill-performance.sh

RESULTS_DIR="benchmark/results"
mkdir -p "$RESULTS_DIR"

echo "Starting fill mode performance benchmarking..."
echo "Results will be saved to $RESULTS_DIR"

# Test configurations
KEY_SIZES=(64 128 256 512 1024)
VALUE_SIZES=(512 1024 2048 4096 8192)
PIPELINE_DEPTHS=(100 500 1000 2000 5000 10000)
THREAD_COUNTS=(2 4 8)

# Standalone tests
echo "=== Standalone Mode Tests ==="
make redis-start

for key_size in "${KEY_SIZES[@]}"; do
  for value_size in "${VALUE_SIZES[@]}"; do
    for pipeline in "${PIPELINE_DEPTHS[@]}"; do
      echo "Testing: key=$key_size value=$value_size pipeline=$pipeline"
      
      # Profile with timing
      /usr/bin/time -v cabal run --enable-profiling -- fill \
        -h localhost -f -d 1 \
        --key-size "$key_size" \
        --value-size "$value_size" \
        --pipeline-depth "$pipeline" \
        +RTS -p -RTS \
        2>&1 | tee "$RESULTS_DIR/standalone_k${key_size}_v${value_size}_p${pipeline}.log"
      
      # Save profile
      mv redis-client.prof "$RESULTS_DIR/standalone_k${key_size}_v${value_size}_p${pipeline}.prof"
      
      sleep 5  # Cool down between tests
    done
  done
done

make redis-stop

# Cluster tests
echo "=== Cluster Mode Tests ==="
make redis-cluster-start

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

echo "Benchmarking complete! Results in $RESULTS_DIR"
```

#### Analysis Approach
1. **Extract metrics from logs**:
   - Total time (from `/usr/bin/time`)
   - Memory usage (from `/usr/bin/time`)
   - Throughput (calculate from data size and time)
   - Keys per second (calculate from keys and time)

2. **Identify optimal configurations**:
   - Maximum throughput configuration
   - Balanced throughput/memory configuration
   - Low-resource configuration
   - Small-key configuration (session cache)
   - Large-value configuration (object cache)

3. **Document findings**:
   - Create summary table of top configurations
   - Explain why certain parameters work better
   - Provide recommendations for different use cases

#### Expected Optimal Configurations

**Maximum Throughput** (preliminary hypothesis):
- Key size: 512-1024 bytes
- Value size: 2048-4096 bytes
- Pipeline depth: 2000-5000 commands
- Threads: 4-8 per node
- Expected improvement: 20-50% over defaults

**Balanced** (good throughput, moderate memory):
- Key size: 256-512 bytes
- Value size: 1024-2048 bytes
- Pipeline depth: 1000-2000 commands
- Threads: 4 per node
- Expected improvement: 10-30% over defaults

**Low Resource** (memory constrained):
- Key size: 64-128 bytes
- Value size: 512-1024 bytes
- Pipeline depth: 500-1000 commands
- Threads: 2 per node
- Expected improvement: Memory usage 50% of defaults

**Session Cache** (small keys/values):
- Key size: 64 bytes
- Value size: 128-256 bytes
- Pipeline depth: 5000-10000 commands
- Threads: 4-8 per node

**Object Cache** (large values):
- Key size: 256 bytes
- Value size: 8192-16384 bytes
- Pipeline depth: 500-1000 commands
- Threads: 2-4 per node

#### Implementation Notes
- Use consistent test environment (Docker containers with fixed resources)
- Document hardware specs: CPU, RAM, network
- Multiple runs per configuration to average out variance
- Monitor Redis server metrics (CPU, memory) during tests
- Consider network bandwidth as potential bottleneck
- Profile with `-p` flag for easy comparison
- Results will vary by environment; provide general guidelines

#### Documentation Updates
Update README.md with recommended configurations:

```markdown
## Performance Tuning

### Fill Mode Configuration

The fill operation can be tuned for different scenarios:

#### Maximum Throughput
For fastest cache population:
```bash
redis-client fill -h localhost -c -d 10 -f \
  --key-size 1024 --value-size 4096 --pipeline-depth 2000 -n 8
```

#### Memory Efficient
For memory-constrained environments:
```bash
redis-client fill -h localhost -c -d 10 -f \
  --key-size 128 --value-size 512 --pipeline-depth 1000 -n 2
```

#### Session Cache Simulation
Small keys and values:
```bash
redis-client fill -h localhost -c -d 10 -f \
  --key-size 64 --value-size 256 --pipeline-depth 5000 -n 4
```

#### Object Cache Simulation
Large values:
```bash
redis-client fill -h localhost -c -d 10 -f \
  --key-size 256 --value-size 8192 --pipeline-depth 1000 -n 4
```

See [PERFORMANCE.md](PERFORMANCE.md) for detailed benchmarking results and analysis.
```

#### Success Criteria
- ✅ Comprehensive benchmark results documented
- ✅ Optimal parameters identified for at least 3 scenarios:
  - Maximum throughput
  - Balanced throughput/memory
  - Low-resource
- ✅ README or PERFORMANCE.md updated with recommendations
- ✅ Performance improvement over default settings demonstrated (target: >20% improvement in at least one scenario)
- ✅ Documentation includes clear guidelines for choosing parameters
- ✅ Results reproducible by others (via benchmark script)

---

### Phase 4: Preset Profiles (Optional Enhancement)
**Status**: NOT STARTED  
**Prerequisites**: Phase 3 complete  
**Estimated Effort**: ~30-50 LOC

#### Goal
Add preset configuration profiles based on Phase 3 findings to make it easier for users to optimize fill performance without remembering complex flag combinations.

#### Context
Phase 3 will identify optimal parameter combinations for common scenarios. Instead of requiring users to remember and type long command lines with multiple flags, we can provide convenient presets.

#### Scope
- Add `--preset PROFILE` flag to fill mode
- Implement preset profiles: `fast`, `balanced`, `memory-efficient`, `session-cache`, `object-cache`
- Presets set default values for `--key-size`, `--value-size`, `--pipeline-depth`, and `-n` (threads)
- Users can override preset values with explicit flags
- Document presets in README and help text

#### Proposed Presets
```
--preset fast
  Optimized for maximum throughput
  Sets: --key-size 1024 --value-size 4096 --pipeline-depth 2000 -n 8
  
--preset balanced
  Good throughput with moderate memory usage
  Sets: --key-size 512 --value-size 2048 --pipeline-depth 1000 -n 4
  
--preset memory-efficient
  Minimizes memory usage
  Sets: --key-size 128 --value-size 512 --pipeline-depth 1000 -n 2
  
--preset session-cache
  Simulates session cache workload (small keys/values)
  Sets: --key-size 64 --value-size 256 --pipeline-depth 5000 -n 4
  
--preset object-cache
  Simulates object cache workload (large values)
  Sets: --key-size 256 --value-size 8192 --pipeline-depth 1000 -n 4
```

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
- **`README.md`** - Document presets

#### Success Criteria
- ✅ All presets work correctly
- ✅ Presets can be overridden by explicit flags
- ✅ Clear error message for invalid preset names
- ✅ Help text and README document all presets
- ✅ Tests verify preset behavior

---

## Implementation Timeline

**Estimated Total Effort**: 120-250 LOC + significant testing/benchmarking time

### Recommended Order
1. **Phase 1** (1-2 weeks) - Critical for understanding current state
2. **Phase 2** (1 week) - Core functionality
3. **Phase 3** (2-3 weeks) - Time-consuming but valuable
4. **Phase 4** (3-5 days) - Optional polish

### Dependencies
```
Phase 1 (Baseline)
    ↓
Phase 2 (Configuration)
    ↓
Phase 3 (Optimization)
    ↓
Phase 4 (Presets - Optional)
```

---

## Success Metrics

### Phase 1
- Performance baselines established
- Bottlenecks identified
- Memory usage documented

### Phase 2
- Configuration flags implemented and tested
- Backward compatibility maintained
- Documentation complete

### Phase 3
- Optimal configurations identified for 3+ scenarios
- >20% performance improvement in at least one scenario
- Comprehensive documentation of findings

### Phase 4 (Optional)
- Convenient presets reduce command complexity
- User experience improved

---

## Future Considerations

After completing this implementation plan, consider:
- **Connection pool enhancements** - Support multiple connections per node (see original clustering plan Phase 16)
- **Advanced pipelining** - Implement pipelining for other commands beyond fill mode
- **Adaptive tuning** - Auto-detect optimal parameters based on runtime conditions
- **Real-world workload simulation** - Add more sophisticated data generation patterns

---

## Notes

- This document focuses exclusively on fill operation configuration and performance
- The original clustering implementation plan covered broader cluster support features
- Phases 1-3 are recommended; Phase 4 is optional but enhances user experience
- All phases maintain backward compatibility
- Performance improvements are estimates and will vary by environment
