using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using StackExchange.Redis;

class Program
{
    static void Main(string[] args)
    {
        string connString = args.Length > 0 ? args[0] : "localhost:7000,localhost:7001,localhost:7002,localhost:7003,localhost:7004";
        Console.Error.WriteLine($"Connecting to cluster: {connString}");

        var options = ConfigurationOptions.Parse(connString);
        options.AbortOnConnectFail = false;
        options.ConnectTimeout = 5000;

        using var connection = ConnectionMultiplexer.Connect(options);
        var db = connection.GetDatabase();

        Console.Error.WriteLine("Starting cluster benchmarks...");

        var results = new Dictionary<string, object>();

        // PING
        results["ping"] = RunBenchmark("ping", 10000, () => db.Ping());

        // SET
        results["set"] = RunBenchmark("set", 10000, () => db.StringSet("bench:key", "bench:value"));

        // GET
        db.StringSet("bench:key", "bench:value");
        results["get"] = RunBenchmark("get", 10000, () => db.StringGet("bench:key"));

        // DEL
        results["del"] = RunBenchmark("del", 10000, () =>
        {
            db.StringSet("bench:delkey", "v");
            db.KeyDelete("bench:delkey");
        });

        // Pipeline (batch) benchmark
        for (int i = 1; i <= 100; i++)
            db.StringSet($"bench:pipe:{i}", $"val{i}");

        results["pipeline_100_gets"] = RunBenchmark("pipeline_100_gets", 1000, () =>
        {
            var batch = db.CreateBatch();
            var tasks = new List<System.Threading.Tasks.Task<RedisValue>>();
            for (int i = 1; i <= 100; i++)
                tasks.Add(batch.StringGetAsync($"bench:pipe:{i}"));
            batch.Execute();
            System.Threading.Tasks.Task.WaitAll(tasks.ToArray());
        });

        // MGET replacement: sequential GETs (cluster-safe, no cross-slot)
        for (int i = 1; i <= 1000; i++)
            db.StringSet($"bench:mget:{i}", $"val{i}");

        results["get_10"] = RunBenchmark("get_10", 5000, () =>
        {
            for (int i = 1; i <= 10; i++) db.StringGet($"bench:mget:{i}");
        });
        results["get_100"] = RunBenchmark("get_100", 2000, () =>
        {
            for (int i = 1; i <= 100; i++) db.StringGet($"bench:mget:{i}");
        });
        results["get_1000"] = RunBenchmark("get_1000", 500, () =>
        {
            for (int i = 1; i <= 1000; i++) db.StringGet($"bench:mget:{i}");
        });

        // MSET replacement: sequential SETs (cluster-safe)
        results["set_10"] = RunBenchmark("set_10", 5000, () =>
        {
            for (int i = 1; i <= 10; i++) db.StringSet($"bench:mset:{i}", $"val{i}");
        });
        results["set_100"] = RunBenchmark("set_100", 2000, () =>
        {
            for (int i = 1; i <= 100; i++) db.StringSet($"bench:mset:{i}", $"val{i}");
        });
        results["set_1000"] = RunBenchmark("set_1000", 500, () =>
        {
            for (int i = 1; i <= 1000; i++) db.StringSet($"bench:mset:{i}", $"val{i}");
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

        // Cleanup
        db.KeyDelete("bench:key");
        db.KeyDelete("bench:delkey");
        for (int i = 1; i <= 100; i++) db.KeyDelete($"bench:pipe:{i}");
        for (int i = 1; i <= 1000; i++) db.KeyDelete($"bench:mget:{i}");
        for (int i = 1; i <= 1000; i++) db.KeyDelete($"bench:mset:{i}");

        Console.Error.WriteLine("Benchmarks complete.");
    }

    static Dictionary<string, object> RunBenchmark(string name, int iterations, Action action)
    {
        Console.Error.WriteLine($"  Running {name} ({iterations} iterations)...");

        // Warm-up
        int warmup = Math.Max(10, iterations / 10);
        for (int i = 0; i < warmup; i++) action();

        var latencies = new List<double>(iterations);
        var sw = new Stopwatch();

        for (int i = 0; i < iterations; i++)
        {
            sw.Restart();
            action();
            sw.Stop();
            latencies.Add(sw.Elapsed.TotalMicroseconds);
        }

        latencies.Sort();
        double totalUs = latencies.Sum();
        double opsPerSec = iterations / (totalUs / 1_000_000.0);

        return new Dictionary<string, object>
        {
            ["p50_us"] = Math.Round(Percentile(latencies, 50), 1),
            ["p95_us"] = Math.Round(Percentile(latencies, 95), 1),
            ["p99_us"] = Math.Round(Percentile(latencies, 99), 1),
            ["ops_per_sec"] = Math.Round(opsPerSec),
            ["iterations"] = iterations,
        };
    }

    static double Percentile(List<double> sorted, double p)
    {
        int idx = Math.Clamp((int)(p / 100.0 * sorted.Count), 0, sorted.Count - 1);
        return sorted[idx];
    }
}
