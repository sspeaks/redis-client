# Redis Client

A Haskell-based Redis client that supports both plain text and TLS connections.

## Features

- Connect to Redis using plain text or TLS
- Send and receive RESP data
- Perform basic Redis commands
- Profile the application for performance analysis

## Usage

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

### Running the Client

To run the client, use the following command:

```sh
cabal run redis-client -- [OPTIONS]
```

### Options

- `-h`, `--host HOST`: Host to connect to
- `-p`, `--password PASSWORD`: Password to authenticate with
- `-t`, `--tls`: Use TLS
- `-d`, `--data GBs`: Random data amount to send in GB
- `-f`, `--flush`: Flush the database

### Performance Tuning Environment Variables

For optimal cache filling performance, you can tune these environment variables:

- `REDIS_CLIENT_FILL_CHUNK_KB`: Chunk size in KB (default: 2048)
  - Larger chunks reduce network round-trips but use more memory
  - Recommended range: 1024-4096 KB
  
- `REDIS_CLIENT_PIPELINE_SIZE`: Number of commands per pipeline batch (default: 1000)
  - Larger pipelines improve throughput but use more memory
  - Recommended range: 500-5000 depending on network latency

#### Performance Guidelines

| Scenario | Chunk Size | Pipeline Size | Memory Usage |
|----------|------------|---------------|-------------|
| Conservative | 1024 KB | 500 | ~512 MB |
| Balanced (default) | 2048 KB | 1000 | ~2 GB |
| High Performance | 4096 KB | 2000 | ~8 GB |
| Maximum Throughput | 4096 KB | 5000 | ~20 GB |

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
# Use 4MB chunks and 2000-command pipeline for maximum throughput
REDIS_CLIENT_FILL_CHUNK_KB=4096 REDIS_CLIENT_PIPELINE_SIZE=2000 \
cabal run redis-client -- fill -h localhost -d 5
```

#### Conservative memory usage for resource-constrained environments

```sh
# Use smaller chunks and pipeline for lower memory usage
REDIS_CLIENT_FILL_CHUNK_KB=1024 REDIS_CLIENT_PIPELINE_SIZE=500 \
cabal run redis-client -- fill -h localhost -d 1
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

## Running End-to-End Tests

To run end-to-end tests, use the following command:

```sh
cabal test
```

If you are using Nix, you can run the tests with:

```sh
nix-shell --run "cabal test"
```

## License

This project is licensed under the MIT License.
