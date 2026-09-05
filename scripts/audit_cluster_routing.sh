#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

cd "$REPO_ROOT"

scripts/generate_cluster_routing.py --check

SOURCE_SHA=$(grep -E '^redis72SourceSha = ' hask-redis-mux/lib/cluster/Database/Redis/Cluster/Commands/Generated.hs | sed -E 's/.*"([0-9a-f]+)"/\1/')
FORM_COUNT=$(grep -E '^generatedSupportedFormsCount = ' hask-redis-mux/lib/cluster/Database/Redis/Cluster/Commands/Generated.hs | awk '{print $3}')

printf 'Redis command source SHA: %s\n' "$SOURCE_SHA"
printf 'Generated command forms: %s\n' "$FORM_COUNT"
