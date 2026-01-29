# Performance Benchmarking Guide

This guide provides instructions for benchmarking the Redis client performance improvements.

## Quick Start

### Option 1: Automated Benchmark Script

Run the provided benchmark script to automatically test both versions:

```bash
# Start Redis server (if not already running)
docker compose up -d redis

# Run the benchmark (default: 1GB test)
./benchmark.sh

# Or with custom size
TEST_SIZE_GB=2 ./benchmark.sh
```

The script will:
1. Build and test the baseline version (before optimizations)
2. Build and test the optimized version (after optimizations)
3. Compare results and show improvement percentage

### Option 2: Manual Testing

If you prefer to test manually:

#### 1. Test Baseline (Before Optimizations)

```bash
# Checkout the commit before optimizations
git checkout 3176667

# Build
cabal build redis-client

# Start Redis
docker compose up -d redis

# Flush and run test
time cabal run redis-client -- fill -h localhost -d 1 -f
```

Note the time taken and keys written.

#### 2. Test Optimized Version

```bash
# Checkout the latest optimized version
git checkout 93df980

# Build
cabal build redis-client

# Flush and run test
time cabal run redis-client -- fill -h localhost -d 1 -f
```

Compare the time taken and throughput with baseline.

## Expected Results

Based on the optimizations implemented:

| Metric | Baseline | Optimized | Improvement |
|--------|----------|-----------|-------------|
| Receive Buffer | 4KB | 64KB | 16x fewer syscalls |
| TCP_NODELAY | Disabled | Enabled | No ACK delays |
| Command Gen | Parse/rebuild | Direct | ~30% faster |
| **Overall** | **Baseline** | **50-70% faster** | **Target** |

## Configuration Options

### Environment Variables

Test different configurations:

```bash
# Test with 128KB receive buffer
export REDIS_CLIENT_RECV_BUFFER_SIZE=131072
./benchmark.sh

# Test with 512MB chunks
export REDIS_CLIENT_FILL_CHUNK_KB=524288
TEST_SIZE_GB=2 ./benchmark.sh

# Test with TLS (if configured)
export REDIS_CLIENT_TLS_INSECURE=1
./benchmark.sh
```

### Test Sizes

Adjust the test size based on your needs:

```bash
# Quick test (500MB)
TEST_SIZE_GB=0.5 ./benchmark.sh

# Standard test (1GB) - default
TEST_SIZE_GB=1 ./benchmark.sh

# Large test (5GB) - recommended for production-like testing
TEST_SIZE_GB=5 ./benchmark.sh
```

## Interpreting Results

### Key Metrics

1. **Time Reduction**: Should be 50-70% faster
2. **Throughput**: Keys written per second
3. **Consistency**: Run multiple times to verify consistency

### Sample Output

```
============================================
Benchmark Results
============================================

Configuration:
  Test Size: 1GB
  Redis Host: localhost:6379

Baseline (Before Optimizations):
  Time: 45.23s
  Keys Written: 1024000
  Throughput: 22638.52 keys/sec

Optimized (After Optimizations):
  Time: 18.91s
  Keys Written: 1024000
  Throughput: 54154.13 keys/sec

Performance Improvement:
  Time Reduction: 58.21%
  Speedup: 2.39x

✓ Performance improvement of 58.21% meets the 50-70% target!
```

## Troubleshooting

### Build Takes Too Long

The first build can take 3-4 minutes due to dependency compilation. Subsequent builds are faster.

### Redis Connection Failed

```bash
# Check if Redis is running
docker ps | grep redis

# Start Redis if needed
docker compose up -d redis

# Test connectivity
redis-cli -h localhost -p 6379 PING
```

### Out of Memory

For large tests (5GB+), ensure you have sufficient memory:

```bash
# Check available memory
free -h

# Use smaller chunks if needed
export REDIS_CLIENT_FILL_CHUNK_KB=262144  # 256MB chunks
TEST_SIZE_GB=5 ./benchmark.sh
```

## Advanced: Comparing with Stack Exchange Redis

To compare with Stack Exchange Redis (C# client):

1. Install Stack Exchange Redis NuGet package
2. Create a similar fill test in C#
3. Run both tests with same data size
4. Compare throughput and latency

Example C# benchmark pattern:
```csharp
var sw = Stopwatch.StartNew();
var tasks = new List<Task>();
for (int i = 0; i < 1024000; i++) {
    tasks.Add(db.StringSetAsync($"key_{i}", value, flags: CommandFlags.FireAndForget));
    if (tasks.Count >= 1000) {
        await Task.WhenAll(tasks);
        tasks.Clear();
    }
}
sw.Stop();
Console.WriteLine($"Time: {sw.ElapsedMilliseconds}ms");
```

## Notes

- The benchmark script automatically handles git checkouts and builds
- Results are saved to `/tmp/redis_benchmark_TIMESTAMP/`
- Run tests multiple times to account for variance
- Ensure no other processes are heavily using network/CPU during tests
- For production validation, test with realistic data patterns and sizes
