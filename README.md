# Redis Client

A Haskell Redis client with standalone and cluster modes, plaintext and TLS
connections, and a RESP2-first command protocol implementation.

### RESP support

The public command parser and encoder support this exact value set:

- RESP2 simple strings, errors, integers, bulk strings (including null bulk
  strings), and non-null arrays.
- RESP3-shaped map and set aggregates.

They do not provide general RESP3 support: pushes, attributes, streamed
encodings, booleans, doubles, big numbers, bulk errors, verbatim strings, and
arbitrary module replies are unsupported, and the client does not negotiate
RESP3 session semantics. The pinned cluster tunnel is different: its opaque
fallback forwards complete RESP3 frames that are outside `RespData`, including
streamed values, byte-for-byte for transport compatibility. Parsed map and set
replies are re-encoded, so their original ordering is not preserved.

## Quick Start

### Installation

**Using Nix (recommended):**
```sh
# Install the CLI and Azure helper from the current checkout
nix profile install .#

# Or install the same commands directly from GitHub
nix profile install github:sspeaks/redis-client
```

Both commands install `redis-client` and the canonical
`azure-redis-connect` helper. The older `redis-connect` name remains available
as a compatibility alias.

**Using Cabal:**
```sh
cabal install exe:redis-client

# The Python helper is run from a source checkout; Cabal does not install it.
python3 scripts/azure-redis-connect.py --help
```

### Basic Usage

The CLI reference below is kept in parity with `redis-client --help`.

<!-- BEGIN GENERATED CLI REFERENCE -->
#### Public modes

| Mode | Purpose | Notes |
| --- | --- | --- |
| `cli` | Interactive Redis REPL. | Standalone by default; add `--cluster` for cluster seed-node routing. |
| `fill` | Load random data for testing. | Supports destructive flushes only with exact confirmation. |
| `tunn` | Start the proxy/tunnel entrypoint. | Standalone mode requires `--tls`; cluster mode supports `smart` and `pinned`. |
| `bench` | Measure cluster throughput. | Requires `--cluster` and emits a JSON summary to stdout. |

#### Public options

| Option | Applies to | Details |
| --- | --- | --- |
| `--help` | all | Print this help text and exit with status 0. |
| `-h`, `--host HOST` | `cli`, `fill`, `tunn`, `bench` | Redis host or cluster seed node. Required for every mode except `--help`. |
| `-p`, `--port PORT` | `cli`, `fill`, `tunn`, `bench` | Connection port. Defaults to 6379 for plaintext and 6380 for TLS. |
| `-u`, `--username USERNAME` | `cli`, `fill`, `tunn`, `bench` | ACL username used with environment-provided credentials. Default: `default`. |
| `-t`, `--tls` | `cli`, `fill`, `tunn`, `bench` | Use TLS for the upstream Redis connection. |
| `--allow-insecure-plaintext-auth` | `cli`, `fill`, `tunn`, `bench` | Allow environment-provided credentials over plaintext and emit a warning naming the target host. |
| `-c`, `--cluster` | `cli`, `fill`, `tunn`, `bench` | Enable Redis Cluster behavior. Required for `bench`; optional for the other modes. |
| `--verbose-pinned-proxy-traffic` | `tunn` | Enable opt-in pinned-proxy request/response payload previews for debugging. Default: off. |
| `-d`, `--data GBs` | `fill` | Random data size in GiB. Required unless `--flush` is the only requested action. |
| `-f`, `--flush` | `fill` | Request `FLUSHALL` before filling, or perform a flush-only run when `--data` is omitted. Requires exact confirmation. |
| `--confirm-flush TARGET` | `fill` | Exact non-interactive acknowledgement for `--flush`. Required whenever stdin is not a terminal. |
| `-s`, `--serial` | `fill` | Disable concurrent fill workers and run the fill loop serially. |
| `-n`, `--connections NUM` | `fill`, `bench` | Parallel worker count. Default: 2. In `fill`, this is standalone connections or cluster threads per node; in `bench`, this is benchmark worker threads. |
| `--key-size BYTES` | `fill`, `bench` | Key size. Default: 512 bytes. Range: 1-65536. |
| `--value-size BYTES` | `fill`, `bench` | Value size. Default: 512 bytes. Range: 1-524288. |
| `--pipeline COUNT` | `fill` | Commands per pipeline batch. Default: 8192. Minimum: 1. |
| `-P`, `--processes NUM` | `fill` | Parallel child processes for `fill`. Default: 1. Only the parent process confirms and performs `--flush`. |
| `--tunnel-mode MODE` | `tunn` | Cluster tunnel strategy. Values: `smart` or `pinned`. Default: `smart`. |
| `--operation OP` | `bench` | Benchmark workload. Values: `set`, `get`, or `mixed`. Default: `set`. |
| `--duration SECS` | `bench` | Benchmark duration in seconds. Default: 30. Minimum: 1. |
| `--mux-count NUM` | `bench` | Multiplexers per cluster node during `bench`. Default: 1. Minimum: 1. |

