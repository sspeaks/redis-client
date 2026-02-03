# Redis Client

A Haskell-based Redis client that supports both plain text and TLS connections.

## Features

- Connect to Redis using plain text or TLS
- Send and receive RESP data
- Perform basic Redis commands
- Profile the application for performance analysis
- Azure Redis Cache integration with Entra (Azure AD) authentication support

## Usage

### Azure Redis Cache Connection

For easy connection to Azure Redis caches with automatic Entra (Azure AD) authentication:

```sh
# If installed via Nix
azure-redis-connect

# Or run directly with Python
python3 azure-redis-connect.py

# Specify a subscription
azure-redis-connect --subscription <subscription-id>
# or
python3 azure-redis-connect.py --subscription <subscription-id>
```

With a specific resource group:

```sh
azure-redis-connect --resource-group <rg-name>
# or
python3 azure-redis-connect.py --resource-group <rg-name>
```

The script will:
1. Use your currently selected Azure subscription (or the one you specify)
2. List all eligible Redis caches in your subscription
3. Let you select a cache
4. Choose between fill mode, CLI mode, or tunnel mode
5. Automatically handle Entra authentication when needed

#### Prerequisites for Azure Integration

- Azure CLI installed and configured (`az login`)
- Python 3.6 or later
- Appropriate Azure permissions to list and access Redis caches

### Building the Project

#### Using Cabal

To build the project with Cabal, use the following command:

```sh
cabal build
```

#### Using Nix

To build the project with Nix, use the following command:

```sh
nix-build
```

To install both `redis-client` and `azure-redis-connect` to your profile:

```sh
# Install from the current directory
nix profile install .#

# Or install directly from GitHub
nix profile install github:sspeaks/redis-client
```

This will install both executables to your PATH, making them available system-wide.

### Running the Client

To run the client, use the following command:

```sh
cabal run redis-client -- [OPTIONS]
```

### Options

- `-h`, `--host HOST`: Host to connect to
- `-u`, `--username USERNAME`: Username to authenticate with (default: 'default')
- `-a`, `--password PASSWORD`: Password to authenticate with
- `-t`, `--tls`: Use TLS
- `-d`, `--data GBs`: Random data amount to send in GB
- `-f`, `--flush`: Flush the database
- `-s`, `--serial`: Run in serial mode (no concurrency)
- `-n`, `--connections NUM`: Number of parallel connections (default: 2)

### Performance Tuning Environment Variables

For optimal cache filling performance, you can tune this environment variable:

- `REDIS_CLIENT_FILL_CHUNK_KB`: Chunk size in KB (default: 8192)
  - Larger chunks reduce network round-trips but use more memory
  - Recommended range: 1024-8192 KB

### Examples

#### Connect to a Redis host and flush the database

```sh
cabal run redis-client -- fill -h localhost -f
```

#### Connect to a Redis host using TLS and fill the cache with 1GB of data

```sh
cabal run redis-client -- fill -h localhost -t -d 1
```

#### High-performance cache filling with custom settings

```sh
# Use 4MB chunks for maximum throughput
REDIS_CLIENT_FILL_CHUNK_KB=4096 cabal run redis-client -- fill -h localhost -d 5
```

#### Conservative memory usage for resource-constrained environments

```sh
# Use smaller chunks for lower memory usage
REDIS_CLIENT_FILL_CHUNK_KB=1024 cabal run redis-client -- fill -h localhost -d 1
```

## Profiling

To enable profiling, use the following command:

```sh
cabal run redis-client --enable-profiling -- +RTS -hT -pj -RTS -h localhost -d 1 -f
```

### Profiling Tools

- `hp2ps`: Convert heap profile to PostScript
  - `hp2ps -e18in -c redis-client.hp`
- `evince`: View PostScript files
- [Speedscope](https://www.speedscope.app/): Interactive flamegraph viewer

### Helpful Resources

- [Detecting Lazy Memory Leaks in Haskell](https://stackoverflow.com/questions/61666819/haskell-how-to-detect-lazy-memory-leaks)
- [Tools for Analyzing Performance of a Haskell Program](https://stackoverflow.com/questions/3276240/tools-for-analyzing-performance-of-a-haskell-program)

### RTS Options

To include RTS options in the executable, use:

```sh
"-with-rtsopts=-hT"
```

## Development and Testing

### Quick Start with Makefile

The project includes a Makefile with common development tasks:

```sh
make help           # Show all available commands
make build          # Build the project
make test           # Run all tests (unit + e2e)
make test-unit      # Run unit tests only
make test-e2e       # Run end-to-end tests
make redis-start    # Start local Redis for testing
make redis-stop     # Stop local Redis
make profile        # Build with profiling enabled
make clean          # Clean build artifacts
```

### Running Tests

#### 1. Unit Tests

Unit tests can be run without Redis:

```sh
cabal test RespSpec
# or
make test-unit
```

#### 2. End-to-End Tests

E2E tests require a running Redis instance. There are two ways to run them:

**Option A: Using Docker Compose (Full E2E Suite)**

This runs the complete test suite in Docker containers:

```sh
./rune2eTests.sh
# or
make test-e2e
```

**Option B: Local Development**

For faster iteration during development:

```sh
# Start Redis locally
make redis-start

# Build and run tests
cabal build
cabal test

# Stop Redis when done
make redis-stop
```

#### 3. Run All Tests

```sh
make test
```

### Setting Up a Local Redis Instance

#### Quick Method (Simple Redis)

Use the provided script to start a simple Redis instance:

```sh
./start-redis-local.sh
```

This creates a Docker container named `redis-client-dev` accessible at `localhost:6379`.

#### Using Docker Compose (Full Setup with TLS)

For the complete setup including TLS support:

```sh
docker compose up -d redis
```

This uses the configuration in `docker-compose.yml` and `redis.conf`.

#### Manual Docker Command

```sh
docker run -d --name redis-client-dev -p 6379:6379 redis:latest
```

### Stopping Redis

```sh
# Using the script
./stop-redis-local.sh

# Using Docker Compose
docker compose stop redis

# Using Docker directly
docker stop redis-client-dev

# Remove the container
docker rm redis-client-dev
```

### Testing Workflow Examples

**1. Quick development cycle:**
```sh
make redis-start     # Start Redis once
make build           # Build the project
make test-unit       # Run unit tests
# ... make changes ...
make test-unit       # Test again
make redis-stop      # Stop when done
```

**2. Full test before PR:**
```sh
make test            # Runs all tests (starts/stops Redis automatically)
```

**3. Manual testing:**
```sh
make redis-start
cabal run redis-client -- fill -h localhost -f -d 1
make redis-stop
```

### Profiling with Redis

To profile the application with a local Redis instance:

```sh
# Start Redis
make redis-start

# Profile before changes (use -f flag for local Docker Redis)
cabal run --enable-profiling -- fill -h localhost -f -d 1 +RTS -p -RTS

# Make your changes...

# Profile after changes
cabal run --enable-profiling -- fill -h localhost -f -d 1 +RTS -p -RTS

# Compare the .prof files
# Stop Redis
make redis-stop

# Clean up profiling artifacts
rm -f *.hp *.prof *.ps *.aux *.stat
```

### CI/CD Integration

The project uses GitHub Actions for CI. Check `.github/workflows/` for the CI configuration.

## License

This project is licensed under the MIT License.
