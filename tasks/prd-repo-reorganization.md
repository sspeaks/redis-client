# PRD: Repository File Reorganization

## Introduction

The `redis-client` repository is a Haskell monorepo containing two cabal packages: `redis-client` (CLI application) and `hask-redis-mux` (publishable library). Over time, significant file duplication has accumulated — the entire `lib/` directory and most test files exist as identical copies in both the root and `hask-redis-mux/` subdirectory. A redundant `data/` directory also exists at the root. This reorganization will eliminate duplication, clarify ownership of shared code, and make the project easier for new contributors to understand.

## Goals

- Eliminate duplicate source files between root `lib/` and `hask-redis-mux/lib/`
- Eliminate duplicate test files between root `test/` and `hask-redis-mux/test/`
- Remove the redundant root-level `data/` directory
- Consolidate Docker infrastructure directories under a single parent without breaking Makefile/CI references
- Keep the two-package structure (`redis-client` + `hask-redis-mux`) intact
- Keep Nix root-level files (`flake.nix`, `default.nix`, `shell.nix`) at the root per Nix convention; consolidate Docker image Nix configs in `nix/`
- Ensure `nix-build`, `cabal build`, and `make test` all continue to work after reorganization

## User Stories

### US-001: Eliminate duplicate lib/ source code
**Description:** As a contributor, I want a single source of truth for library code so that I don't have to update the same file in two places.

**Acceptance Criteria:**
- [ ] Library source code exists in exactly one location
- [ ] `hask-redis-mux.cabal` still resolves all `hs-source-dirs` correctly
- [ ] `redis-client.cabal` still builds correctly (it depends on `hask-redis-mux` as a library)
- [ ] `cabal build all` succeeds
- [ ] `nix-build` succeeds (if network available)

### US-002: Eliminate duplicate test files
**Description:** As a contributor, I want each test file to exist in only one place so that test changes are never accidentally lost or inconsistent.

**Acceptance Criteria:**
- [ ] Unit test files (`Spec.hs`, `ClusterSpec.hs`, `ClusterCommandSpec.hs`, `MultiplexerSpec.hs`, `FromRespSpec.hs`, `MultiplexPoolSpec.hs`) exist only in `hask-redis-mux/test/`
- [ ] E2E test files (`E2E.hs`, `ClusterE2E.hs`, `LibraryE2E.hs`, `E2EHelpers.hs`, `ClusterE2E/`, `LibraryE2E/`) remain in root `test/` (they belong to `redis-client`)
- [ ] `FillHelpersSpec.hs` remains in root `test/` (belongs to `redis-client`)
- [ ] Duplicate E2E files in `hask-redis-mux/test/` are removed (they are not referenced by `hask-redis-mux.cabal`)
- [ ] `cabal test all` succeeds — all test suites still discover their files
- [ ] `make test` succeeds

### US-003: Remove redundant root data/ directory
**Description:** As a contributor, I want to avoid confusion about which `data/` directory is canonical so that I know where to update reference data.

**Acceptance Criteria:**
- [ ] Root-level `data/` directory is removed
- [ ] `hask-redis-mux/data/cluster_slot_mapping.txt` remains (used by `embedFile` in `SlotMapping.hs`)
- [ ] `cabal build all` succeeds (no missing file errors)

### US-004: Consolidate Docker directories
**Description:** As a contributor, I want Docker infrastructure grouped together so it's easy to find and manage.

**Acceptance Criteria:**
- [ ] `docker/`, `docker-cluster/`, and `docker-cluster-host/` are moved under a single parent directory (e.g. `infra/` or `docker/`)
- [ ] All Makefile targets that reference Docker paths are updated
- [ ] All scripts (`scripts/*.sh`) that reference Docker paths are updated
- [ ] All Nix files (`nix/*.nix`) that reference Docker paths are updated
- [ ] CI workflows (`.github/`) that reference Docker paths are updated
- [ ] `make test` still works end-to-end

### US-005: Verify full build and test pipeline
**Description:** As a contributor, I want confidence that the reorganization didn't break anything.