#### Environment variables

| Name | Details |
| --- | --- |
| `REDIS_CLIENT_PASSWORD_FILE` | Path to a Redis credential file. Highest precedence; strips one trailing newline. |
| `REDIS_CLIENT_PASSWORD` | Redis credential value used only when `REDIS_CLIENT_PASSWORD_FILE` is unset. |
| `REDIS_CLIENT_TLS_INSECURE` | Set to exactly `1` to disable TLS certificate verification. Unset, empty, `0`, and `false` keep verification enabled; every other value is rejected. |

#### Flush confirmation

- `--flush` is intent only. The client never sends `FLUSHALL` without an exact confirmation target.
- Standalone target: `redis://HOST:PORT?tls=true|false&scope=single-node`
- Cluster target: `redis+cluster://HOST:PORT?tls=true|false&scope=all-primaries`
- In a terminal, the client prompts for the exact displayed target. In non-interactive automation, pass that exact value with `--confirm-flush`.
- With `--processes N` for `N > 1`, only the parent process confirms and flushes once before spawning children.

#### Representative examples

```sh
redis-client --help
redis-client cli -h localhost
redis-client cli -h localhost -c
redis-client fill -h localhost -d 5 --pipeline 4096 --key-size 128 --value-size 1024
redis-client fill -h localhost -f --confirm-flush 'redis://localhost:6379?tls=false&scope=single-node'
redis-client fill -h redis1.local -c -d 10 -n 4 -P 2
redis-client tunn -h redis1.local -t -c --tunnel-mode smart
redis-client tunn -h redis1.local -c --tunnel-mode pinned --verbose-pinned-proxy-traffic
redis-client bench -h redis1.local -c --operation mixed --duration 15 --connections 32 --mux-count 2
REDIS_CLIENT_PASSWORD_FILE=/secure/redis.pass redis-client cli -h cache.local -t
```
<!-- END GENERATED CLI REFERENCE -->

### Smart cluster tunnel framing

Smart cluster tunnel mode incrementally accepts RESP request frames across TCP
reads and pipelines complete requests in wire order. To bound per-client
retained input, each complete encoded request frame is limited to **1,048,576
bytes**. A malformed or oversized frame receives one RESP error and the proxy
then closes that client connection; an incomplete frame at peer EOF is closed
without execution. Bytes after a framing failure are never executed.

This is a deliberate bounded proxy policy, not a claim that smart tunnel mode
supports every request size accepted by Redis itself. Clients that need larger
requests should connect directly to the cluster nodes (or use pinned mode) and
remain within the applicable Redis deployment limits.

Pinned cluster tunnels forward traffic in both directions. Replies represented
by `RespData`, including RESP3-shaped maps and sets, are parsed and re-encoded
while applicable topology values are rewritten. The opaque fallback forwards
complete RESP3 frames outside that subset, including streamed values,
byte-for-byte. Malformed or incomplete streamed RESP3 framing fails closed by
closing the connection rather than attempting to resynchronize inside a
possible binary payload. This narrow framing compatibility is not a claim of
general RESP3 command support. Incomplete pinned replies retain at most a
512 MiB Redis bulk payload plus its RESP framing overhead.

