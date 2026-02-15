# Scripts Directory

## E2E Test Scripts

- `run-cluster-e2e-tests.sh` and `run-library-e2e-tests.sh` both `cd` into `docker/cluster/` to start the Redis cluster, then navigate back to root with `cd ../..` before running `nix-build`. If docker directory structure changes, update the navigation paths.
- `run-e2e-tests.sh` uses `-f` flag with absolute path (`$SCRIPT_DIR/docker/standalone/docker-compose.yml`) instead of `cd`, so it's less fragile to directory moves.
- All three scripts use `nix-shell` shebangs and require the `redis` package for `redis-cli`.
