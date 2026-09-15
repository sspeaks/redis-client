# Release process

This repository publishes two packages from one source tree:

| Package | Primary audience | Version source | Changelog | Release tag | Published artifacts |
| --- | --- | --- | --- | --- | --- |
| `redis-client` | CLI users and Docker consumers | `redis-client.cabal` | `CHANGELOG.md` | `redis-client-vX.Y.Z.W` | Git tag, source tree, `ghcr.io/sspeaks/redis-client` image |
| `hask-redis-mux` | Library consumers | `hask-redis-mux/hask-redis-mux.cabal` | `hask-redis-mux/CHANGELOG.md` | `hask-redis-mux-vX.Y.Z.W` | Git tag, source tree, Hackage upload |

## Version ownership

The CLI and library are versioned independently.

- Advance **only the package you changed** when the user-visible impact is
  confined to that package.
- Release **both packages from the same commit** only when one change set
  intentionally ships both the CLI and the library together.
- `hask-redis-mux` follows the Haskell PVP because it exposes a public API.
- `redis-client` versions the executable and Docker image together; the Docker
  image version is always the Cabal package version for that release.

## CI and release verification

Before a release tag can publish artifacts, CI validates:

1. each Cabal package name matches its expected manifest;
2. each package's latest changelog version heading matches its Cabal version;
3. the pushed release tag matches exactly one package and the same version; and
4. `redis-client` release jobs publish immutable Docker tags for the version and
   commit SHA.

Run the same checks locally with:

```sh
python3 scripts/check-release-metadata.py
python3 scripts/check-release-metadata.py \
  --release-tag redis-client-vX.Y.Z.W \
  --commit-sha "$(git rev-parse HEAD)" \
  --docker-tag X.Y.Z.W \
  --docker-tag "sha-$(git rev-parse --short=12 HEAD)" \
  --docker-tag latest \
  --allow-latest
```

## Release checklist

### For every release

1. Update the relevant package version in its `.cabal` file.
2. Update the package-specific changelog so the newest version heading exactly
   matches that version.
3. Review Cabal metadata (`synopsis`, `description`, `homepage`,
   `bug-reports`, `tested-with`, and `extra-doc-files`) for the package being
   released.
4. Review README and Haddock-facing examples for the released surface.
5. Run `nix-build` and `make test-release-metadata`. Run broader `make` targets
   as needed for the touched surface.

### Additional checks for `hask-redis-mux`

1. Review API compatibility against the previous release and choose the next
   PVP version accordingly.
2. Confirm public-module additions, removals, and typeclass changes are called
   out in `hask-redis-mux/CHANGELOG.md`.
3. Record whether the Hackage upload was completed, intentionally deferred, or
   blocked, and from which `hask-redis-mux-v...` tag it should be published.

### Additional checks for `redis-client`

1. Confirm the Nix outputs still build the CLI and Docker image from the same
   source commit.
2. Push the release tag `redis-client-vX.Y.Z.W`.
3. After CI completes, verify the image was published with:
   - `ghcr.io/sspeaks/redis-client:X.Y.Z.W`
   - `ghcr.io/sspeaks/redis-client:sha-<12-hex-commit>`
   - `ghcr.io/sspeaks/redis-client:latest` (only for an intentional CLI release)
4. Do not publish Docker artifacts from ordinary `main` pushes.