### Fill capacity limits

Before connecting or spawning children, fill mode validates positive process,
connection, and pipeline values. Serial mode always executes one connection per
process, regardless of `--connections`. The normal safety envelope is **8 processes**,
**16 connections per process**, **32 total workers**, and an estimated
**2 GiB** peak client-memory ceiling. The estimate reserves **128 MiB per
process** for the shared random-noise buffer plus one conservatively sized
encoded pipeline batch per worker (`COUNT * (key bytes + value bytes + 64)`).

Cluster mode discovers the primary count before launching fill workers and
reports the multiplied total as `processes x primaries x connections`; that
post-discovery total is also checked against the worker and memory limits.
Use `--allow-high-scale-fill` only after sizing the host and Redis deployment:
it is an explicit acknowledgement that these protective caps are intentionally
being exceeded, not an automatic performance optimization.

### Flush confirmation details

`--flush` is deliberately insufficient, including for localhost. In a terminal,
the client displays the canonical target and requires it to be typed exactly.
For non-interactive automation, pass that same target to `--confirm-flush`.
Standalone targets use
`redis://HOST:PORT?tls=true|false&scope=single-node`; cluster targets use
`redis+cluster://HOST:PORT?tls=true|false&scope=all-primaries`. `PORT` is the
effective port (6379 plaintext or 6380 TLS when omitted), and an IPv6 host is
written in brackets (for example, `[2001:db8::1]`). The `--tls` flag controls
the connection; `tls=true` records that choice in the target. Cluster
confirmation explicitly covers FLUSHALL on every primary.

In an interactive terminal, the exact displayed target must be typed. EOF
(including Ctrl-D) or any mismatch cancels the operation before connecting.
When stdin is not a terminal, no prompt is available: `--confirm-flush` is
required and must exactly equal the canonical target. With `--processes N`
for `N > 1`, only the parent process confirms and performs one flush before
spawning children; child processes receive no flush request and never repeat
the confirmation.

```sh
# Non-interactive standalone flush
redis-client fill -h localhost --flush \
  --confirm-flush 'redis://localhost:6379?tls=false&scope=single-node'

# Non-interactive cluster flush
redis-client fill -h redis1.local -c --flush \
  --confirm-flush 'redis+cluster://redis1.local:6379?tls=false&scope=all-primaries'
```

For CI, use an explicitly disposable Redis fixture and keep the exact target
in the command. This example has no credentials, publishes only to loopback on
port 16379, waits at most 30 seconds for Redis to answer `PING`, prints its
logs on a readiness failure, and always removes its uniquely named fixture:

```sh
fixture_name="redis-client-flush-fixture-$$"
cleanup() {
  docker rm -f "$fixture_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker run --rm -d --name "$fixture_name" -p 127.0.0.1:16379:6379 redis:7
ready=false
for attempt in $(seq 1 30); do
  if docker exec "$fixture_name" redis-cli ping 2>/dev/null | grep -qx PONG; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "Redis fixture did not become ready within 30 seconds." >&2
  docker logs "$fixture_name" >&2 || true
  exit 1
fi

redis-client fill -h 127.0.0.1 -p 16379 -f \
  --confirm-flush 'redis://127.0.0.1:16379?tls=false&scope=single-node'
```

### Credential handling

Credential command-line options are intentionally unsupported. Use an owner-only
credential file where possible:

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

Environment variables are convenient for automation but may be visible to other
same-user or privileged processes, depending on operating-system and platform
policy. Avoid exporting credentials into shell startup files.

Credentialed connections require TLS by default. For a trusted local test
server that does not support TLS, acknowledge the risk explicitly:

```sh
REDIS_CLIENT_PASSWORD_FILE="$HOME/.config/redis-client/password" \
  redis-client cli -h 127.0.0.1 --allow-insecure-plaintext-auth
```

This override prints a prominent warning naming the target and stating that the
credential is being sent unencrypted. Do not use it across shared or untrusted
networks.

