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
- `-a`, `--password PASSWORD` - Password
- `-t`, `--tls` - Use TLS connection
- `-c`, `--cluster` - Redis Cluster mode
- `-d`, `--data GBs` - Amount of random data to fill (in GB)
- `-f`, `--flush` - Flush database before filling (deletes all data; use only in testing)
- `-s`, `--serial` - Serial mode (no concurrency)
- `-n`, `--connections NUM` - Parallel connections (default: 2)
- `--tunnel-mode MODE` - Tunnel mode: 'smart' or 'pinned' (default: 'smart')

### Environment Variables

- `REDIS_CLIENT_FILL_CHUNK_KB` - Size of each command batch sent to Redis in kilobytes (default: 8192 KB, range: 1024-8192 KB). Larger values reduce network round-trips but use more memory. Use smaller values (1024-2048 KB) in memory-constrained environments or larger values (4096-8192 KB) for maximum throughput.

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

See [AZURE_EXAMPLES.md](AZURE_EXAMPLES.md) for detailed examples.

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
cabal test RespSpec ClusterSpec ClusterCommandSpec
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
- `lib/cluster/` - Cluster support and connection pooling
- `lib/crc16/` - CRC16 for hash slot calculation
- `test/` - Unit and E2E tests

## License

MIT License
