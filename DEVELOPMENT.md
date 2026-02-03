# Development Guide

This guide will help you set up your development environment and run tests for the Redis client project.

## Prerequisites

- **GHC** (Glasgow Haskell Compiler) - version 9.14 or compatible
- **Cabal** - Haskell build tool
- **Docker** - For running Redis locally
- **(Optional) Nix** - For reproducible builds

### Installing Prerequisites

#### On Ubuntu/Debian
```bash
# Install GHC and Cabal via GHCup (recommended)
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# Install Docker
sudo apt-get update
sudo apt-get install docker.io docker-compose-plugin

# Install system dependencies
sudo apt-get install libreadline-dev
```

#### On macOS
```bash
# Install GHC and Cabal via GHCup
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# Install Docker Desktop
# Download from https://www.docker.com/products/docker-desktop
```

## Quick Start

### 1. Clone and Build

```bash
git clone <repository-url>
cd redis-client
cabal update
cabal build
```

### 2. Run Tests

#### Run Unit Tests
Unit tests don't require Redis:
```bash
cabal test RespSpec
# or
make test-unit
```

#### Run with Local Redis
```bash
# Start Redis
./start-redis-local.sh

# Run tests
cabal build
cabal test

# Stop Redis
./stop-redis-local.sh
```

### 3. Using the Makefile

The Makefile provides convenient shortcuts:

```bash
make help          # Show all available commands
make build         # Build the project
make test-unit     # Run unit tests only
make redis-start   # Start local Redis
make redis-stop    # Stop local Redis
make clean         # Clean build artifacts
```

## Development Workflow

### Typical Development Cycle

1. **Start Redis** (if needed for your changes):
   ```bash
   make redis-start
   ```

2. **Make your changes** to the code

3. **Build** the project:
   ```bash
   make build
   ```

4. **Run tests**:
   ```bash
   make test-unit    # Quick feedback
   ```

5. **Iterate** on steps 2-4 until satisfied

6. **Clean up** when done:
   ```bash
   make redis-stop
   ```

### Running the Application

To run the Redis client application:

```bash
# Basic usage
cabal run redis-client -- fill -h localhost -d 1 -f

# With profiling
cabal run --enable-profiling -- fill -h localhost -d 1 -f +RTS -p -RTS
```

## Profiling

### Before Making Changes

Profile your code before making changes to establish a baseline:

```bash
# Start Redis
make redis-start

# Run with profiling (use -f flag for local Docker Redis)
cabal run --enable-profiling -- fill -h localhost -d 1 -f +RTS -p -RTS

# This creates redis-client.prof
```

### After Making Changes

```bash
# Run again with profiling
cabal run --enable-profiling -- fill -h localhost -d 1 -f +RTS -p -RTS

# Compare the .prof files
diff redis-client.prof redis-client.prof.old
```

### Cleaning Up Profiling Artifacts

```bash
rm -f *.hp *.prof *.ps *.aux *.stat
# or
make clean
```

## Testing Infrastructure

### Unit Tests (RespSpec)

Located in `test/Spec.hs`. These test the RESP protocol implementation and don't require Redis.

```bash
cabal test RespSpec
```

### End-to-End Tests

Located in `test/E2E.hs`. These require a running Redis instance.

**Option 1: Docker Compose (Full Suite)**
```bash
./rune2eTests.sh
```

**Option 2: Local Redis**
```bash
./start-redis-local.sh
cabal build
cabal test
./stop-redis-local.sh
```

## Docker Setup

### Simple Redis (Development)

The `start-redis-local.sh` script starts a basic Redis container:

```bash
./start-redis-local.sh
# Creates container 'redis-client-dev' on port 6379
```

### Full Setup with TLS

Use Docker Compose for the complete setup including TLS:

```bash
docker compose up -d redis
```

Configuration files:
- `docker-compose.yml` - Service definitions
- `redis.conf` - Redis configuration with TLS

## Troubleshooting

### "readline not found" Error

Install the readline development library:
```bash
# Ubuntu/Debian
sudo apt-get install libreadline-dev

# macOS
brew install readline
```

### Docker Permission Issues

If you get permission denied errors with Docker:
```bash
# Add your user to the docker group
sudo usermod -aG docker $USER
# Log out and back in
```

### Build Dependency Issues

If you encounter dependency resolution issues:
```bash
cabal clean
cabal update
cabal build
```

## Project Structure

```
redis-client/
├── app/              # Application entry point
├── lib/              # Library code
│   ├── client/       # Redis client implementation
│   ├── crc16/        # CRC16 implementation
│   ├── redis-command-client/  # Command client
│   └── resp/         # RESP protocol implementation
├── test/             # Test files
│   ├── Spec.hs       # Unit tests
│   └── E2E.hs        # End-to-end tests
├── Makefile          # Build automation
├── redis-client.cabal # Package configuration
├── cabal.project     # Cabal project configuration
└── docker-compose.yml # Docker setup
```

## Useful Commands

### Cabal Commands
```bash
cabal build                    # Build the project
cabal test                     # Run all tests
cabal test RespSpec            # Run specific test suite
cabal clean                    # Clean build artifacts
cabal repl                     # Start GHCi REPL
```

### Docker Commands
```bash
docker ps                      # List running containers
docker logs redis-client-dev   # View Redis logs
docker stop redis-client-dev   # Stop Redis
docker start redis-client-dev  # Start Redis
docker rm redis-client-dev     # Remove Redis container
```

## Contributing

When contributing:

1. Always run tests before submitting changes
2. Profile performance-critical changes
3. Update documentation for user-facing changes
4. Follow existing code style

See README.md for more information about the project.