TLS certificate verification remains enabled unless
`REDIS_CLIENT_TLS_INSECURE=1` is set. This bypass is intended only for
controlled testing with a server whose certificate cannot be verified:

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

Nix installations also provide `redis-connect` as a compatibility alias. From
a source checkout after a Cabal install, use
`python3 scripts/azure-redis-connect.py` instead.

**Prerequisites:** Azure CLI (`az login`), Python 3.6+, `redis-client` on
`PATH`, and Azure permissions for Redis access.

See [docs/AZURE_EXAMPLES.md](docs/AZURE_EXAMPLES.md) for detailed examples.

## Library Usage

### Standalone Multiplexed Client

The standalone multiplexed client gives you pipelined throughput for a single (non-cluster) Redis server. Multiplexing is enabled by default.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Database.Redis

main :: IO ()
main =
  withStandaloneClient defaultStandaloneConfig $ \client -> do
    result <- runStandaloneClient client $ do
      (_ :: Bool) <- set "mykey" "myvalue"
      get "mykey"
    print (result :: ByteString)
```

Set `standaloneMultiplexerCount` to control how many multiplexed connections
the client creates. For TLS connections, update `standaloneConnector` to
`clusterTLSConnector "redis.example.com"`.
Library callers that issue `AUTH` directly are responsible for choosing a TLS
connector; the CLI enforces the credentialed-plaintext policy because it owns
both the credential and transport configuration.

### Cluster Client

Cluster mode uses multiplexing for command routing and pipelining.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Database.Redis

main :: IO ()
main =
  withClusterClient config clusterPlaintextConnector $ \client -> do
    result <- runClusterCommandClient client $ do
      (_ :: Bool) <- set "{example}:key" "myvalue"
      get "{example}:key"
    print (result :: ByteString)
  where
    config = ClusterConfig
      { clusterSeedNode = NodeAddress "localhost" 7000
      , clusterPoolConfig = PoolConfig
          { maxConnectionsPerNode = 2
          , connectionTimeout = 5
          , maxRetries = 3
          , useTLS = False
          }
      , clusterMaxRetries = 3
      , clusterRetryDelay = 100000
      , clusterTopologyRefreshInterval = 600
        }
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

### Contributor prerequisites

The supported development environment is Nix-first. Before the first build,
install:

- Git, Make, and [Nix](https://nixos.org/download/) with flakes enabled.
- Docker with the Compose plugin if you will run the full end-to-end suite.
- [direnv](https://direnv.net/) is optional; the tracked `.envrc` enters the
  same flake development shell as `nix develop`.

The Nix development shell supplies GHC, Cabal, Haskell Language Server,
`stylish-haskell`, and native dependencies such as zlib. The executable also
links against readline. If you cannot use Nix, install a C toolchain, GHC,
Cabal, readline development headers, and zlib development headers before
building (for example, `build-essential libreadline-dev zlib1g-dev` on
Debian/Ubuntu).

### First-time setup

Clone the repository, enter the development environment, and run the repository
setup target once:

```sh
git clone https://github.com/sspeaks/redis-client.git
cd redis-client

# Choose one environment entry point:
nix develop
# Or, with direnv installed:
direnv allow

