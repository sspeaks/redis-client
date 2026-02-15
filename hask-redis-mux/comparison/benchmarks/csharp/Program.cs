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

    static void Main(string[] args)
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
        results["ping"] = RunBenchmark("ping", 10000, i => db.Ping());

        // SET with distributed unique keys (matching Haskell's mkKey pattern)
        results["set"] = RunBenchmark("set", 10000, i => db.StringSet($"bench:set:{i}", "bench:value"));

        // Pre-populate read key pool (matching Haskell's readKeyPool)
        int readKeyPool = 10000;
        Console.Error.WriteLine("  Pre-populating read key pool...");
        Parallel.For(0, readKeyPool, new ParallelOptions { MaxDegreeOfParallelism = NumThreads },
            i => db.StringSet($"bench:r:{i}", $"val{i}"));

        // GET with distributed keys from pool
        results["get"] = RunBenchmark("get", 10000, i =>
            db.StringGet($"bench:r:{i % readKeyPool}"));

        // DEL with unique keys per iteration
        results["del"] = RunBenchmark("del", 10000, i =>
        {
            var key = $"bench:del:{i}";
            db.StringSet(key, "v");
            db.KeyDelete(key);
        });

        // Pipeline (batch) benchmark - keys from pool
        results["pipeline_100_gets"] = RunBenchmark("pipeline_100_gets", 1000, i =>
        {
            var batch = db.CreateBatch();
            var tasks = new List<Task<RedisValue>>();
            for (int j = 0; j < 100; j++)
                tasks.Add(batch.StringGetAsync($"bench:r:{(i * 100 + j) % readKeyPool}"));
            batch.Execute();
            Task.WaitAll(tasks.ToArray());
        });

        // GET batch benchmarks (keys from pool distribute across all slots)
        results["get_10"] = RunBenchmark("get_10", 5000, i =>
        {
            for (int j = 0; j < 10; j++) db.StringGet($"bench:r:{(i * 10 + j) % readKeyPool}");
        });
        results["get_100"] = RunBenchmark("get_100", 2000, i =>
        {
            for (int j = 0; j < 100; j++) db.StringGet($"bench:r:{(i * 100 + j) % readKeyPool}");
        });
        results["get_1000"] = RunBenchmark("get_1000", 500, i =>
        {
            for (int j = 0; j < 1000; j++) db.StringGet($"bench:r:{(i * 1000 + j) % readKeyPool}");
        });

        // SET batch benchmarks with distributed keys
        results["set_10"] = RunBenchmark("set_10", 5000, i =>
        {
            for (int j = 0; j < 10; j++) db.StringSet($"bench:mset:{i * 10 + j}", $"val{j}");
        });
        results["set_100"] = RunBenchmark("set_100", 2000, i =>
        {
            for (int j = 0; j < 100; j++) db.StringSet($"bench:mset:{i * 100 + j}", $"val{j}");
        });
        results["set_1000"] = RunBenchmark("set_1000", 500, i =>
        {
            for (int j = 0; j < 1000; j++) db.StringSet($"bench:mset:{i * 1000 + j}", $"val{j}");
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
        Parallel.For(0, readKeyPool, new ParallelOptions { MaxDegreeOfParallelism = NumThreads },
            i => db.KeyDelete($"bench:r:{i}"));

        Console.Error.WriteLine("Benchmarks complete.");
    }

    static Dictionary<string, object> RunBenchmark(string name, int iterations, Action<int> action)
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
        Parallel.For(0, NumThreads, new ParallelOptions { MaxDegreeOfParallelism = NumThreads }, t =>
        {
            int baseIdx = t * stride;
            for (int i = 0; i < warmupPerThread; i++)
                action(baseIdx + i);
        });

        // Measured phase - wall-clock timed
        var wallClock = Stopwatch.StartNew();
        Parallel.For(0, NumThreads, new ParallelOptions { MaxDegreeOfParallelism = NumThreads }, t =>
        {
            var lats = threadLatencies[t];
            var sw = new Stopwatch();
            int baseIdx = t * stride + warmupPerThread;
            for (int i = 0; i < perThread; i++)
            {
                sw.Restart();
                action(baseIdx + i);
                sw.Stop();
                lats.Add(sw.Elapsed.TotalMicroseconds);
            }
        });
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
