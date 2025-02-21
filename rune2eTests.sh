#!/bin/bash

docker load < $(nix-build e2eDockerImg.nix)
docker-compose up --exit-code-from e2etests
docker-compose down
docker rmi $(docker images "e2etests:*" -q)