make setup
```

`nix develop` provides the reproducible compiler, tools, and native libraries;
`direnv allow` automatically enters that same shell when you change into the
repository. `make setup` is a separate one-time repository bootstrap: it points
Git at the tracked `.githooks/` directory and updates Cabal's package index.
Entering the Nix shell also configures the hook path, but `make setup` remains
the explicit bootstrap command and prepares Cabal for workspace builds.

For a system-Cabal setup without Nix, install the native dependencies above and
then run `make setup`. On Debian/Ubuntu the target can install
`libreadline-dev`; install the remaining compiler and zlib prerequisites
yourself first. In this fallback, `make` targets use the GHC and Cabal available
on `PATH`.

### Build

For the reproducible Nix package build:

```sh
nix-build --no-out-link
```

For a faster workspace build while developing:

```sh
make build
```

`make build` builds both the root `redis-client` executable package and the
`hask-redis-mux` library package. With Nix available it also enables the E2E
executables by running:

```sh
cabal build all -fe2e
```

Without Nix, `make build` falls back to the system GHC and Cabal on `PATH` and
runs `cabal build all`; this builds both packages without enabling the E2E
executables.

### Running Tests

**Unit and repository checks** (no running Redis required):
```sh
make test-unit
```

The system-Cabal fallback for the Haskell unit suites is:

```sh
cabal build all
cabal test all
```

`make test-unit` is broader: in addition to all Cabal test suites, it checks
generated Redis command metadata, credential handling, GitHub issue workflow
status, and the E2E runner scripts.

**Full test suite** (requires Docker, the Docker Compose plugin, and Nix):
```sh
make test
```

The full target runs the unit/repository checks plus the standalone, direct TLS,
cluster, authenticated-cluster, and library end-to-end suites. Individual
Docker suites remain available when narrowing a failure:

```sh
make test-e2e
make test-direct-tls-e2e
make test-cluster-e2e
make test-authenticated-cluster-e2e
make test-library-e2e
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

### Reproducible performance benchmarks

The repository ships a dedicated `redis-client-benchmark` executable for
repeatable JSON benchmark runs instead of relying on the ad hoc cluster-only
`redis-client bench` CLI mode.

It covers:

- `--scenario standalone` - multiplexed standalone Redis.
- `--scenario cluster` - routed cluster traffic through the cluster client's
  per-node multiplexer pool.
- `--scenario slow-server` - a built-in delayed or stalled RESP server for
  backpressure, timeout, and memory-stability checks.

Every run records the benchmark configuration, machine metadata, selected RTS
settings, ops/s, latency percentiles (`p50`, `p95`, `p99`, `p999`),
errors/timeouts, allocation bytes per attempted operation, peak residency,
post-GC live bytes, GC CPU%, and sampled queue/in-flight high-water marks.

**Fast smoke benchmark**:

```sh
make benchmark-smoke
```

That smoke path runs short standalone, cluster, and slow-server workloads,
writes JSON artifacts to `artifacts/benchmark-smoke/`, and is the benchmark
coverage used in CI. Longer sweeps and higher-concurrency variants stay opt-in.

**Representative opt-in commands**:

```sh
# Standalone
cabal run redis-client-benchmark -- \
  --scenario standalone \
  --host 127.0.0.1 \
  --port 6379 \
  --duration 15 \
  --warmup 3 \
  --concurrency 16 \
  --batch-size 64 \
  --mux-count 2 \
  --key-size 32 \
  --payload-size 256 \
  --operation mixed \
  --timeout-ms 1000 \
  --output artifacts/standalone-benchmark.json \
  +RTS -T -RTS

# Cluster (for the local Docker fixture, run from the host against published ports)
cabal run redis-client-benchmark -- \
  --scenario cluster \
  --host 127.0.0.1 \
  --port 6379 \
  --duration 15 \
  --warmup 3 \
  --concurrency 16 \
  --batch-size 64 \
  --mux-count 2 \
  --key-size 32 \
  --payload-size 256 \
  --operation mixed \
  --timeout-ms 1000 \
  --output artifacts/cluster-benchmark.json \
  +RTS -T -RTS

# Slow / stalled server
cabal run redis-client-benchmark -- \
  --scenario slow-server \
  --duration 10 \
  --warmup 0 \
  --concurrency 8 \
  --batch-size 32 \
  --mux-count 1 \
  --key-size 16 \
  --payload-size 64 \
  --operation ping \
  --timeout-ms 100 \
  --response-delay-ms 50 \
  --stall-after-requests 32 \
  --output artifacts/slow-server-benchmark.json \
  +RTS -T -RTS
```

### Profiling

Profile before and after changes with the same benchmark shape so the JSON
output and `.prof` report are directly comparable:

