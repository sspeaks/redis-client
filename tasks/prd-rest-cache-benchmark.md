# PRD: REST + Redis Cache Benchmark — Haskell redis-client vs StackExchange.Redis

## 1. Introduction / Overview

This feature creates two functionally identical REST API applications — one in Haskell (using the `redis-client` library from this repo) and one in C#/.NET (using StackExchange.Redis) — that serve CRUD endpoints backed by SQLite with Redis as a cache-aside layer. Both apps are then stress-tested with `autocannon` under identical conditions (standalone Redis and Redis Cluster with host networking) to produce a head-to-head performance comparison. The final deliverable is a comparison document that presents the numbers **and explains why** the differences exist.

## 2. Goals

- Validate that the Haskell `redis-client` library is competitive with StackExchange.Redis for real-world REST + cache workloads.
- Produce reproducible, apples-to-apples benchmarks where every variable except the Redis library is held constant.
- Generate a clear comparison document with latency percentiles (p50, p95, p99) and requests/sec, plus analysis of **why** each library performs the way it does.
- Run benchmarks against both standalone Redis and Redis Cluster (host networking via `docker-cluster-host/`).

## 3. User Stories

### US-001: SQLite Schema and Seed Data Script

**Description:** As a developer, I want a shared SQLite schema and seed script so that both apps start with the same database state.

**Acceptance Criteria:**
- [ ] SQL schema file at `benchmarks/shared/schema.sql` defining a `users` table: `id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, bio TEXT, created_at TEXT DEFAULT CURRENT_TIMESTAMP`
- [ ] Seed script at `benchmarks/shared/seed.py` (or shell) that inserts 10,000 rows with deterministic fake data (seeded random)
- [ ] Running the seed script twice produces identical data (idempotent — drops and recreates)
- [ ] A `benchmarks/shared/README.md` describes how to run the seed script

### US-002: C#/.NET REST API with StackExchange.Redis Cache Layer

**Description:** As a developer, I want a C#/.NET minimal API app that exposes CRUD endpoints for `users`, using StackExchange.Redis as a cache-aside layer over SQLite, so that I have the baseline comparison target.

**Acceptance Criteria:**
- [ ] .NET 8 minimal API project at `benchmarks/dotnet-rest/`
- [ ] Endpoints: `GET /users/:id`, `GET /users?page=&limit=`, `POST /users`, `PUT /users/:id`, `DELETE /users/:id`
- [ ] GET endpoints check Redis cache first (key format: `user:{id}`), fall back to SQLite, and populate cache on miss (TTL = 60s)
- [ ] POST/PUT invalidate (delete) the relevant cache key after writing to SQLite
- [ ] DELETE removes from both SQLite and cache
- [ ] Connects to Redis via `ConnectionMultiplexer` (configurable host/port via env vars `REDIS_HOST`, `REDIS_PORT`)
- [ ] SQLite database path configurable via env var `SQLITE_DB` (default: `benchmarks/shared/bench.db`)
- [ ] Supports Redis Cluster mode via env var `REDIS_CLUSTER=true`
- [ ] Listens on a configurable port via env var `PORT` (default: 5000)
- [ ] JSON request/response bodies
- [ ] `dotnet build` succeeds

### US-003: Haskell REST API with redis-client Cache Layer

**Description:** As a developer, I want a Haskell REST API app that exposes the same CRUD endpoints for `users`, using this repo's `redis-client` library as a cache-aside layer over SQLite, so that I can compare it against the C# app.

**Acceptance Criteria:**
- [ ] Haskell project at `benchmarks/haskell-rest/` with its own `.cabal` file (depends on `redis-client` library via source-repository-package or cabal.project)
- [ ] Uses a lightweight HTTP framework (e.g., `warp` + `wai` or `scotty`)
- [ ] Endpoints: `GET /users/:id`, `GET /users?page=&limit=`, `POST /users`, `PUT /users/:id`, `DELETE /users/:id`
- [ ] GET endpoints check Redis cache first (key format: `user:{id}`), fall back to SQLite, and populate cache on miss (TTL = 60s via `SETEX` or `SET ... EX 60`)
- [ ] POST/PUT invalidate (delete) the relevant cache key after writing to SQLite
- [ ] DELETE removes from both SQLite and cache
- [ ] Connects to Redis using `redis-client` library (`PlainTextClient` for standalone, cluster via `ClusterClient`)
- [ ] Redis host/port configurable via env vars `REDIS_HOST`, `REDIS_PORT`
- [ ] Cluster mode via env var `REDIS_CLUSTER=true`
- [ ] SQLite database path configurable via env var `SQLITE_DB` (default: `benchmarks/shared/bench.db`)
- [ ] Listens on a configurable port via env var `PORT` (default: 3000)
- [ ] JSON request/response bodies
- [ ] `cabal build` succeeds (or `nix-build` if a nix expression is provided)

