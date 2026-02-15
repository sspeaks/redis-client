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
        string connString = args.Length > 0 ? args[0] : "localhost:6379";
        Console.Error.WriteLine($"Connecting to {connString}");

        var options = ConfigurationOptions.Parse(connString);
        options.AbortOnConnectFail = false;
        options.ConnectTimeout = 5000;

        using var connection = ConnectionMultiplexer.Connect(options);
        var db = connection.GetDatabase();

        Console.Error.WriteLine("Starting benchmarks...");

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

        // MGET benchmarks
        for (int i = 1; i <= 1000; i++)
            db.StringSet($"bench:mget:{i}", $"val{i}");

        RedisKey[] MgetKeys(int n) => Enumerable.Range(1, n).Select(i => (RedisKey)$"bench:mget:{i}").ToArray();

        results["mget_10"] = RunBenchmark("mget_10", 5000, () => db.StringGet(MgetKeys(10)));
        results["mget_100"] = RunBenchmark("mget_100", 2000, () => db.StringGet(MgetKeys(100)));
        results["mget_1000"] = RunBenchmark("mget_1000", 500, () => db.StringGet(MgetKeys(1000)));

        // MSET benchmarks
        KeyValuePair<RedisKey, RedisValue>[] MsetPairs(int n) =>
            Enumerable.Range(1, n).Select(i => new KeyValuePair<RedisKey, RedisValue>($"bench:mset:{i}", $"val{i}")).ToArray();

        results["mset_10"] = RunBenchmark("mset_10", 5000, () => db.StringSet(MsetPairs(10)));
        results["mset_100"] = RunBenchmark("mset_100", 2000, () => db.StringSet(MsetPairs(100)));
        results["mset_1000"] = RunBenchmark("mset_1000", 500, () => db.StringSet(MsetPairs(1000)));

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
