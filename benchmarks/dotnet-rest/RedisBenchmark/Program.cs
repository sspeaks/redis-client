using System.Text.Json;
using Microsoft.Data.Sqlite;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);

var redisHost = Environment.GetEnvironmentVariable("REDIS_HOST") ?? "localhost";
var redisPort = Environment.GetEnvironmentVariable("REDIS_PORT") ?? "6379";
var redisCluster = Environment.GetEnvironmentVariable("REDIS_CLUSTER")?.ToLower() == "true";
var sqliteDb = Environment.GetEnvironmentVariable("SQLITE_DB") ?? "benchmarks/shared/bench.db";
var port = Environment.GetEnvironmentVariable("PORT") ?? "5000";

builder.WebHost.UseUrls($"http://0.0.0.0:{port}");

var app = builder.Build();

// Redis connection
var redisConfig = ConfigurationOptions.Parse($"{redisHost}:{redisPort}");
redisConfig.AbortOnConnectFail = false;
var redis = ConnectionMultiplexer.Connect(redisConfig);
var cache = redis.GetDatabase();

// SQLite connection string
var sqliteConnStr = $"Data Source={sqliteDb};Mode=ReadWriteCreate;Cache=Shared";

// Initialize SQLite WAL mode (persists per-database-file)
{
    using var initConn = new SqliteConnection(sqliteConnStr);
    initConn.Open();
    using var walCmd = initConn.CreateCommand();
    walCmd.CommandText = "PRAGMA journal_mode=WAL;";
    walCmd.ExecuteNonQuery();
}

// Helper: open SQLite connection with busy_timeout set
async Task<SqliteConnection> OpenSqliteAsync()
{
    var conn = new SqliteConnection(sqliteConnStr);
    await conn.OpenAsync();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "PRAGMA busy_timeout=5000;";
    cmd.ExecuteNonQuery();
    return conn;
}

var jsonOpts = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

// GET /users/:id - cache-aside
app.MapGet("/users/{id:int}", async (int id) =>
{
    var cacheKey = $"user:{id}";

    // Check cache first
    var cached = await cache.StringGetAsync(cacheKey);
    if (cached.HasValue)
    {
        return Results.Content(cached.ToString(), "application/json");
    }

    // Fall back to SQLite
    using var conn = await OpenSqliteAsync();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT id, name, email, bio, created_at FROM users WHERE id = @id";
    cmd.Parameters.AddWithValue("@id", id);

    using var reader = await cmd.ExecuteReaderAsync();
    if (!await reader.ReadAsync())
    {
        return Results.NotFound(new { error = "User not found" });
    }

    var user = new
    {
        id = reader.GetInt32(0),
        name = reader.GetString(1),
        email = reader.GetString(2),
        bio = reader.IsDBNull(3) ? null : reader.GetString(3),
        createdAt = reader.GetString(4)
    };

    var json = JsonSerializer.Serialize(user, jsonOpts);

    // Populate cache with TTL 60s
    await cache.StringSetAsync(cacheKey, json, TimeSpan.FromSeconds(60));

    return Results.Content(json, "application/json");
});

// GET /users?page=&limit= - paginated list (not cached)
app.MapGet("/users", async (int? page, int? limit) =>
{
    var p = page ?? 1;
    var l = Math.Min(limit ?? 20, 100);
    var offset = (p - 1) * l;

    using var conn = await OpenSqliteAsync();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT id, name, email, bio, created_at FROM users ORDER BY id LIMIT @limit OFFSET @offset";
    cmd.Parameters.AddWithValue("@limit", l);
    cmd.Parameters.AddWithValue("@offset", offset);

    var users = new List<object>();
    using var reader = await cmd.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
        users.Add(new
        {
            id = reader.GetInt32(0),
            name = reader.GetString(1),
            email = reader.GetString(2),
            bio = reader.IsDBNull(3) ? null : reader.GetString(3),
            createdAt = reader.GetString(4)
        });
    }

    return Results.Json(new { page = p, limit = l, data = users }, jsonOpts);
});