### US-004: Autocannon Benchmark Scripts

**Description:** As a developer, I want autocannon scripts that stress-test both REST apps under identical conditions so that I get comparable numbers.

**Acceptance Criteria:**
- [ ] Script at `benchmarks/scripts/run-benchmarks.sh`
- [ ] Accepts env vars: `HASKELL_URL` (default `http://localhost:3000`), `DOTNET_URL` (default `http://localhost:5000`), `DURATION` (default 30s), `CONNECTIONS` (default 100), `PIPELINING` (default 10)
- [ ] Runs the following scenarios against both apps: (1) GET single user by ID (random IDs 1-10000), (2) GET paginated list (`?page=1&limit=20`), (3) POST new user, (4) Mixed: 70% GET single, 10% GET list, 10% POST, 5% PUT, 5% DELETE
- [ ] Each scenario runs autocannon with the specified duration, connections, and pipelining
- [ ] Collects output as JSON (autocannon's `-j` flag)
- [ ] Saves results to `benchmarks/results/standalone/` or `benchmarks/results/cluster/` depending on which Redis topology is active
- [ ] Prints summary table to stdout after all scenarios complete

### US-005: Standalone Redis Benchmark Run

**Description:** As a developer, I want to run the full benchmark suite against standalone Redis so that I have baseline numbers for both apps.

**Acceptance Criteria:**
- [ ] Uses `docker/docker-compose.yml` to start standalone Redis
- [ ] Seeds the database with `benchmarks/shared/seed` script
- [ ] Starts both REST apps (Haskell on port 3000, C# on port 5000)
- [ ] Runs `benchmarks/scripts/run-benchmarks.sh` with default settings
- [ ] Results saved to `benchmarks/results/standalone/`
- [ ] Both apps are stopped after the run
- [ ] A wrapper script `benchmarks/scripts/run-standalone.sh` automates the full sequence

### US-006: Redis Cluster (Host Networking) Benchmark Run

**Description:** As a developer, I want to run the full benchmark suite against a Redis Cluster using host networking so that I can compare cluster performance.

**Acceptance Criteria:**
- [ ] Uses `docker-cluster-host/docker-compose.yml` and `docker-cluster-host/make_cluster.sh` to start the cluster
- [ ] Seeds the database with `benchmarks/shared/seed` script
- [ ] Starts both REST apps in cluster mode (`REDIS_CLUSTER=true`, pointing at cluster node)
- [ ] Runs `benchmarks/scripts/run-benchmarks.sh`
- [ ] Results saved to `benchmarks/results/cluster/`
- [ ] Both apps are stopped after the run
- [ ] A wrapper script `benchmarks/scripts/run-cluster.sh` automates the full sequence

### US-007: Comparison Document

**Description:** As a developer, I want a comparison document that presents the benchmark results with explanations for the performance differences so that I understand the tradeoffs between the two libraries.

**Acceptance Criteria:**
- [ ] Markdown document at `benchmarks/results/COMPARISON.md`
- [ ] Contains: (1) Test setup description (hardware, Redis version, Docker config, app config), (2) Results tables for standalone and cluster, each showing requests/sec, latency p50/p95/p99, and throughput for every scenario, (3) Analysis section explaining **why** the numbers differ — covering connection model (multiplexing vs connection pool), serialization approach, GHC runtime vs .NET CLR, thread model, GC behavior, etc., (4) Conclusions and recommendations
- [ ] All data sourced from the JSON result files in `benchmarks/results/`
- [ ] Includes methodology notes (how many runs, warm-up, etc.)

## 4. Functional Requirements

- **FR-1:** Both REST apps must expose identical endpoint paths and accept/return identical JSON shapes.
- **FR-2:** Both apps must use the same SQLite database file (or a copy seeded identically).
- **FR-3:** Cache key format must be identical: `user:{id}` for single-user lookups.
- **FR-4:** Cache TTL must be identical: 60 seconds.
- **FR-5:** Both apps must use the same Redis instance(s) — no separate Redis for each app.
- **FR-6:** Autocannon must hit both apps with the same concurrency, duration, and pipelining settings.
- **FR-7:** The Haskell app must use the `redis-client` library from this repository (not Hedis or another library).
- **FR-8:** The C# app must use `StackExchange.Redis` NuGet package.
- **FR-9:** Both apps must support standalone and cluster Redis modes via environment variable toggle.
- **FR-10:** The comparison document must include explanations for observed differences, not just raw numbers.

## 5. Non-Goals (Out of Scope)

- **Not** optimizing the redis-client library itself in this feature (that's the existing prd.json's job).
- **Not** testing TLS connections (plaintext only for benchmarking simplicity).
- **Not** testing against Azure Managed Redis — local Docker only.
- **Not** building a UI or dashboard for results visualization.
- **Not** testing other Redis libraries (e.g., Hedis for Haskell, ServiceStack.Redis for C#).
- **Not** implementing authentication, authorization, or input validation beyond basic request parsing.
- **Not** implementing the `GET /users?page=&limit=` cache (only single-user GETs are cached; list queries always hit SQLite).

## 6. Design Considerations

### API Shape (both apps)

```
GET    /users/:id          → { id, name, email, bio, created_at }
GET    /users?page=1&limit=20 → [ { id, name, email, bio, created_at }, ... ]
POST   /users              ← { name, email, bio } → { id, name, email, bio, created_at }
PUT    /users/:id          ← { name, email, bio } → { id, name, email, bio, created_at }
DELETE /users/:id          → 204 No Content
```

### Cache-Aside Pattern

```
GET /users/:id:
  1. Check Redis for key "user:{id}"
  2. If hit → return cached JSON
  3. If miss → query SQLite → serialize to JSON → SET in Redis with EX 60 → return

POST/PUT /users/:id:
  1. Write to SQLite
  2. DEL "user:{id}" from Redis

DELETE /users/:id:
  1. DELETE from SQLite
  2. DEL "user:{id}" from Redis
```

### Haskell Web Framework

Use `warp` + `wai` for minimal overhead. Alternatively `scotty` if it simplifies routing. The goal is to keep the web layer thin so Redis library performance dominates.

### C# Framework

ASP.NET Core minimal API (`.NET 8`) — matches the Haskell app's lightweight approach.

## 7. Technical Considerations

- **SQLite concurrency:** SQLite uses file-level locking. Under heavy write load, this could become the bottleneck for both apps equally. Use WAL mode (`PRAGMA journal_mode=WAL`) to allow concurrent readers.
- **Haskell GHC RTS:** The Haskell app should use `-threaded -rtsopts "-with-rtsopts=-N"` to use all CPU cores.
- **Connection sharing:** Both apps should use a single Redis connection/multiplexer for standalone mode. For cluster mode, the Haskell app uses `MultiplexPool` and C# uses `ConnectionMultiplexer` with cluster enabled.
- **Warm-up:** Autocannon should include a short warm-up period (the first few seconds of each run) to avoid cold-start effects.
- **Docker host networking:** The Redis Cluster must use `docker-cluster-host/` (host networking) so that node addresses are reachable from the host where the apps run.
- **Deterministic seed data:** Both apps must use the same pre-seeded SQLite database to ensure identical cache hit/miss patterns.

## 8. Success Metrics

- Both REST apps build and run successfully against standalone and cluster Redis.
- Autocannon produces valid JSON results for all scenarios.
- The comparison document clearly shows requests/sec and latency for each scenario.
- The comparison document includes at least 3 substantive explanations for observed performance differences.
- The benchmark scripts are fully automated — a single script runs the entire pipeline end-to-end.

## 9. Open Questions

- Should we pin the number of GHC capabilities (`-N4`) to match .NET's thread pool, or let both runtimes auto-detect?
- Should we run multiple iterations and report averages, or is a single long run (60s+) sufficient?
- What size of value should we cache? The full JSON user object is small (~200 bytes). Should we add a larger `bio` field to test with bigger payloads?
