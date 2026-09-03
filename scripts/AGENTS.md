# Scripts Directory

## E2E Test Scripts

- `run-cluster-e2e-tests.sh` and `run-library-e2e-tests.sh` both `cd` into `docker/cluster/` to start the Redis cluster, then navigate back to root with `cd ../..` before running `nix-build`. If docker directory structure changes, update the navigation paths.
- `run-e2e-tests.sh` uses `-f` flag with absolute path (`$SCRIPT_DIR/docker/standalone/docker-compose.yml`) instead of `cd`, so it's less fragile to directory moves.
- All three scripts use `nix-shell` shebangs and require the `redis` package for `redis-cli`.
- Standalone TLS credentials are generated under `docker/standalone/.runtime/` with owner-only private-key permissions. They are test-only and must never be committed or reused.
- `test-compose-networking.sh` renders Compose JSON without starting containers and enforces loopback-only client publications, bridge networks, unpublished cluster-bus ports, and the host-network profile gate.
- `test-redis-loopback-connectivity.sh` owns the cluster Compose project for its duration. It refuses to run over existing project containers and verifies loopback/internal access plus rejection through a non-loopback host address.
- `docker/cluster-host/make_cluster.sh` is an explicit compatibility-only path. It requires `REDIS_CLIENT_ALLOW_HOST_NETWORK=1`; its Redis configs must remain bound to `127.0.0.1`.
