# Scripts Directory

## E2E Test Scripts

- `run-cluster-e2e-tests.sh` and `run-library-e2e-tests.sh` both `cd` into `docker/cluster/` to start the Redis cluster, then navigate back to root with `cd ../..` before running `nix-build`. If docker directory structure changes, update the navigation paths.
- `run-authenticated-cluster-e2e-tests.sh` owns a unique `docker/auth-cluster/` Compose project, joins the test image to its private bridge network, and must remove the project volumes and root `result` symlink on every exit.
- `run-e2e-tests.sh` uses `-f` flag with absolute path (`$SCRIPT_DIR/docker/standalone/docker-compose.yml`) instead of `cd`, so it's less fragile to directory moves.
- `run-e2e-tests.sh` atomically reserves a random 128-bit invocation token, labels the Nix-built image with that token, and preflights exact image and Compose identities before claiming them. Cleanup may remove only images with the exact ownership label and the exact reserved Compose project. It preserves the first build/load/test/signal failure while attempting all owned cleanup, and returns cleanup failure only when the primary path succeeded. Its focused regression is `test-run-e2e-tests.sh`. GNU Make reports the exact runner code in its recipe diagnostic and returns its standard status 2 for a failed target.
- All three scripts use `nix-shell` shebangs and require the `redis` package for `redis-cli`.
- Standalone TLS credentials are generated under `docker/standalone/.runtime/` with owner-only private-key permissions. They are test-only and must never be committed or reused.
- `test-compose-networking.sh` renders Compose JSON without starting containers and enforces loopback-only client publications, bridge networks, unpublished cluster-bus ports, and the host-network profile gate.
- `test-redis-loopback-connectivity.sh` owns the cluster Compose project for its duration. It refuses to run over existing project containers and verifies loopback/internal access plus rejection through a non-loopback host address.
- `docker/cluster-host/make_cluster.sh` is an explicit compatibility-only path. It requires `REDIS_CLIENT_ALLOW_HOST_NETWORK=1`; its Redis configs must remain bound to `127.0.0.1`.

## Software Factory

- `factory/setup-wizard.sh` is for the maintainer only; agents never run it. Everything above its `STAGES` marker is the wizard template, not hand-edited. Its steps are in `factory/setup_steps.py`, tested with a fake `gh`.
- Every factory job calls `factory/gate.py` first and again immediately before each publish or merge. Its module docstring defines the interface and the job and step names it counts; renaming one silently disables a limit. Run `make test-factory`.
- `factory/intake.py` decides which ticket may be worked; its module docstring defines the interface for publishing and ticket jobs and what a label event can prove. `factory/intake_github.py` is its read-only GitHub adapter and command line. Every label write by a factory job goes through `check_label_change` or `check_new_ticket_labels`, every comment through `render_factory_comment`, and ticket work calls `verify` immediately before publishing.
- Every script that calls GitHub with a token builds the request with `factory/github_http.api_request` and opens it with `open_api`, never `urlopen`: no redirects, no proxies, API host only.
- `factory/work.py` holds the decisions of `factory-work.yml`, the only workflow that works a ticket. Its docstring names the jobs and steps its failure count reads; renaming one changes what counts as a failure.
