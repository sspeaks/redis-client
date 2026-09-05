# Redis Client

A Haskell Redis client with support for standalone and cluster modes, plaintext and TLS connections, and RESP protocol implementation.

## Quick Start

### Installation

**Using Nix (recommended):**
```sh
# Install from current directory
nix profile install .#

# Or install directly from GitHub
nix profile install github:sspeaks/redis-client
```

**Using Cabal:**
```sh
cabal build
cabal install
```

### Basic Usage

The client has three modes: `cli` (interactive), `fill` (testing), and `tunn` (TLS proxy).

**Interactive CLI:**
```sh
redis-client cli -h localhost
redis-client cli -h localhost -c          # Cluster mode
redis-client cli -h localhost -t          # With TLS
```

**Fill cache with data:**
```sh
redis-client fill -h localhost -d 5       # Fill 5GB
redis-client fill -h localhost -d 5 -c    # Fill 5GB in cluster
redis-client fill -h localhost -f         # Flush database
```

**TLS Tunnel:**
```sh
redis-client tunn -h localhost -t
redis-client tunn -h localhost -t -c --tunnel-mode smart  # Cluster mode
```

### Command Options

- `-h`, `--host HOST` - Host to connect to (required)
- `-p`, `--port PORT` - Port (default: 6379 for plaintext, 6380 for TLS)
- `-u`, `--username USERNAME` - Username (default: 'default')
- `-t`, `--tls` - Use TLS connection
- `--allow-insecure-plaintext-auth` - Explicitly allow credentials over plaintext. Emits a warning naming the target host.
- `-c`, `--cluster` - Redis Cluster mode
- `-d`, `--data GBs` - Amount of random data to fill (in GB)
- `-f`, `--flush` - Flush database before filling (deletes all data; use only in testing)
- `-s`, `--serial` - Serial mode (no concurrency)
- `-n`, `--connections NUM` - Parallel connections (default: 2)
- `--tunnel-mode MODE` - Tunnel mode: 'smart' or 'pinned' (default: 'smart')

### Environment Variables

- `REDIS_CLIENT_PASSWORD_FILE` - Path to a file containing the Redis password, access key, or Entra token. This has highest precedence. A single trailing newline is removed.
- `REDIS_CLIENT_PASSWORD` - Redis password, access key, or Entra token used only when `REDIS_CLIENT_PASSWORD_FILE` is not set.
- `REDIS_CLIENT_TLS_INSECURE` - Set to exactly `1` to disable TLS certificate verification. Unset, empty, `0`, and `false` keep verification enabled; every other value is rejected.
- `REDIS_CLIENT_FILL_CHUNK_KB` - Size of each command batch sent to Redis in kilobytes (default: 8192 KB, range: 1024-8192 KB). Larger values reduce network round-trips but use more memory. Use smaller values (1024-2048 KB) in memory-constrained environments or larger values (4096-8192 KB) for maximum throughput.

Credential command-line options are no longer accepted. This is a breaking security change that keeps live credentials out of process arguments and parallel fill child arguments. Prefer an owner-only credential file:

```sh
install -d -m 700 "$HOME/.config/redis-client"
umask 077
read -rsp "Redis credential: " REDIS_CREDENTIAL && printf '\n'
printf '%s' "$REDIS_CREDENTIAL" > "$HOME/.config/redis-client/password"
unset REDIS_CREDENTIAL
chmod 600 "$HOME/.config/redis-client/password"

REDIS_CLIENT_PASSWORD_FILE="$HOME/.config/redis-client/password" \
  redis-client cli -h localhost -t
```

Environment values are convenient for automation but may be visible to other same-user or privileged processes, depending on operating-system and platform policy. Avoid exporting credentials into shell startup files.

Credentialed connections require TLS by default. For a trusted local test server
that does not support TLS, the risk must be acknowledged explicitly:

```sh
REDIS_CLIENT_PASSWORD_FILE="$HOME/.config/redis-client/password" \
  redis-client cli -h 127.0.0.1 --allow-insecure-plaintext-auth
```

This override prints a prominent warning naming the target and stating that the
credential is being sent unencrypted. Do not use it across shared or untrusted
networks.

TLS certificate verification remains enabled unless
`REDIS_CLIENT_TLS_INSECURE=1` is set. This bypass is intended only for controlled
testing with a server whose certificate cannot be verified:

```sh
REDIS_CLIENT_TLS_INSECURE=1 redis-client cli -h test-cache.local -t
```

The client warns whenever verification is disabled. Values such as `true`,
`yes`, or misspellings fail rather than silently weakening TLS.

## Azure Redis Integration

Connect to Azure Redis caches with automatic Entra (Azure AD) authentication:

```sh
# Interactive mode
azure-redis-connect

# Specify subscription
azure-redis-connect --subscription <subscription-id>

# Specify resource group
azure-redis-connect --resource-group <rg-name>
```

**Prerequisites:** Azure CLI (`az login`), Python 3.6+, and Azure permissions for Redis access.

See [docs/AZURE_EXAMPLES.md](docs/AZURE_EXAMPLES.md) for detailed examples.

## Library Usage

### Standalone Multiplexed Client

The standalone multiplexed client gives you pipelined throughput for a single (non-cluster) Redis server. Multiplexing is enabled by default.

