# 4. REST Cache-Aside Pattern

This section demonstrates a real-world cache-aside pattern implemented as a REST API in both ecosystems.

## Haskell: Scotty + hask-redis-mux

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Web.Scotty
import Database.Redis
import Data.ByteString.Lazy (fromStrict)
import Data.ByteString.Char8 (pack)
import qualified Data.Text.Lazy as TL

-- Mock data source (simulates a database lookup)
fetchFromDatabase :: String -> IO (Maybe ByteString)
fetchFromDatabase itemId = do
  putStrLn $ "DB lookup for: " <> itemId
  if itemId == "42"
    then return (Just "{\"id\":42,\"name\":\"Widget\"}")
    else return Nothing

main :: IO ()
main = withStandaloneClient defaultStandaloneConfig $ \redisClient -> do
  scotty 3000 $ do
    get "/item/:id" $ do
      itemId <- captureParam "id"
      let cacheKey = "item:" <> pack itemId

      -- Step 1: Check cache
      cached <- liftIO $ runStandaloneClient redisClient $ do
        (val :: Maybe ByteString) <- get cacheKey
        return val

      case cached of
        Just hit -> do
          -- Cache hit: return cached value
          setHeader "X-Cache" "HIT"
          raw (fromStrict hit)

        Nothing -> do
          -- Step 2: Cache miss — fetch from source
          result <- liftIO $ fetchFromDatabase itemId
          case result of
            Nothing -> do
              status status404
              text "Not found"
            Just item -> do
              -- Step 3: Populate cache with 60s TTL
              liftIO $ runStandaloneClient redisClient $ do
                set cacheKey item
                (ok :: Bool) <- expire cacheKey 60
                return ok
              setHeader "X-Cache" "MISS"
              raw (fromStrict item)
```

## C# : ASP.NET Core Minimal API + StackExchange.Redis

```csharp
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);

// Register Redis as singleton via DI
builder.Services.AddSingleton<IConnectionMultiplexer>(
    ConnectionMultiplexer.Connect("localhost:6379"));

var app = builder.Build();

// Mock data source
static string? FetchFromDatabase(string itemId)
{
    Console.WriteLine($"DB lookup for: {itemId}");
    return itemId == "42"
        ? """{"id":42,"name":"Widget"}"""
        : null;
}

app.MapGet("/item/{id}", async (string id, IConnectionMultiplexer redis) =>
{
    IDatabase db = redis.GetDatabase();
    string cacheKey = $"item:{id}";

    // Step 1: Check cache
    RedisValue cached = await db.StringGetAsync(cacheKey);
    if (cached.HasValue)
    {
        // Cache hit
        return Results.Content(cached.ToString(), "application/json",
            statusCode: 200);
    }

    // Step 2: Cache miss — fetch from source
    string? item = FetchFromDatabase(id);
    if (item is null)
    {
        return Results.NotFound("Not found");
    }

    // Step 3: Populate cache with 60s TTL
    await db.StringSetAsync(cacheKey, item, TimeSpan.FromSeconds(60));

    return Results.Content(item, "application/json", statusCode: 200);
});

app.Run();
```

## Comparison Notes

| Aspect | Haskell (Scotty + hask-redis-mux) | C# (ASP.NET Core + StackExchange.Redis) |
|---|---|---|
| **Boilerplate** | ~40 lines; explicit bracket resource management | ~35 lines; DI handles connection lifetime |
| **DI Pattern** | Manual — pass `redisClient` via closure | Built-in DI container with `AddSingleton` |
| **Async Model** | IO monad; `liftIO` bridges Scotty/Redis monads | Native async/await; seamless composition |
| **Error Handling** | Pattern matching on `Maybe`; exceptions propagate via IO | Null checks; exceptions caught by middleware |
| **Type Safety** | Compile-time typed cache values via `FromResp` | Runtime `RedisValue` casts |
| **TTL Setting** | Separate `expire` call (or use `psetex`) | Inline `TimeSpan` parameter in `StringSetAsync` |
| **Cache Header** | Manual `setHeader "X-Cache"` | Manual via `Results.Content` (or middleware) |

> **Key Takeaway:** Both implementations follow the same cache-aside pattern with similar structure. The Haskell version benefits from compile-time type safety but requires explicit monad management. The C# version benefits from built-in DI and inline TTL support.