```sh
# Baseline on main
git switch main
make redis-start

# Capture the before result and cost-centre profile
cabal run redis-client-benchmark --enable-profiling -- \
  --scenario standalone \
  --host 127.0.0.1 \
  --port 6379 \
  --duration 15 \
  --warmup 3 \
  --concurrency 16 \
  --batch-size 64 \
  --mux-count 2 \
  --key-size 32 \
  --payload-size 256 \
  --operation mixed \
  --timeout-ms 1000 \
  --output artifacts/before-standalone-benchmark.json \
  +RTS -T -p -s -RTS
mv redis-client-benchmark.prof artifacts/before-standalone-benchmark.prof

# Make the change, rebuild, and capture the after result with the exact same command
cabal run redis-client-benchmark --enable-profiling -- \
  --scenario standalone \
  --host 127.0.0.1 \
  --port 6379 \
  --duration 15 \
  --warmup 3 \
  --concurrency 16 \
  --batch-size 64 \
  --mux-count 2 \
  --key-size 32 \
  --payload-size 256 \
  --operation mixed \
  --timeout-ms 1000 \
  --output artifacts/after-standalone-benchmark.json \
  +RTS -T -p -s -RTS
mv redis-client-benchmark.prof artifacts/after-standalone-benchmark.prof

# Compare the structured benchmark output first
python3 scripts/compare-benchmark-results.py \
  artifacts/before-standalone-benchmark.json \
  artifacts/after-standalone-benchmark.json

# Then inspect the cost-centre profiles side by side
diff -u artifacts/before-standalone-benchmark.prof artifacts/after-standalone-benchmark.prof || true

make redis-stop

# Clean up profiling artifacts when you're done
rm -f *.hp *.prof *.ps *.aux *.stat
```

**Profiling tools:**
- `hp2ps -e18in -c redis-client.hp` - Convert heap profile to PostScript
- [Speedscope](https://www.speedscope.app/) - Interactive flamegraph viewer

### Runtime profiles

The shared executable and test stanzas now use the RTS defaults that ship with GHC. That keeps CLI startup, tunnels, and test runs on conservative settings unless you opt into a workload-specific profile.

For the fill pipeline in `app/FillHelpers.hs` and the default `pipelineBatchSize = 8192` in `app/AppConfig.hs`, use the wrapper script when you actually want a tuned profile:

```sh
# Measured high-throughput fill / bench profile (caps clamp to visible CPUs, max 4)
./scripts/run-with-rts-profile.sh fill-throughput -- \
  cabal run redis-client -- fill -h localhost -f -d 1

# Memory-constrained fill profile for local test workloads
./scripts/run-with-rts-profile.sh fill-bounded -- \
  cabal run redis-client -- fill -h localhost -f -d 1 --pipeline 1024
```

The `fill-bounded` profile intentionally pairs `-f` with a smaller pipeline so local validation stays within tighter memory limits. For the legacy comparison profile and the measured benchmark matrix, see [docs/rts-profiles.md](docs/rts-profiles.md).

## Project Structure

- `redis-client.cabal` - Root executable package definition.
- `app/` - `redis-client` executable sources for CLI, fill, and tunnel modes.
- `bench/` - Dedicated reproducible benchmark executable sources.
- `test/` - Root executable unit tests and Docker E2E test programs.
- `hask-redis-mux/hask-redis-mux.cabal` - Public Redis client library package.
- `hask-redis-mux/lib/resp/` - RESP protocol implementation.
- `hask-redis-mux/lib/client/` - Plaintext and TLS connection management.
- `hask-redis-mux/lib/redis-command-client/` - Redis command execution.
- `hask-redis-mux/lib/cluster/` - Cluster routing, pools, multiplexers, and
  standalone client support.
- `hask-redis-mux/lib/crc16/` - CRC16 hash-slot implementation.
- `hask-redis-mux/lib/redis/` - Public `Database.Redis` facade.
- `hask-redis-mux/test/` and `hask-redis-mux/bench/` - Library tests and
  benchmarks.
- `Makefile`, `flake.nix`, `shell.nix`, and `default.nix` - Supported
  development and Nix packaging entry points.
- `scripts/` and `docker/` - Repository checks and owned Docker E2E fixtures.
- `.githooks/` - Tracked contributor hooks enabled by `make setup` and the Nix
  development shell.

## License

MIT License
