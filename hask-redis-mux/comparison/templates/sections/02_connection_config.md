# 2. Connection & Configuration

## Standalone Connection

### Haskell (hask-redis-mux)

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Database.Redis

-- Default: localhost:6379, plaintext, 1 multiplexer
main :: IO ()
main = do
  result <- runRedis defaultStandaloneConfig $ do
    set "key" "value"
    (val :: ByteString) <- get "key"
    return val
  print result
```

#### Custom Configuration

```haskell
import Database.Redis

main :: IO ()
main = do
  let config = StandaloneConfig
        { standaloneNodeAddress     = NodeAddress "redis.example.com" 6380
        , standaloneConnector       = clusterPlaintextConnector
        , standaloneMultiplexerCount = 4  -- 4 multiplexed connections
        }
  withStandaloneClient config $ \client ->
    runStandaloneClient client $ do
      set "key" "value"
```

### C# (StackExchange.Redis)

```csharp
using StackExchange.Redis;

// Default: localhost:6379
var connection = ConnectionMultiplexer.Connect("localhost");
IDatabase db = connection.GetDatabase();

await db.StringSetAsync("key", "value");
RedisValue val = await db.StringGetAsync("key");
Console.WriteLine(val); // "value"
```

#### Custom Configuration

```csharp
var options = new ConfigurationOptions
{
    EndPoints = { { "redis.example.com", 6380 } },
    Password = "secret",
    AbortOnConnectFail = false,
    ConnectTimeout = 5000,
    SyncTimeout = 3000,
    AsyncTimeout = 5000,
    ReconnectRetryPolicy = new ExponentialRetry(5000),
};
var connection = ConnectionMultiplexer.Connect(options);
```

## Cluster Connection

### Haskell (hask-redis-mux)

```haskell
import Database.Redis

main :: IO ()
main = do
  let clusterCfg = ClusterConfig
        { clusterSeedNode                = NodeAddress "cluster-node-1" 7000
        , clusterPoolConfig              = PoolConfig
            { maxConnectionsPerNode = 10
            , connectionTimeout     = 5
            , maxRetries            = 3
            , useTLS                = False
            }
        , clusterMaxRetries              = 3
        , clusterRetryDelay              = 100000   -- 100ms
        , clusterTopologyRefreshInterval = 600      -- 10 minutes
        }
  withClusterClient clusterCfg clusterPlaintextConnector $ \client ->
    runClusterCommandClient client $ do
      set "key" "value"
      (val :: ByteString) <- get "key"
      return val
```

### C# (StackExchange.Redis)

```csharp
var options = new ConfigurationOptions
{
    EndPoints = { "cluster-node-1:7000", "cluster-node-2:7001", "cluster-node-3:7002" },
    CommandMap = CommandMap.Create(new HashSet<string> { "CLUSTER" }),
};
var connection = ConnectionMultiplexer.Connect(options);
IDatabase db = connection.GetDatabase();
```

## TLS Configuration

### Haskell (hask-redis-mux)

```haskell
import Database.Redis

main :: IO ()
main = do
  let config = StandaloneConfig
        { standaloneNodeAddress     = NodeAddress "redis.example.com" 6380
        , standaloneConnector       = clusterTLSConnector "redis.example.com"
        , standaloneMultiplexerCount = 1
        }
  withStandaloneClient config $ \client ->
    runStandaloneClient client $ do
      set "key" "value"
```

> **Note:** hask-redis-mux uses the `crypton` library for TLS. The `clusterTLSConnector` takes a hostname string for certificate validation. For cluster mode, set `useTLS = True` in `PoolConfig`.

### C# (StackExchange.Redis)

```csharp
var options = new ConfigurationOptions
{
    EndPoints = { { "redis.example.com", 6380 } },
    Ssl = true,
    SslHost = "redis.example.com",
    // Optionally provide a certificate validation callback:
    // CertificateValidation += (sender, cert, chain, errors) => true;
};
var connection = ConnectionMultiplexer.Connect(options);
```

## Connection Pooling

| Aspect | hask-redis-mux | StackExchange.Redis |
|---|---|---|
| **Standalone** | `standaloneMultiplexerCount` controls parallel multiplexed connections (default: 1) | Single multiplexed connection (handles thousands of concurrent operations) |
| **Cluster** | Per-node pool via `PoolConfig.maxConnectionsPerNode`; thread-safe with exclusive checkout; callers block at capacity | Per-node multiplexed connection; no explicit pool — multiplexer handles concurrency |
| **Pool Overflow** | Callers block until a connection is returned | N/A — single connection per endpoint |
| **Failed Connections** | Discarded; fresh connection created on next checkout | Automatic reconnection with configurable retry policy |

## Reconnection Behavior

| Aspect | hask-redis-mux | StackExchange.Redis |
|---|---|---|
| **Standalone** | No automatic reconnection at multiplexer level; `MultiplexerException` raised on failure | Automatic reconnection with `ReconnectRetryPolicy` (linear or exponential backoff) |
| **Cluster** | Cluster client detects MOVED/ASK errors and checks out fresh connections from pool; topology auto-refreshes on interval | Automatic reconnection per-node; `ClusterConfiguration` re-discovered on topology change |
| **Error Propagation** | `MultiplexerException` variants: `Dead`, `ParseError`, `ConnectionClosed` | `RedisConnectionException`, `RedisTimeoutException`; events via `ConnectionMultiplexer.ConnectionFailed` |
| **Health Checks** | No built-in heartbeat | Configurable `KeepAlive` interval (default: 60s) |

> **Comparison Note:** StackExchange.Redis provides more built-in resilience with automatic reconnection and event hooks. hask-redis-mux relies on the bracket pattern for safe cleanup and expects the application to handle reconnection logic for standalone connections, while cluster mode benefits from connection pool rotation.