// POST /users
app.MapPost("/users", async (HttpContext ctx) =>
{
    var body = await JsonSerializer.DeserializeAsync<JsonElement>(ctx.Request.Body);
    var name = body.GetProperty("name").GetString()!;
    var email = body.GetProperty("email").GetString()!;
    var bio = body.TryGetProperty("bio", out var bioProp) ? bioProp.GetString() : null;

    using var conn = await OpenSqliteAsync();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "INSERT INTO users (name, email, bio) VALUES (@name, @email, @bio) RETURNING id, name, email, bio, created_at";
    cmd.Parameters.AddWithValue("@name", name);
    cmd.Parameters.AddWithValue("@email", email);
    cmd.Parameters.AddWithValue("@bio", (object?)bio ?? DBNull.Value);

    using var reader = await cmd.ExecuteReaderAsync();
    await reader.ReadAsync();

    var user = new
    {
        id = reader.GetInt32(0),
        name = reader.GetString(1),
        email = reader.GetString(2),
        bio = reader.IsDBNull(3) ? null : reader.GetString(3),
        createdAt = reader.GetString(4)
    };

    // Invalidate cache for this user
    await cache.KeyDeleteAsync($"user:{user.id}");

    return Results.Created($"/users/{user.id}", user);
});

// PUT /users/:id
app.MapPut("/users/{id:int}", async (int id, HttpContext ctx) =>
{
    var body = await JsonSerializer.DeserializeAsync<JsonElement>(ctx.Request.Body);
    var name = body.GetProperty("name").GetString()!;
    var email = body.GetProperty("email").GetString()!;
    var bio = body.TryGetProperty("bio", out var bioProp) ? bioProp.GetString() : null;

    using var conn = await OpenSqliteAsync();

    // Check exists
    using var checkCmd = conn.CreateCommand();
    checkCmd.CommandText = "SELECT COUNT(*) FROM users WHERE id = @id";
    checkCmd.Parameters.AddWithValue("@id", id);
    var exists = (long)(await checkCmd.ExecuteScalarAsync())! > 0;
    if (!exists)
    {
        return Results.NotFound(new { error = "User not found" });
    }

    using var cmd = conn.CreateCommand();
    cmd.CommandText = "UPDATE users SET name = @name, email = @email, bio = @bio WHERE id = @id RETURNING id, name, email, bio, created_at";
    cmd.Parameters.AddWithValue("@id", id);
    cmd.Parameters.AddWithValue("@name", name);
    cmd.Parameters.AddWithValue("@email", email);
    cmd.Parameters.AddWithValue("@bio", (object?)bio ?? DBNull.Value);

    using var reader = await cmd.ExecuteReaderAsync();
    await reader.ReadAsync();

    var user = new
    {
        id = reader.GetInt32(0),
        name = reader.GetString(1),
        email = reader.GetString(2),
        bio = reader.IsDBNull(3) ? null : reader.GetString(3),
        createdAt = reader.GetString(4)
    };

    // Invalidate cache
    await cache.KeyDeleteAsync($"user:{id}");

    return Results.Ok(user);
});

// DELETE /users/:id
app.MapDelete("/users/{id:int}", async (int id) =>
{
    using var conn = await OpenSqliteAsync();

    using var cmd = conn.CreateCommand();
    cmd.CommandText = "DELETE FROM users WHERE id = @id";
    cmd.Parameters.AddWithValue("@id", id);
    var rows = await cmd.ExecuteNonQueryAsync();

    if (rows == 0)
    {
        return Results.NotFound(new { error = "User not found" });
    }

    // Remove from cache
    await cache.KeyDeleteAsync($"user:{id}");

    return Results.Ok(new { message = "User deleted" });
});

app.Run();
