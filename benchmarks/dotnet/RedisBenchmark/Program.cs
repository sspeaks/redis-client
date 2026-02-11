using System.Diagnostics;
using System.Text.Json;
using StackExchange.Redis;

// Parse command-line arguments
string host = "localhost";
int port = 6379;
string? password = null;
bool tls = false;
string operation = "set";
int durationSec = 30;
int keySize = 16;
int valueSize = 256;
int connectionCount = 1;

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--host": host = args[++i]; break;
        case "--port": port = int.Parse(args[++i]); break;
        case "--password": password = args[++i]; break;
        case "--tls": tls = true; break;
        case "--operation": operation = args[++i]; break;
        case "--duration": durationSec = int.Parse(args[++i]); break;
        case "--key-size": keySize = int.Parse(args[++i]); break;
        case "--value-size": valueSize = int.Parse(args[++i]); break;
        case "--connections": connectionCount = int.Parse(args[++i]); break;
    }
}

await RunBenchmark(host, port, password, tls, operation, durationSec, keySize, valueSize, connectionCount);
return 0;

static async Task RunBenchmark(string host, int port, string? password, bool tls,
    string operation, int durationSec, int keySize, int valueSize, int connectionCount)
{
    Console.Error.WriteLine($"Connecting to {host}:{port} (tls={tls}, connections={connectionCount})...");

    var configStr = $"{host}:{port},abortConnect=false,connectTimeout=10000,syncTimeout=10000,asyncTimeout=10000";
    if (password != null) configStr += $",password={password}";
    if (tls) configStr += ",ssl=true";

    var config = ConfigurationOptions.Parse(configStr);

    // Create multiple multiplexers for parallelism
    var muxes = new ConnectionMultiplexer[connectionCount];
    for (int i = 0; i < connectionCount; i++)
    {
        muxes[i] = await ConnectionMultiplexer.ConnectAsync(config);
    }

    Console.Error.WriteLine($"Connected. Running '{operation}' workload for {durationSec}s...");

    // Pre-generate random key/value templates
    var rng = new Random(42);

    // For GET workload, pre-populate keys
    if (operation == "get" || operation == "mixed")
    {
        Console.Error.WriteLine("Pre-populating keys for GET workload...");
        var db = muxes[0].GetDatabase();
        var populateTasks = new List<Task>();
        for (int i = 0; i < 10000; i++)
        {
            var key = GenerateKey(keySize, i);
            var val = GenerateValue(valueSize, rng);
            populateTasks.Add(db.StringSetAsync(key, val, flags: CommandFlags.FireAndForget));
        }
        // FireAndForget doesn't return meaningful tasks, but flush the connection
        await Task.Delay(2000);
        Console.Error.WriteLine("Pre-population done.");
    }

    long totalOps = 0;
    var sw = Stopwatch.StartNew();
    var cts = new CancellationTokenSource(TimeSpan.FromSeconds(durationSec));

    // Launch concurrent submitter tasks (one per connection)
    int concurrency = connectionCount * 4; // 4 async loops per mux
    var tasks = new Task<long>[concurrency];

    for (int t = 0; t < concurrency; t++)
    {
        int taskId = t;
        var mux = muxes[t % connectionCount];
        tasks[t] = Task.Run(async () =>
        {
            var db = mux.GetDatabase();
            var localRng = new Random(taskId + 1);
            long ops = 0;
            int keyCounter = taskId * 1_000_000;

            while (!cts.IsCancellationRequested)
            {
                try
                {
                    switch (operation)
                    {
                        case "set":
                            {
                                var key = GenerateKey(keySize, keyCounter++);
                                var val = GenerateValue(valueSize, localRng);
                                await db.StringSetAsync(key, val);
                                ops++;
                                break;
                            }
                        case "get":
                            {
                                int idx = localRng.Next(10000);
                                var key = GenerateKey(keySize, idx);
                                await db.StringGetAsync(key);
                                ops++;
                                break;
                            }
                        case "mixed":
                            {
                                if (localRng.Next(100) < 80)
                                {
                                    // 80% GET
                                    int idx = localRng.Next(10000);
                                    var key = GenerateKey(keySize, idx);
                                    await db.StringGetAsync(key);
                                }
                                else
                                {
                                    // 20% SET
                                    var key = GenerateKey(keySize, keyCounter++);
                                    var val = GenerateValue(valueSize, localRng);
                                    await db.StringSetAsync(key, val);
                                }
                                ops++;
                                break;
                            }
                    }
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"Error: {ex.Message}");
                }
            }

            return ops;
        });
    }

    var results = await Task.WhenAll(tasks);
    sw.Stop();

    totalOps = results.Sum();
    double elapsed = sw.Elapsed.TotalSeconds;
    double opsPerSec = totalOps / elapsed;

    // Output JSON result
    var result = new
    {
        operation,
        ops_per_sec = Math.Round(opsPerSec, 2),
        duration_sec = Math.Round(elapsed, 2),
        total_ops = totalOps
    };

    Console.WriteLine(JsonSerializer.Serialize(result));

    // Cleanup
    foreach (var mux in muxes)
    {
        mux.Dispose();
    }
}

static string GenerateKey(int keySize, int counter)
{
    var prefix = $"bench:{counter}:";
    if (prefix.Length >= keySize)
        return prefix[..keySize];
    // Pad with 'x' to reach desired key size
    return prefix + new string('x', keySize - prefix.Length);
}

static byte[] GenerateValue(int valueSize, Random rng)
{
    var buf = new byte[valueSize];
    rng.NextBytes(buf);
    return buf;
}
