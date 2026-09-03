#! /usr/bin/env nix-shell
#! nix-shell -p bash gnugrep python3 -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  rm -rf -- "$WORK_DIR"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

export REDIS_TLS_CERT_DIR="$WORK_DIR/certs"
export REDIS_TLS_CERT_UID
export REDIS_TLS_CERT_GID
REDIS_TLS_CERT_UID="$(id -u)"
REDIS_TLS_CERT_GID="$(id -g)"

docker compose -f "$REPO_ROOT/docker/standalone/docker-compose.yml" \
  config --format json >"$WORK_DIR/standalone.json"
docker compose -f "$REPO_ROOT/docker/cluster/docker-compose.yml" \
  config --format json >"$WORK_DIR/cluster.json"
docker compose -f "$REPO_ROOT/docker/cluster-host/docker-compose.yml" \
  config --format json >"$WORK_DIR/cluster-host.json"

if docker compose -f "$REPO_ROOT/docker/cluster-host/docker-compose.yml" \
  config --services | grep -q .; then
  echo "Error: host-network services must require an explicit Compose profile." >&2
  exit 1
fi

python3 - "$WORK_DIR" "$REPO_ROOT" <<'PY'
import json
import pathlib
import sys

work_dir = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])


def load(name):
    with (work_dir / f"{name}.json").open(encoding="utf-8") as stream:
        return json.load(stream)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def assert_loopback_port(service, expected_port):
    ports = service.get("ports", [])
    require(len(ports) == 1, f"expected one published port, got {ports!r}")
    port = ports[0]
    require(port.get("host_ip") == "127.0.0.1", repr(port))
    require(int(port.get("published")) == expected_port, repr(port))
    require(int(port.get("target")) == expected_port, repr(port))
    require(port.get("protocol") == "tcp", repr(port))


standalone = load("standalone")
require(standalone["networks"]["default"]["driver"] == "bridge", "standalone network must use a bridge")
require("network_mode" not in standalone["services"]["redis"], "standalone Redis must not use host networking")
assert_loopback_port(standalone["services"]["redis"], 6379)

cluster = load("cluster")
cluster_network = next(iter(cluster["networks"].values()))
require(cluster_network["driver"] == "bridge", "cluster network must use a bridge")
expected_cluster_ports = {
    "redis1": 6379,
    "redis2": 6380,
    "redis3": 6381,
    "redis4": 6382,
    "redis5": 6383,
    "redis-standalone": 6390,
}
for name, expected_port in expected_cluster_ports.items():
    service = cluster["services"][name]
    require("network_mode" not in service, f"{name} must not use host networking")
    assert_loopback_port(service, expected_port)
    published = {int(port["target"]) for port in service.get("ports", [])}
    require(
        not any(16379 <= port <= 16383 for port in published),
        f"{name} publishes a cluster-bus port: {published!r}",
    )

cluster_host = load("cluster-host")
for name, service in cluster_host["services"].items():
    require(service.get("network_mode") == "host", f"{name} lost its compatibility network mode")
    require(service.get("profiles") == ["host-network"], f"{name} is not profile-gated")
    config = (repo_root / "docker" / "cluster-host" / f"{name}.conf").read_text(encoding="utf-8")
    bind_lines = [line.split() for line in config.splitlines() if line.startswith("bind ")]
    require(bind_lines == [["bind", "127.0.0.1"]], f"{name} must bind only to loopback")

print("Compose networking checks passed.")
PY
