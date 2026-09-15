# RTS profiles

Issue #76 replaces the old global `-N -H1024M -A128m -n8m -qb` defaults with conservative executable and test settings, then keeps higher-throughput tuning explicit.

The fill path already starts from a 128 MiB shared noise buffer in `app/FillHelpers.hs`, and `defaultRunState` in `app/AppConfig.hs` still defaults the fill pipeline to `8192`. Those two facts make blanket high-memory RTS defaults a poor fit for CLI startup, tunnels, and test executables, but they still justify an opt-in profile for large fill and benchmark runs.

## Profiles

| Profile | Flags | Intended use |
| --- | --- | --- |
| `conservative` | GHC defaults (`-threaded -rtsopts`, no `-with-rtsopts`) | CLI, tests, tunnels, and small validation runs. |
| `fill-throughput` | `-N<visible capped at 4> -A64m -n4m -qb` | Opt-in fill / benchmark runs once the workload is known to benefit. |
| `fill-bounded` | `-N<visible capped at 2> -A16m -n4m -qb` | Memory-constrained local fill validation, paired with `-f` and a smaller pipeline. |
| `legacy-high-memory` | `-N -H1024M -A128m -n8m -qb` | Reproduction-only profile used in the benchmark matrix below. |

Run them with:

```sh
./scripts/run-with-rts-profile.sh fill-throughput -- \
  cabal run redis-client -- fill -h localhost -f -d 1
```

For bounded local test workloads, keep the flush and shrink the pipeline:

```sh
./scripts/run-with-rts-profile.sh fill-bounded -- \
  cabal run redis-client -- fill -h localhost -f -d 1 --pipeline 1024
```

## Reproducible matrix

Generate the lightweight matrix with:

```sh
make benchmark-rts
```

That script writes `docs/benchmarks/issue-76-rts-matrix.json` and covers:

1. CLI startup and a single `PING` in standalone and cluster modes.
2. Standalone fill (`-f -d 1`) plus a bounded fill run (`--pipeline 1024`).
3. Cluster smart-tunnel startup and tunnel `PING` latency.
4. Cluster benchmark mode (`bench --operation mixed --duration 5`).

The matrix intentionally stays lightweight enough to run in a developer environment. It records `+RTS -s` metrics where the process exits normally, and startup / ping latencies for tunnel mode where long-lived proxy processes do not emit comparable RTS summaries on forced shutdown.

## Measured run

The checked-in JSON was generated on a host with **20 visible CPUs**. The selected profile keeps the default executable/test path conservative, and makes the throughput-oriented profile explicit with a **4-capability cap** instead of the old blind `-N`.

| Scenario | Conservative | `fill-throughput` | Legacy high-memory | Takeaway |
| --- | --- | --- | --- | --- |
| CLI startup (standalone) | p50 0.00-0.01s, 74 KiB peak residency, 1 cap | p50 0.01s, 99 KiB peak residency, 4 caps | p50 0.05s, 254 KiB peak residency, 20 caps | The old global flags slow short-lived tools by roughly 4-5x for no user-visible gain. |
| Tunnel smart proxy | p50 17.1 ms startup, p50 4.68 ms tunnel ping | p50 15.3 ms startup, p50 4.41 ms tunnel ping | p50 65.6 ms startup, p50 4.95 ms tunnel ping | Tunnel startup pays the same blind-`-N` penalty; conservative and capped profiles stay responsive. |
| Standalone fill (`-f -d 1`) | 270 MiB/s, 136 MiB peak residency, 2.46% GC CPU | 284 MiB/s, 136 MiB peak residency, 0.61% GC CPU | 310 MiB/s, 140 MiB peak residency, 1.13% GC CPU | The capped profile keeps most of the fill throughput benefit while avoiding the container-hostile `-N`. |
| Bounded fill (`-f -d 1 --pipeline 1024`) | — | — | — | `fill-bounded` reached 243 MiB/s with 129 MiB peak residency and 0.65% GC CPU. |
| Cluster bench (`--operation mixed --duration 5`) | 411,805 ops/s, 243 KiB peak residency, 1 cap | 429,309 ops/s, 3.17 MiB peak residency, 4 caps | 436,761 ops/s, 3.27 MiB peak residency, 20 caps | `fill-throughput` closes most of the gap to the old peak-throughput setting while using one fifth of the capabilities. |

Those results are why the repo now uses **no baked-in high-memory RTS defaults** for executables or tests, keeps **`fill-throughput`** as the documented opt-in profile for benchmark and large fill runs, and keeps **`fill-bounded`** for local validation with `-f`.
