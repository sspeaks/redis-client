#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ "${REDIS_CLIENT_ALLOW_HOST_NETWORK:-}" != "1" ]]; then
  cat >&2 <<'EOF'
Refusing to start the host-network Redis cluster by default.
Use docker/cluster for normal development and tests.

If host networking is specifically required, ensure no untrusted local users can
access the test ports, then opt in with:
  REDIS_CLIENT_ALLOW_HOST_NETWORK=1 ./docker/cluster-host/make_cluster.sh
EOF
  exit 1
fi

echo "WARNING: starting the explicit host-network Redis test cluster on loopback-only ports." >&2
docker compose --profile host-network up -d

NODES=(
  "127.0.0.1:7000"
  "127.0.0.1:7001"
  "127.0.0.1:7002"
  "127.0.0.1:7003"
  "127.0.0.1:7004"
)

# Wait for all nodes
for node in "${NODES[@]}"; do
  host="${node%:*}"
  port="${node#*:}"
  for i in $(seq 1 10); do
    if redis-cli -h "$host" -p "$port" ping 2>/dev/null | grep -q "PONG"; then
      echo "Node $node is ready."
      break
    fi
    echo "Waiting for node $node... ($i/10)"
    sleep 2
  done
done

sleep 2

echo "Creating Redis cluster on host network..."
redis-cli --cluster create "${NODES[@]}" --cluster-yes

echo "Redis cluster created successfully!"
