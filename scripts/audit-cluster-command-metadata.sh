#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATED="${REPO_ROOT}/hask-redis-mux/lib/cluster/Database/Redis/Cluster/Commands/Generated.hs"
SCRATCH="${REPO_ROOT}/hask-redis-mux/data/redis-7.2/.generated"

mkdir -p "${SCRATCH}"

candidate_path="${SCRATCH}/Generated.candidate.hs"
canonical="$(cat "${GENERATED}")"
node "${REPO_ROOT}/scripts/generate-cluster-command-metadata.js" "${candidate_path}" >/dev/null
candidate="$(cat "${candidate_path}")"

if [[ "${canonical}" != "${candidate}" ]]; then
  echo "Audit failed: generated command artifact differs from canonical output." >&2
  exit 1
fi

mutated="${candidate/GeneratedCommandSpec \"ACL\"/GeneratedCommandSpec \"ACL_MUTATED\"}"
if [[ "${candidate}" == "${mutated}" ]]; then
  echo "Audit failed: deliberate routing-entry mutation did not change artifact." >&2
  exit 1
fi

echo "Cluster command metadata audit passed."
