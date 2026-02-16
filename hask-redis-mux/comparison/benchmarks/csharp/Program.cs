using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using StackExchange.Redis;

class Program
{
    static int NumThreads = Environment.ProcessorCount;

    static async Task Main(string[] args)
    {
        string connString = args.Length > 0 ? args[0] : "localhost:7000,localhost:7001,localhost:7002,localhost:7003,localhost:7004";
        Console.Error.WriteLine($"Connecting to cluster: {connString}");

        var options = ConfigurationOptions.Parse(connString);
        options.AbortOnConnectFail = false;
        options.ConnectTimeout = 5000;

        using var connection = ConnectionMultiplexer.Connect(options);
        var db = connection.GetDatabase();

        Console.Error.WriteLine($"Starting cluster benchmarks ({NumThreads} threads)...");

        var results = new Dictionary<string, object>();

        // PING - distributed across threads
        results["ping"] = await RunBenchmark("ping", 10000, async i => { await db.PingAsync(); });

        // SET with distributed unique keys (matching Haskell's mkKey pattern)
        results["set"] = await RunBenchmark("set", 10000, async i => { await db.StringSetAsync($"bench:set:{i}", "bench:value"); });

        // Pre-populate read key pool (matching Haskell's readKeyPool)
        int readKeyPool = 10000;
        Console.Error.WriteLine("  Pre-populating read key pool...");
        var populateTasks = Enumerable.Range(0, readKeyPool)
            .Select(i => db.StringSetAsync($"bench:r:{i}", $"val{i}"));
        await Task.WhenAll(populateTasks);

        // GET with distributed keys from pool
        results["get"] = await RunBenchmark("get", 10000, async i =>
            { await db.StringGetAsync($"bench:r:{i % readKeyPool}"); });

        // DEL with unique keys per iteration
        results["del"] = await RunBenchmark("del", 10000, async i =>
        {
            var key = $"bench:del:{i}";
            await db.StringSetAsync(key, "v");
            await db.KeyDeleteAsync(key);
        });

        // Pipeline (batch) benchmark - keys from pool
        results["pipeline_100_gets"] = await RunBenchmark("pipeline_100_gets", 1000, async i =>
        {
            var batch = db.CreateBatch();
            var tasks = new List<Task<RedisValue>>();
            for (int j = 0; j < 100; j++)
                tasks.Add(batch.StringGetAsync($"bench:r:{(i * 100 + j) % readKeyPool}"));
            batch.Execute();
            await Task.WhenAll(tasks);
        });

        // GET batch benchmarks (keys from pool distribute across all slots)
        results["get_10"] = await RunBenchmark("get_10", 5000, async i =>
        {
            for (int j = 0; j < 10; j++) await db.StringGetAsync($"bench:r:{(i * 10 + j) % readKeyPool}");
        });
        results["get_100"] = await RunBenchmark("get_100", 2000, async i =>
        {
            for (int j = 0; j < 100; j++) await db.StringGetAsync($"bench:r:{(i * 100 + j) % readKeyPool}");
        });
        results["get_1000"] = await RunBenchmark("get_1000", 500, async i =>
        {
            for (int j = 0; j < 1000; j++) await db.StringGetAsync($"bench:r:{(i * 1000 + j) % readKeyPool}");
        });

        // SET batch benchmarks with distributed keys
        results["set_10"] = await RunBenchmark("set_10", 5000, async i =>
        {
            for (int j = 0; j < 10; j++) await db.StringSetAsync($"bench:mset:{i * 10 + j}", $"val{j}");
        });
        results["set_100"] = await RunBenchmark("set_100", 2000, async i =>
        {
            for (int j = 0; j < 100; j++) await db.StringSetAsync($"bench:mset:{i * 100 + j}", $"val{j}");
        });
        results["set_1000"] = await RunBenchmark("set_1000", 500, async i =>
        {
            for (int j = 0; j < 1000; j++) await db.StringSetAsync($"bench:mset:{i * 1000 + j}", $"val{j}");
        });

        // GC stats
        results["gc"] = new Dictionary<string, object>
        {
            ["gen0_collections"] = GC.CollectionCount(0),
            ["gen1_collections"] = GC.CollectionCount(1),
            ["gen2_collections"] = GC.CollectionCount(2),
            ["total_allocated_bytes"] = GC.GetTotalAllocatedBytes(),
            ["peak_working_set_bytes"] = Process.GetCurrentProcess().PeakWorkingSet64,
        };

        // Output JSON
        var jsonOptions = new JsonSerializerOptions { WriteIndented = true };
        Console.WriteLine(JsonSerializer.Serialize(results, jsonOptions));

        // Cleanup benchmark keys
        Console.Error.WriteLine("Cleaning up benchmark keys...");
        var cleanupTasks = Enumerable.Range(0, readKeyPool)
            .Select(i => db.KeyDeleteAsync($"bench:r:{i}"));
        await Task.WhenAll(cleanupTasks);

        Console.Error.WriteLine("Benchmarks complete.");
    }

    static async Task<Dictionary<string, object>> RunBenchmark(string name, int iterations, Func<int, Task> action)
    {
        int perThread = iterations / NumThreads;
        int actualIterations = perThread * NumThreads;
        int warmupPerThread = Math.Max(10, perThread / 10);
        int stride = warmupPerThread + perThread;

        Console.Error.WriteLine($"  Running {name} ({actualIterations} iterations, {NumThreads} threads)...");

        // Thread-local latency lists
        var threadLatencies = new List<double>[NumThreads];
        for (int t = 0; t < NumThreads; t++)
            threadLatencies[t] = new List<double>(perThread);

        // Warm-up (concurrent, per-thread at 10% of iterations)
        var warmupTasks = Enumerable.Range(0, NumThreads).Select(t => Task.Run(async () =>
        {
            int baseIdx = t * stride;
            for (int i = 0; i < warmupPerThread; i++)
                await action(baseIdx + i);
        }));
        await Task.WhenAll(warmupTasks);

        // Measured phase - wall-clock timed
        var wallClock = Stopwatch.StartNew();
        var measuredTasks = Enumerable.Range(0, NumThreads).Select(t => Task.Run(async () =>
        {
            var lats = threadLatencies[t];
            var sw = new Stopwatch();
            int baseIdx = t * stride + warmupPerThread;
            for (int i = 0; i < perThread; i++)
            {
                sw.Restart();
                await action(baseIdx + i);
                sw.Stop();
                lats.Add(sw.Elapsed.TotalMicroseconds);
            }
        }));
        await Task.WhenAll(measuredTasks);
        wallClock.Stop();

        // Merge thread-local latencies
        var allLatencies = new List<double>(actualIterations);
        foreach (var lats in threadLatencies)
            allLatencies.AddRange(lats);

        allLatencies.Sort();

        // Throughput from wall-clock time (matching Haskell methodology)
        double wallClockSeconds = wallClock.Elapsed.TotalSeconds;
        double opsPerSec = actualIterations / wallClockSeconds;

        return new Dictionary<string, object>
        {
            ["p50_us"] = Math.Round(Percentile(allLatencies, 50), 1),
            ["p95_us"] = Math.Round(Percentile(allLatencies, 95), 1),
            ["p99_us"] = Math.Round(Percentile(allLatencies, 99), 1),
            ["ops_per_sec"] = Math.Round(opsPerSec),
            ["iterations"] = actualIterations,
        };
    }

    static double Percentile(List<double> sorted, double p)
    {
        int idx = Math.Clamp((int)(p / 100.0 * sorted.Count), 0, sorted.Count - 1);
        return sorted[idx];
    }
}
