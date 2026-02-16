using System.Text.Json;
using StackExchange.Redis;

// Pre-size thread pool to avoid starvation under burst async load
// (.NET default is low and ramps up ~1 thread per 500ms)
ThreadPool.SetMinThreads(50, 50);

var port = 3001;
var redisConn = "localhost:7000,localhost:7001,localhost:7002";

for (int i = 0; i < args.Length; i++)
{
    if (args[i] == "--port" && i + 1 < args.Length)
        port = int.Parse(args[++i]);
    else if (args[i] == "--redis" && i + 1 < args.Length)
        redisConn = args[++i];
}

Console.Error.WriteLine($"Starting REST server on port {port}");
Console.Error.WriteLine($"Redis cluster: {redisConn}");

var options = ConfigurationOptions.Parse(redisConn);
options.AbortOnConnectFail = false;
options.ConnectTimeout = 5000;
options.AsyncTimeout = 3000;
options.SyncTimeout = 3000;

using var connection = ConnectionMultiplexer.Connect(options);
var db = connection.GetDatabase();

var builder = WebApplication.CreateBuilder();
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
var app = builder.Build();

app.MapGet("/health", () => "OK");

app.MapGet("/item/{id}", async (string id, HttpContext ctx) =>
{
    var cacheKey = $"cache:item:{id}";

    // Cache-aside: check Redis first
    var cached = await db.StringGetAsync(cacheKey);
    if (cached.HasValue)
    {
        ctx.Response.Headers["X-Cache"] = "HIT";
        return Results.Content(cached.ToString(), "application/json");
    }

    // Cache miss: get from mock data source
    if (!int.TryParse(id, out int numericId))
    {
        return Results.NotFound("Not found");
    }

    var jsonData = JsonSerializer.Serialize(new { id = numericId, name = $"Item {numericId}" });

    // Populate cache with 60s TTL
    await db.StringSetAsync(cacheKey, jsonData, TimeSpan.FromSeconds(60));

    ctx.Response.Headers["X-Cache"] = "MISS";
    return Results.Content(jsonData, "application/json");
});

app.Run();
