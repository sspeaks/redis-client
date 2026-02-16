# PRD: hask-redis-mux vs StackExchange.Redis Comparison Document Generator

## Overview

A Python script that generates a comprehensive, objective technical comparison document between **hask-redis-mux** (Haskell) and **StackExchange.Redis** (C#/.NET). The document covers raw library usage (direct Redis operations) and a REST API comparison using the cache-aside pattern. The script connects to a live Redis cluster, runs benchmarks, and produces both Markdown and HTML output.

## Problem Statement

Engineers evaluating Redis client libraries across the Haskell and .NET ecosystems lack a single, authoritative reference that objectively compares API ergonomics, feature coverage, and runtime performance. This tool fills that gap by generating a living document from real benchmark data against any Redis cluster.

## Goals

- Provide an objective, side-by-side technical comparison for engineers evaluating both libraries
- Include real benchmark data collected at generation time against a target Redis cluster
- Cover both raw library usage and REST API (cache-aside) integration patterns
- Output both Markdown (`.md`) and rendered HTML for flexible consumption
- Accept a Redis connection string as input so the document can be regenerated against any environment

## Non-Goals

- Marketing or advocacy for either library
- Covering every Redis command or data structure exhaustively
- Providing a production-ready REST application (examples are illustrative)
- Supporting non-cluster Redis topologies in benchmarks (standalone is used for localhost default)

## Target Audience

Software engineers and architects evaluating Redis client libraries, particularly those working in polyglot environments with both Haskell and .NET services.

---

## Functional Requirements

### FR-1: Script Interface

- **Input**: Redis connection string (e.g., `localhost:6379`, `redis.example.com:6380,password=xxx,ssl=true`)
- **Default**: `localhost:6379` when no argument is provided
- **Output**: Two files in an `output/` directory:
  - `comparison.md` — Markdown source
  - `comparison.html` — Rendered HTML with embedded CSS styling
- **Language**: Python 3.10+
- **Invocation**: `python3 generate_comparison.py <connection-string>`

### FR-2: Document Structure

The generated document must contain the following sections:

#### Section 1: Executive Summary
- Brief overview of both libraries (origin, ecosystem, license, maintenance status)
- Summary table of key differences

#### Section 2: Connection & Configuration
- Side-by-side code samples showing how to connect to a Redis server/cluster
- hask-redis-mux: `StandaloneConfig`, `withStandaloneClient`, `withClusterClient`
- StackExchange.Redis: `ConnectionMultiplexer.Connect()`, `ConfigurationOptions`
- Comparison of TLS configuration, connection pooling, and reconnection behavior

#### Section 3: Core Operations (Raw Library Usage)
Side-by-side code samples and API comparison for:
- **GET / SET / DEL** — basic string operations
- **PING** — connection health check
- **Pipelining** — hask-redis-mux multiplexed pipelining vs StackExchange.Redis `CreateBatch()` / async pipelining
- **TTL / Expiry** — setting key expiration
- **MGET / MSET** — multi-key operations
- **Pub/Sub** — subscribe/publish patterns
- **Transactions** — MULTI/EXEC support

Each operation section must include:
- Haskell code sample using hask-redis-mux
- C# code sample using StackExchange.Redis
- Brief comparison notes (API style, type safety, error handling)

#### Section 4: REST API Comparison (Cache-Aside Pattern)
- **Haskell**: Scotty web framework + hask-redis-mux
- **C#**: ASP.NET Core minimal API + StackExchange.Redis
- Full working example of a `GET /item/:id` endpoint implementing cache-aside:
  1. Check Redis cache for key
  2. On miss: fetch from mock data source, populate cache with TTL
  3. Return result
- Comparison of:
  - Boilerplate / setup code
  - Middleware and dependency injection patterns
  - Error handling approaches
  - Type safety and serialization

#### Section 5: Feature Comparison Matrix
A table comparing:
- Cluster support
- TLS support
- Connection pooling
- Multiplexed pipelining
- Typed responses
- Pub/Sub
- Transactions
- Lua scripting support
- Sentinel support
- Async/concurrent operation model

#### Section 6: Benchmark Results
Live benchmark data collected by the script at generation time:

**6a. Raw Operation Benchmarks**
- Single GET/SET latency (p50, p95, p99)
- Throughput (ops/sec) for sequential and pipelined operations
- MGET/MSET throughput for batch sizes of 10, 100, 1000

**6b. REST Cache-Aside Benchmarks**
- Request latency for cache hit vs cache miss (p50, p95, p99)
- Throughput (requests/sec) under concurrent load
- Comparison of cold-start times

**6c. Memory & GC Profiling**
- Haskell: RTS stats (`+RTS -s`) — max residency, total allocations, GC pause times, productivity
- C#/.NET: GC counters — Gen0/Gen1/Gen2 collections, total allocated bytes, peak working set
- Side-by-side comparison table of memory characteristics under identical workloads

Benchmark methodology notes:
- Number of iterations, warm-up rounds, and statistical methodology must be documented
- Both libraries run against the same Redis instance provided via connection string
- Results presented as tables and (optionally) ASCII charts

#### Section 7: Developer Experience Comparison
- Build system and dependency management (Cabal/Nix vs dotnet CLI/NuGet)
- Documentation quality and availability
- Community size and ecosystem maturity
- Error messages and debugging experience

#### Section 8: Conclusion
- Summary of strengths and weaknesses for each library
- Recommended use cases for each

### FR-3: Benchmark Runner

The script must:
- Build and run the pre-written Haskell benchmark program (checked into `comparison/benchmarks/haskell/`) using hask-redis-mux against the target Redis
- Build and run the pre-written C# benchmark program (checked into `comparison/benchmarks/csharp/`) using StackExchange.Redis against the same Redis
- Collect timing data and memory/GC statistics from both and embed results into the document
- For Haskell: capture RTS stats (`+RTS -s` output) for memory profiling
- For C#: capture .NET GC counters and peak working set for memory profiling
- Handle build failures gracefully (skip benchmarks, note in document)
- Clean up temporary build artifacts after generation (but not the source benchmark projects)

### FR-4: HTML Rendering

- Convert Markdown to HTML using Python (e.g., `markdown` or `markdown2` library)
- Include embedded CSS for clean, readable styling (table formatting, code syntax highlighting)
- Embed Chart.js (via CDN or inlined) for interactive bar and line charts of benchmark results
- Single-file HTML output (Chart.js loaded from CDN; document remains a single `.html` file)

### FR-5: Initial Document Generation

- The first invocation must target `localhost:6379` (a local Redis instance)
- If Redis is not running locally, the script should start one via Docker (`docker run -d -p 6379:6379 redis:latest`) or note that benchmarks were skipped

---

## Technical Requirements

### TR-1: Dependencies

**Python**:
- Python 3.10+
- `markdown2` or `markdown` for MD→HTML conversion
- `pygments` for code syntax highlighting in HTML
- `subprocess` for invoking Haskell and C# build/run commands

**Haskell benchmark** (generated/embedded by script):
- Uses hask-redis-mux library from this repository
- Cabal or Nix build

**C# benchmark** (generated/embedded by script):
- .NET 8.0+ SDK
- StackExchange.Redis NuGet package
- Minimal console app

### TR-2: Project Structure

```
hask-redis-mux/
├── tasks/
│   └── prd-redis-comparison.md          # This PRD
├── comparison/
│   ├── generate_comparison.py           # Main script
│   ├── templates/
│   │   ├── sections/                    # Markdown templates per section
│   │   └── style.css                    # Embedded CSS for HTML
│   ├── benchmarks/
│   │   ├── haskell/                     # Haskell benchmark project
│   │   │   ├── Main.hs
│   │   │   └── benchmark.cabal
│   │   └── csharp/                      # C# benchmark project
│   │       ├── Program.cs
│   │       └── Benchmark.csproj
│   └── output/                          # Generated output (gitignored)
│       ├── comparison.md
│       └── comparison.html
```

### TR-3: Error Handling

- If Haskell toolchain not found: skip Haskell benchmarks, note in document
- If .NET SDK not found: skip C# benchmarks, note in document
- If Redis connection fails: skip benchmarks, generate document with code comparison only
- All errors logged to stderr with clear messages

### TR-4: Idempotency

- Running the script multiple times overwrites previous output
- No side effects beyond the `output/` directory and temporary build artifacts

---

## Success Criteria

1. Running `python3 generate_comparison.py localhost:6379` produces both `comparison.md` and `comparison.html` in the output directory
2. The document contains all 8 sections specified in FR-2
3. Code samples for hask-redis-mux accurately reflect the library's actual API (as defined in this repository)
4. Code samples for StackExchange.Redis accurately reflect the library's current API
5. Benchmark data is collected from a live Redis instance and embedded in the document
6. HTML output renders correctly in a modern browser with readable formatting
7. The script handles missing toolchains gracefully without crashing

---

## Design Decisions

1. **Benchmark programs**: Pre-written and checked into the repo (more maintainable, can be tested independently)
2. **HTML charts**: Embedded Chart.js for interactive bar/line charts in the HTML output
3. **Memory profiling**: Yes — include memory/GC stats for both runtimes (Haskell RTS stats, .NET GC counters)
