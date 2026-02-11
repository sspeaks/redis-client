#!/usr/bin/env bash
set -euo pipefail

# Benchmark comparison: StackExchange.Redis vs redis-client (Haskell)
# Runs both benchmarks for set, get, mixed workloads and prints a summary table.

# Defaults
HOST="localhost"
PORT="6379"
PASSWORD=""
TLS=false
DURATION=30
KEY_SIZE=16
VALUE_SIZE=256
CONNECTIONS=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run StackExchange.Redis and redis-client benchmarks side-by-side.

Options:
  --host HOST        Redis host (default: localhost)
  --port PORT        Redis port (default: 6379)
  --password PASS    Redis password (default: none)
  --tls              Enable TLS
  --duration SECS    Benchmark duration in seconds (default: 30)
  --key-size BYTES   Key size in bytes (default: 16)
  --value-size BYTES Value size in bytes (default: 256)
  --connections NUM  Number of multiplexer connections (default: 1)
  --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       HOST="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --password)   PASSWORD="$2"; shift 2 ;;
    --tls)        TLS=true; shift ;;
    --duration)   DURATION="$2"; shift 2 ;;
    --key-size)   KEY_SIZE="$2"; shift 2 ;;
    --value-size) VALUE_SIZE="$2"; shift 2 ;;
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --help)       usage; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTNET_DIR="${SCRIPT_DIR}/dotnet/RedisBenchmark"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"

# Locate the Haskell redis-client binary
REDIS_CLIENT=""
if command -v redis-client &>/dev/null; then
  REDIS_CLIENT="redis-client"
elif [[ -x "${SCRIPT_DIR}/../dist-newstyle/build/x86_64-linux/ghc-9.8.4/redis-client-0.5.0.0/x/redis-client/build/redis-client/redis-client" ]]; then
  REDIS_CLIENT="${SCRIPT_DIR}/../dist-newstyle/build/x86_64-linux/ghc-9.8.4/redis-client-0.5.0.0/x/redis-client/build/redis-client/redis-client"
else
  # Try to find any nix result link
  for r in "${SCRIPT_DIR}"/../result*/bin/redis-client; do
    if [[ -x "$r" ]]; then
      REDIS_CLIENT="$r"
      break
    fi
  done
fi

if [[ -z "${REDIS_CLIENT}" ]]; then
  echo "ERROR: Could not find redis-client binary. Build with nix-build or cabal build first." >&2
  exit 1
fi
echo "Using redis-client: ${REDIS_CLIENT}" >&2

# Build the C# benchmark if needed
echo "Building C# benchmark..." >&2
dotnet build "${DOTNET_DIR}" -c Release --nologo -v quiet >&2

# Build CLI args for each harness
build_dotnet_args() {
  local op="$1"
  local args=("--host" "${HOST}" "--port" "${PORT}" "--operation" "${op}" "--duration" "${DURATION}" "--key-size" "${KEY_SIZE}" "--value-size" "${VALUE_SIZE}" "--connections" "${CONNECTIONS}")
  if [[ -n "${PASSWORD}" ]]; then
    args+=("--password" "${PASSWORD}")
  fi
  if [[ "${TLS}" == "true" ]]; then
    args+=("--tls")
  fi
  echo "${args[@]}"
}

build_haskell_args() {
  local op="$1"
  local args=("bench" "-h" "${HOST}" "-p" "${PORT}" "--operation" "${op}" "--duration" "${DURATION}" "--key-size" "${KEY_SIZE}" "--value-size" "${VALUE_SIZE}" "-n" "${CONNECTIONS}" "-c")
  if [[ -n "${PASSWORD}" ]]; then
    args+=("-a" "${PASSWORD}")
  fi
  if [[ "${TLS}" == "true" ]]; then
    args+=("-t")
  fi
  echo "${args[@]}"
}

# Run a single benchmark and extract ops_per_sec from JSON output
run_dotnet_bench() {
  local op="$1"
  local args
  args=$(build_dotnet_args "${op}")
  echo "  Running C# ${op} benchmark..." >&2
  # shellcheck disable=SC2086
  dotnet run --project "${DOTNET_DIR}" -c Release --no-build -- ${args} 2>/dev/null
}

run_haskell_bench() {
  local op="$1"
  local args
  args=$(build_haskell_args "${op}")
  echo "  Running Haskell ${op} benchmark..." >&2
  # shellcheck disable=SC2086
  ${REDIS_CLIENT} ${args} 2>/dev/null
}

# Collect results for all operations
declare -A DOTNET_OPS HASKELL_OPS RATIOS
ALL_PASS=true
OPERATIONS=("set" "get" "mixed")

combined_results="[]"

for op in "${OPERATIONS[@]}"; do
  echo "=== ${op} workload ===" >&2

  dotnet_json=$(run_dotnet_bench "${op}")
  haskell_json=$(run_haskell_bench "${op}")

  dotnet_ops=$(echo "${dotnet_json}" | jq -r '.ops_per_sec')
  haskell_ops=$(echo "${haskell_json}" | jq -r '.ops_per_sec')

  DOTNET_OPS[${op}]="${dotnet_ops}"
  HASKELL_OPS[${op}]="${haskell_ops}"

  if (( $(echo "${dotnet_ops} > 0" | bc -l) )); then
    ratio=$(echo "scale=2; ${haskell_ops} * 100 / ${dotnet_ops}" | bc -l)
  else
    ratio="0"
  fi
  RATIOS[${op}]="${ratio}"

  # Check if ratio >= 90%
  if (( $(echo "${ratio} < 90" | bc -l) )); then
    ALL_PASS=false
  fi

  # Accumulate JSON results
  entry=$(jq -n \
    --arg op "${op}" \
    --argjson dotnet_ops "${dotnet_ops}" \
    --argjson haskell_ops "${haskell_ops}" \
    --arg ratio "${ratio}" \
    '{operation: $op, se_redis_ops_per_sec: $dotnet_ops, redis_client_ops_per_sec: $haskell_ops, ratio_pct: ($ratio | tonumber)}')
  combined_results=$(echo "${combined_results}" | jq --argjson e "${entry}" '. + [$e]')
done

# Save combined results
echo "${combined_results}" | jq '.' > "${RESULTS_DIR}/comparison.json"

# Print summary table
echo ""
echo "╔══════════════╦══════════════════════╦══════════════════════╦══════════╗"
echo "║  Operation   ║  SE.Redis (ops/sec)  ║  redis-client (ops)  ║  Ratio   ║"
echo "╠══════════════╬══════════════════════╬══════════════════════╬══════════╣"
for op in "${OPERATIONS[@]}"; do
  printf "║  %-10s  ║  %18s  ║  %18s  ║  %5s%%  ║\n" \
    "${op}" "${DOTNET_OPS[${op}]}" "${HASKELL_OPS[${op}]}" "${RATIOS[${op}]}"
done
echo "╚══════════════╩══════════════════════╩══════════════════════╩══════════╝"
echo ""
echo "Results saved to ${RESULTS_DIR}/comparison.json"

if [[ "${ALL_PASS}" == "true" ]]; then
  echo "✅ All workloads within 10% parity (ratio >= 90%)"
  exit 0
else
  echo "❌ Some workloads below 10% parity target (ratio < 90%)"
  exit 1
fi
