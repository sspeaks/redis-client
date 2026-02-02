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