```haskell
import Redis

main :: IO ()
main = do
  let config = StandaloneConfig
        { standaloneNodeAddress     = NodeAddress "localhost" 6379
        , standaloneConnector       = clusterPlaintextConnector
        , standaloneMultiplexerCount = 1
        , standaloneUseMultiplexing = True   -- default
        }
  client <- createStandaloneClientFromConfig config
  runStandaloneClient client $ do
    set "mykey" "myvalue"
    result <- get "mykey"
    liftIO $ print result
  closeStandaloneClient client
```

Set `standaloneUseMultiplexing = False` to fall back to sequential (non-pipelined) command execution.

For TLS connections, use `clusterTLSConnector` instead of `clusterPlaintextConnector`.
Library callers that issue `AUTH` directly are responsible for choosing a TLS
connector; the CLI enforces the credentialed-plaintext policy because it owns
both the credential and transport configuration.

### Cluster Client

Cluster mode uses multiplexing by default for optimal throughput. Set `clusterUseMultiplexing = False` to opt out.

```haskell
import Redis

main :: IO ()
main = do
  let config = ClusterConfig
        { clusterNodeAddress      = NodeAddress "localhost" 7000
        , clusterConnector        = clusterPlaintextConnector
        , clusterUseMultiplexing  = True   -- default
        , clusterMultiplexerCount = 1
        }
  client <- createClusterClient config clusterPlaintextConnector
  runClusterCommandClient client $ do
    set "mykey" "myvalue"
    result <- get "mykey"
    liftIO $ print result
  closeClusterClient client
```

## Using as a Nix Overlay

You can add `redis-client` to your local nixpkgs Haskell package set via the exported overlay. This lets you use it as a library dependency in other Haskell packages built with nixpkgs.

**In a consumer flake:**
```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
    redis-client.url = "github:sspeaks/redis-client";
  };

  outputs = { nixpkgs, redis-client, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ redis-client.overlays.default ];
      };
    in {
      # haskellPackages.redis-client is now available
      defaultPackage.x86_64-linux =
        pkgs.haskellPackages.callCabal2nix "my-app" ./. { };
    };
}
```

Your `.cabal` file just needs `redis-client` in `build-depends` — the overlay makes it visible to `callCabal2nix` automatically.

**Without flakes (e.g. in `shell.nix` or `default.nix`):**
```nix
let
  redis-client-src = builtins.fetchGit {
    url = "https://github.com/sspeaks/redis-client.git";
    ref = "main";
  };
  redis-client-flake = builtins.getFlake (toString redis-client-src);
  pkgs = import <nixpkgs> {
    overlays = [ redis-client-flake.overlays.default ];
  };
in
  pkgs.haskellPackages.callCabal2nix "my-app" ./. { }
```

## Development

### Building

```sh
# Using Makefile (handles Nix if available)
make build

# Or directly with Cabal
cabal build

# Or with Nix
nix-build
```

### Running Tests

**Unit tests** (no Redis required):
```sh
make test-unit
# or
cabal test RespSpec ClusterSpec ClusterCommandSpec MultiplexerSpec MultiplexPoolSpec
```

**End-to-end tests** (requires Docker and Nix):
```sh
make test-e2e               # Standalone Redis E2E
make test-cluster-e2e       # Cluster E2E
make test                   # Run all tests
```

**Manual testing with local Redis:**

For interactive testing or running unit tests manually:
```sh
make redis-start            # Start standalone Redis
make redis-cluster-start    # Start Redis cluster

# Run unit tests or manual commands
cabal test RespSpec ClusterSpec ClusterCommandSpec
# or
cabal run redis-client -- fill -h localhost -d 1

make redis-stop             # Stop standalone Redis
make redis-cluster-stop     # Stop Redis cluster
```

Note: Do NOT start Redis manually before running E2E tests (`make test-e2e` or `make test-cluster-e2e`). Those tests manage their own Docker instances.

### Regenerating cluster routing grammar

Cluster smart-proxy routing is generated from immutable Redis 7.2.6 command
metadata vendored at:

`vendor/redis-7.2.6-commands/` (source SHA `ae6a2aa95cd094b032e7a69b8b59f64dd1ed085f`)

Update and audit commands:

```sh
# Regenerate hask-redis-mux/lib/.../Commands/Generated.hs deterministically
scripts/generate_cluster_routing.py

# Semantic drift check (fails on any routing-entry mutation)
scripts/audit_cluster_routing.sh
```

The generator is deterministic: same source metadata => identical generated file.

### Profiling

Profile before and after changes to detect regressions:

```sh
# Start local Redis (if needed)
make redis-start

# Profile with -p flag (easiest to compare)
cabal run --enable-profiling -- fill -h localhost -f -d 1 +RTS -p -RTS

# Make changes...

# Profile again
cabal run --enable-profiling -- fill -h localhost -f -d 1 +RTS -p -RTS

# Compare .prof files for regressions
# Stop Redis
make redis-stop

# Clean up profiling artifacts
rm -f *.hp *.prof *.ps *.aux *.stat
```

**Profiling tools:**
- `hp2ps -e18in -c redis-client.hp` - Convert heap profile to PostScript
- [Speedscope](https://www.speedscope.app/) - Interactive flamegraph viewer

## Project Structure

- `app/` - Main executable (cli, fill, tunnel modes)
- `lib/resp/` - RESP protocol implementation
- `lib/client/` - Connection management (plaintext and TLS)
- `lib/redis-command-client/` - Redis command execution
- `lib/cluster/` - Cluster support, connection pooling, multiplexer, and standalone client
- `lib/crc16/` - CRC16 for hash slot calculation
- `test/` - Unit and E2E tests

## License

MIT License
