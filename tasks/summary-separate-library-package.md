# Separate Library Package (hask-redis-mux)

## Overview
The `hask-redis-mux` library has been extracted from the `redis-client` CLI into its own standalone Cabal package, publishable to Hackage independently. The CLI (`redis-client`) now depends on `hask-redis-mux` as an external library. This is a build-system-only change with zero runtime impact — performance profiling confirmed no regression.

## What's New

### Standalone Library Package
The core Redis multiplexing library (`hask-redis-mux`) is now a self-contained Haskell package located in the `hask-redis-mux/` subdirectory. It includes all six internal libraries (resp, client, crc16, redis-command-client, cluster, redis) and exposes a single public API via re-exported modules. The package is Hackage-ready: `cabal check` passes and `cabal sdist` produces a valid tarball.

### Simplified CLI Package
The `redis-client` CLI no longer bundles its own library stanzas. It depends on `hask-redis-mux` for all Redis functionality, making the CLI package focused solely on the application layer (CLI parsing, fill mode, cluster setup, tunneling).

### Multi-Package Build
Both packages build together seamlessly. `cabal build all`, `cabal test all`, `nix-build`, and all Makefile targets work with the two-package structure.

## How to Use

### Building
```bash
# Nix (preferred)
nix-build

# Cabal (inside nix-shell)
nix-shell --run 'cabal build all'

# Makefile
make build
```

### Running Tests
```bash
# All unit tests (4 suites across both packages)
make test-unit

# Full end-to-end (requires Docker)
make test

# Individual test suites
nix-shell --run 'cabal test hask-redis-mux:RespSpec'
nix-shell --run 'cabal test hask-redis-mux:ClusterSpec'
nix-shell --run 'cabal test hask-redis-mux:ClusterCommandSpec'
nix-shell --run 'cabal test redis-client:FillHelpersSpec'
```

### Using hask-redis-mux as a Library
Add `hask-redis-mux` to your `build-depends` in a `.cabal` file. All public modules from the `redis` internal library are re-exported from the default library:

```cabal
build-depends:
    hask-redis-mux
```

### Publishing to Hackage
```bash
cd hask-redis-mux
nix-shell --run 'cabal check'   # Verify package metadata
nix-shell --run 'cabal sdist'   # Produce tarball
# Upload dist-newstyle/sdist/hask-redis-mux-0.1.0.0.tar.gz to Hackage
```

## Technical Notes

- **Subdirectory layout**: Cabal does not support two `.cabal` files in the same directory. The library lives in `hask-redis-mux/` with symlinks (`lib`, `test`, `data`, `LICENSE`, `CHANGELOG.md`) pointing back to the repo root.
- **Nix integration**: Both `default.nix` and `flake.nix` use `callCabal2nixWithOptions` with `--subpath hask-redis-mux` to build the library package before `redis-client`.
- **Re-exported modules**: `hask-redis-mux` has a default (unnamed) library with `reexported-modules` so consumers can use a single `hask-redis-mux` dependency instead of referencing individual internal libraries.
- **No new dependencies**: The split is purely structural — no new Haskell dependencies were added.
- **Performance**: Fill-mode profiling confirmed identical hot-path cost centres and throughput within normal run-to-run variance (~2%). No runtime impact from the package split.
- **Hackage warnings**: `cabal check` reports missing upper bounds warnings, which are acceptable and do not block upload.
- **cabal.project**: Lists both packages via `packages: redis-client.cabal hask-redis-mux/`.

## Files Changed

### New Package (`hask-redis-mux/`)
- `hask-redis-mux/hask-redis-mux.cabal` — Full library package definition with 6 internal libraries, 3 test suites, Hackage metadata
- `hask-redis-mux/lib` — Symlink to `../lib`
- `hask-redis-mux/test` — Symlink to `../test`
- `hask-redis-mux/data` — Symlink to `../data`
- `hask-redis-mux/LICENSE` — Symlink to `../LICENSE`
- `hask-redis-mux/CHANGELOG.md` — Symlink to `../CHANGELOG.md`

### Build System
- `redis-client.cabal` — Removed all library stanzas and 3 test suites; executable and E2E tests now depend on `hask-redis-mux`
- `cabal.project` — Added `hask-redis-mux/` to packages list
- `default.nix` — Added `hask-redis-mux` overlay using `callCabal2nixWithOptions --subpath`
- `flake.nix` — Added `hask-redis-mux` overlay matching `default.nix` pattern
- `Makefile` — Updated `build`, `test-unit`, and `profile` targets to use `cabal build/test all`
