#!/bin/bash

# shellcheck disable=SC2046

docker load <$(nix build "github:sspeaks/nixos-config#garnet-image" --print-out-paths)
docker load <$(nix-build e2eDockerImg.nix)
docker-compose up --exit-code-from e2etests
docker-compose down
# shellcheck disable=SC2046
docker rmi $(docker images "e2etests:*" -q)
rm result
