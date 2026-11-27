#!/usr/bin/env bash
# Start or stop the three-node Redis Cluster that benchmarks run against.
# Requires redis-server and redis-cli on PATH.
set -Eeuo pipefail

if [[ $# -ne 2 || ( "$1" != "start" && "$1" != "stop" ) ]]; then
  echo "usage: benchmark-cluster.sh start|stop DIRECTORY" >&2
  exit 2
fi

CLUSTER_ROOT="$2"
read -r -a PORTS <<<"${CLUSTER_PORTS:-7000 7001 7002}"

if [[ "$1" == "stop" ]]; then
  for port in "${PORTS[@]}"; do
    # Stop only servers this fixture started.
    if [[ -f "$CLUSTER_ROOT/$port/redis.pid" ]]; then
      redis-cli -h 127.0.0.1 -p "$port" shutdown nosave >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$CLUSTER_ROOT"
  exit 0
fi

mkdir -p "$CLUSTER_ROOT"
for port in "${PORTS[@]}"; do
  mkdir -p "$CLUSTER_ROOT/$port"
  cat >"$CLUSTER_ROOT/$port/redis.conf" <<EOF
bind 127.0.0.1
protected-mode no
port $port
save ""
appendonly no
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-announce-ip 127.0.0.1
cluster-announce-port $port
dir $CLUSTER_ROOT/$port
daemonize yes
pidfile $CLUSTER_ROOT/$port/redis.pid
logfile $CLUSTER_ROOT/$port/redis.log
EOF
  redis-server "$CLUSTER_ROOT/$port/redis.conf"
done

for port in "${PORTS[@]}"; do
  for attempt in $(seq 1 20); do
    if redis-cli -h 127.0.0.1 -p "$port" ping 2>/dev/null | grep -qx PONG; then
      break
    fi
    if [[ "$attempt" -eq 20 ]]; then
      echo "Error: Redis cluster node on port $port did not become ready." >&2
      exit 1
    fi
    sleep 0.5
  done
done

redis-cli --cluster create "${PORTS[@]/#/127.0.0.1:}" --cluster-yes >/dev/null

# Nodes agree on slots before each one starts serving them.
for port in "${PORTS[@]}"; do
  for attempt in $(seq 1 60); do
    if redis-cli -h 127.0.0.1 -p "$port" cluster info | grep -q '^cluster_state:ok'; then
      break
    fi
    if [[ "$attempt" -eq 60 ]]; then
      echo "Error: Redis cluster node on port $port is not serving its slots." >&2
      exit 1
    fi
    sleep 0.5
  done
done
