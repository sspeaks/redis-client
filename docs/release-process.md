# Release process

This repository publishes two independently versioned packages:

| Package | Version source | Changelog | Release tag and GitHub Release | Published artifacts |
| --- | --- | --- | --- | --- |
| `redis-client` | `redis-client.cabal` | `CHANGELOG.md` | `redis-client-vX.Y.Z.W` | Cabal source distribution, Nix package, and `ghcr.io/sspeaks/redis-client` image |
| `hask-redis-mux` | `hask-redis-mux/hask-redis-mux.cabal` | `hask-redis-mux/CHANGELOG.md` | `hask-redis-mux-vX.Y.Z.W` | Cabal source distribution and manual Hackage upload |

## Version and changelog ownership

- Advance only the package whose user-visible behavior changed.
- Release both packages from one commit only when the change intentionally
  ships both surfaces.
- `hask-redis-mux` follows the Haskell PVP because it exposes a public API.
- During development, the first package changelog entry must be versioned as
  `## X.Y.Z.W -- Unreleased`, and `X.Y.Z.W` must equal that package's Cabal
  version. A generic `## Unreleased` heading is intentionally invalid because
  it cannot prove which future package version owns the changes.
- Before tagging, replace `Unreleased` with the release date in `YYYY-MM-DD`
  form. The tagged version, Cabal version, and first changelog entry must then
  agree exactly.

This prevents an old tag from publishing newer source content that is still
marked unreleased.

## Automated release behavior

Both namespaced tag families create a namespaced GitHub Release. The workflow
uses the tagged package's top changelog entry as release notes and attaches its
Cabal source distribution.

Only `redis-client-v...` tags publish Docker images. Docker builds use the
repository's committed `flake.nix` and `flake.lock` through
`nix build --no-update-lock-file --no-write-lock-file .#dockerImage`; release
automation cannot refresh or rewrite the lock and does not use a moving Nix
channel or the legacy `default.nix` entry point. Every CLI release pushes:

- `ghcr.io/sspeaks/redis-client:X.Y.Z.W`
- `ghcr.io/sspeaks/redis-client:sha-<12-hex-commit>`
- `ghcr.io/sspeaks/redis-client:latest`

The accepted tag grammar is a stable four-component version, so `latest` moves
only for a validated stable CLI release. Library tags never publish or retag
GHCR images.

`hask-redis-mux` publication to Hackage remains a deliberate manual step after
the namespaced GitHub Release succeeds.

## Validation

Run the repository and workflow-contract checks with:

```sh
make test-release-metadata
```

To validate a prepared CLI release:

```sh
python3 scripts/check-release-metadata.py \
  --release-tag redis-client-vX.Y.Z.W \
  --commit-sha "$(git rev-parse HEAD)" \
  --docker-tag X.Y.Z.W \
  --docker-tag "sha-$(git rev-parse --short=12 HEAD)" \
  --docker-tag latest \
  --allow-latest
```

To validate a prepared library release:

```sh
python3 scripts/check-release-metadata.py \
  --release-tag hask-redis-mux-vX.Y.Z.W
```

Release validation fails if the relevant top changelog entry is still
`Unreleased`, lacks a date, is empty, or disagrees with the Cabal version or
tag. The other package may remain independently unreleased.

## Release checklist

1. Update the relevant Cabal package version.
2. Add all user-visible changes to that package's versioned `Unreleased`
   changelog entry.
3. Run `nix-build`, `make test`, `cabal check`, and
   `cabal sdist pkg:<package>`.
4. Replace `Unreleased` with the release date.
5. Run `make test-release-metadata` and the package-specific tagged validation
   command above.
6. Push the corresponding namespaced tag.
7. Verify the namespaced GitHub Release contains the correct notes and source
   distribution.
8. For `redis-client`, verify all three GHCR tags. For `hask-redis-mux`, upload
   the exact GitHub Release source distribution to Hackage or record why the
   manual upload was deferred.
