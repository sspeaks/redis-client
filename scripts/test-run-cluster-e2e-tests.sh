#! /usr/bin/env nix-shell
#! nix-shell -p bash coreutils gnugrep -i bash
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$REPO_ROOT/.cluster-e2e-timeout-regression-$$"

fail() {
  echo "Error: $*" >&2
  exit 1
}

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

[[ ! -e "$WORK_DIR" ]] || fail "refusing to reuse regression fixture $WORK_DIR"
mkdir -m 700 "$WORK_DIR"

FIXTURE="$WORK_DIR/fixture"
BIN_DIR="$FIXTURE/bin"
STATE_DIR="$FIXTURE/docker-state"
LOG_FILE="$FIXTURE/commands.log"
OUTPUT_FILE="$FIXTURE/runner.out"
ARCHIVE_FILE="$FIXTURE/e2e-image.tar"

mkdir -p "$BIN_DIR" "$STATE_DIR" "$FIXTURE/scripts" \
  "$FIXTURE/docker/cluster-e2e" "$FIXTURE/nix"
cp "$SCRIPT_DIR/run-cluster-e2e-tests.sh" "$FIXTURE/scripts/run-cluster-e2e-tests.sh"
chmod 700 "$FIXTURE/scripts/run-cluster-e2e-tests.sh"
: >"$FIXTURE/docker/cluster-e2e/docker-compose.yml"
: >"$FIXTURE/nix/cluster-e2e-docker.nix"
: >"$ARCHIVE_FILE"
: >"$LOG_FILE"

cat >"$BIN_DIR/nix-build" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf 'nix-build %s\n' "$*" >>"$STUB_LOG"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --argstr)
      case "$2" in
        imageName) printf '%s\n' "$3" >"$STUB_STATE/image-name" ;;
        imageOwner) printf '%s\n' "$3" >"$STUB_STATE/image-owner" ;;
      esac
      shift 3
      ;;
    *) shift ;;
  esac
done

printf '%s\n' "$STUB_ARCHIVE"
EOF

cat >"$BIN_DIR/timeout" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf 'timeout %s\n' "$*" >>"$STUB_LOG"
[[ "${1:-}" == "120" ]] || {
  echo "Unexpected cluster-create timeout: ${1:-<missing>}" >&2
  exit 97
}
shift

# Shorten only this disposable hung-command probe while exercising the
# production runner's 120-second timeout invocation.
exec "$REAL_TIMEOUT" 1 "$@"
EOF

cat >"$BIN_DIR/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf 'docker %s\n' "$*" >>"$STUB_LOG"

state_dir="$STUB_STATE"
image_name="$(cat "$state_dir/image-name" 2>/dev/null || true):latest"
image_owner="$(cat "$state_dir/image-owner" 2>/dev/null || true)"
image_id="sha256:owned-$image_owner"

if [[ "${1:-}" == "load" ]]; then
  cat >/dev/null
  touch "$state_dir/image-present"
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then
  if [[ -e "$state_dir/image-present" ]]; then
    printf '%s\n' "$image_id"
  fi
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  if [[ -e "$state_dir/image-present" ]]; then
    printf '%s\n' "$image_owner"
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "container" && "${2:-}" == "ls" ]] \
  || [[ "${1:-}" == "network" && "${2:-}" == "ls" ]] \
  || [[ "${1:-}" == "volume" && "${2:-}" == "ls" ]]; then
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "rm" ]]; then
  args=("$@")
  target="${args[${#args[@]} - 1]}"
  [[ "$target" == "$image_id" ]] || exit 98
  rm -f "$state_dir/image-present"
  touch "$state_dir/image-removed"
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  command_line=" $* "
  project_name=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == "--project-name" ]]; then
      project_name="$argument"
      break
    fi
    previous="$argument"
  done

  if [[ "$command_line" == *" up --detach "* ]]; then
    printf '%s\n' "$project_name" >"$state_dir/project-name"
    touch "$state_dir/compose-present"
    exit 0
  fi

  if [[ "$command_line" == *" ps --format json "* ]]; then
    printf '%s\n' '{"Health":"healthy"}'
    exit 0
  fi

  if [[ "$command_line" == *" exec -T redis1 redis-cli --cluster create "* ]]; then
    printf '%s\n' "$project_name" >"$state_dir/cluster-create-project"
    touch "$state_dir/cluster-create-entered"
    exec sleep 30
  fi

  if [[ "$command_line" == *" down --volumes --remove-orphans "* ]]; then
    rm -f "$state_dir/compose-present"
    touch "$state_dir/compose-removed"
    exit 0
  fi

  if [[ "$command_line" == *" ps "* || "$command_line" == *" logs "* ]]; then
    exit 0
  fi
fi

echo "Unsupported Docker invocation: $*" >&2
exit 99
EOF

chmod 700 "$BIN_DIR/nix-build" "$BIN_DIR/timeout" "$BIN_DIR/docker"

REAL_TIMEOUT="$(command -v timeout)"
[[ -n "$REAL_TIMEOUT" ]] || fail "GNU timeout is unavailable"

set +e
SECONDS=0
PATH="$BIN_DIR:$PATH" \
  STUB_ARCHIVE="$ARCHIVE_FILE" \
  STUB_LOG="$LOG_FILE" \
  STUB_STATE="$STATE_DIR" \
  REAL_TIMEOUT="$REAL_TIMEOUT" \
  /bin/bash "$FIXTURE/scripts/run-cluster-e2e-tests.sh" >"$OUTPUT_FILE" 2>&1
runner_status=$?
elapsed_seconds=$SECONDS
set -e

[[ "$runner_status" -eq 124 ]] ||
  fail "hung cluster creation returned $runner_status; expected timeout status 124"
[[ "$elapsed_seconds" -le 5 ]] ||
  fail "hung cluster creation exceeded the 1-second regression deadline ($elapsed_seconds seconds)"
grep -Fq -- "timeout 120 docker compose" "$LOG_FILE" ||
  fail "cluster creation did not invoke the production 120-second timeout"
[[ -e "$STATE_DIR/cluster-create-entered" ]] ||
  fail "hung cluster-create operation was not reached"
[[ -e "$STATE_DIR/compose-removed" && -e "$STATE_DIR/image-removed" ]] ||
  fail "EXIT cleanup did not remove both exact-owned fixture resources"
[[ ! -e "$STATE_DIR/compose-present" && ! -e "$STATE_DIR/image-present" ]] ||
  fail "exact-owned fixture resources survived timeout cleanup"

project_name="$(cat "$STATE_DIR/project-name")"
[[ "$project_name" =~ ^redis-client-cluster-e2e-[0-9a-f]{32}$ ]] ||
  fail "unexpected Compose ownership identity: $project_name"
[[ "$(cat "$STATE_DIR/cluster-create-project")" == "$project_name" ]] ||
  fail "cluster create and cleanup did not use the same Compose ownership identity"

printf '%s\n' \
  "Cluster E2E cluster-create timeout regression passed: status 124, 1-second probe deadline, exact-owned resources removed."
