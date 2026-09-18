# Issue #63 release contract revision

- Cabal package versions remain authoritative and package-independent.
- Development changelogs use versioned `X.Y.Z.W -- Unreleased` entries; release tags require a dated top entry matching both Cabal and tag versions.
- Both package tag families create namespaced GitHub Releases with package-specific notes and source distributions.
- Only stable `redis-client` tags publish GHCR version, commit-SHA, and `latest` tags, using the locked flake Docker output.
- Redis `CLIENT SETINFO LIB-VER` is derived from Cabal's generated `VERSION_hask_redis_mux` metadata to stay aligned with `LIB-NAME hask-redis-mux`.
