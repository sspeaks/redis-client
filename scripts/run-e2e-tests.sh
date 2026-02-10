#!/bin/bash

# shellcheck disable=SC2046
docker load <$(nix-build nix/e2e-docker.nix)
docker compose -f docker/docker-compose.yml up --exit-code-from e2etests
docker compose -f docker/docker-compose.yml down
# shellcheck disable=SC2046
docker rmi $(docker images "e2etests:*" -q) 2>/dev/null || true
rm -f result