**Acceptance Criteria:**
- [ ] `cabal build all` succeeds
- [ ] `cabal test all` succeeds
- [ ] `nix-build` succeeds (if network available; otherwise `cabal build` is sufficient)
- [ ] `make test` succeeds (if Docker/network available)
- [ ] No profiling artifacts or temp files left behind

## Functional Requirements

- FR-1: The canonical location for all library source code (`lib/resp/`, `lib/client/`, `lib/crc16/`, `lib/redis-command-client/`, `lib/cluster/`, `lib/redis/`) shall be the root `lib/` directory. `hask-redis-mux.cabal` shall reference these via relative paths (`../lib/resp`, etc.) from its `hs-source-dirs`.
- FR-2: The duplicate `hask-redis-mux/lib/` directory shall be removed entirely.
- FR-3: Unit test files owned by `hask-redis-mux` shall live in `hask-redis-mux/test/`. The `hask-redis-mux.cabal` `hs-source-dirs` for test components already point there.
- FR-4: E2E test files and the `FillHelpersSpec` owned by `redis-client` shall remain in root `test/`. Any duplicate E2E files in `hask-redis-mux/test/` shall be removed.
- FR-5: The root-level `data/` directory shall be deleted. The only canonical copy of `cluster_slot_mapping.txt` is `hask-redis-mux/data/cluster_slot_mapping.txt`.
- FR-6: Docker directories shall be consolidated under `docker/` as follows: `docker/standalone/` (was `docker/`), `docker/cluster/` (was `docker-cluster/`), `docker/cluster-host/` (was `docker-cluster-host/`).
- FR-7: All references to old Docker paths in `Makefile`, `scripts/`, `nix/`, and `.github/` shall be updated to reflect the new paths.
- FR-8: Nix root-level files (`flake.nix`, `default.nix`, `shell.nix`, `flake.lock`) shall remain at the repo root per Nix conventions. The `nix/` subdirectory continues to hold Docker image build configs.

## Non-Goals

- No changes to the two-package cabal structure (both `redis-client` and `hask-redis-mux` remain separate packages)
- No changes to source code logic, only file locations and build config paths
- No changes to the Haskell module hierarchy (`Database.Redis.*`)
- No renaming of cabal packages or executables
- No changes to the C FFI file (`lib/crc16/crc16.c`) beyond moving it if needed
- No merging of test suites — unit tests and E2E tests remain separate components

## Technical Considerations

- **`hs-source-dirs` in `hask-redis-mux.cabal`**: Currently set to `lib/resp`, `lib/client`, etc. After removing `hask-redis-mux/lib/`, these must change to `../lib/resp`, `../lib/client`, etc. Verify cabal supports relative paths outside the package directory.
- **`cabal.project`**: Already lists both packages (`./` and `hask-redis-mux/`). May need path updates if Docker Nix configs move.
- **`embedFile` in SlotMapping.hs**: Uses a path relative to the build directory. Since `hask-redis-mux/data/` is not moving, this should be unaffected.
- **C source file**: `hask-redis-mux.cabal` references `c-sources: lib/crc16/crc16.c`. After the lib dedup, this must become `../lib/crc16/crc16.c`.
- **Makefile**: Uses Docker Compose paths extensively. Every `docker-compose` invocation must be updated.
- **Git history**: Use `git mv` where possible to preserve file history.

## Success Metrics

- Zero duplicate source files between root and `hask-redis-mux/` directories
- All existing build commands (`cabal build all`, `nix-build`, `make test`) pass without modification to their invocation
- A new contributor can look at the directory tree and understand where library code, app code, tests, and infrastructure live without consulting documentation

## Open Questions

- Should `hask-redis-mux/` be renamed to something shorter (e.g. `mux/`) for convenience, or is the current name fine since it matches the Hackage package name?
- Are there any CI pipelines or external tooling (beyond `.github/`) that reference the current Docker paths?
- Should a `CONTRIBUTING.md` or updated `README.md` section be added to document the new project layout?
