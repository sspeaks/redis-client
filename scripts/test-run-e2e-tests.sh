#! /usr/bin/env nix-shell
#! nix-shell -p bash coreutils gnugrep gnumake -i bash
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

fail() {
  echo "Error: $*" >&2
  exit 1
}

create_fixture() {
  local name=$1
  local fixture="$WORK_DIR/$name"
  local bin_dir="$fixture/bin"

  mkdir -p \
    "$bin_dir" \
    "$fixture/scripts" \
    "$fixture/docker/standalone" \
    "$fixture/nix" \
    "$fixture/docker-state"
  cp "$SCRIPT_DIR/run-e2e-tests.sh" "$fixture/scripts/run-e2e-tests.sh"
  chmod 700 "$fixture/scripts/run-e2e-tests.sh"
  : >"$fixture/docker/standalone/docker-compose.yml"
  : >"$fixture/nix/e2e-docker.nix"

  cat >"$fixture/scripts/generate-test-tls-certs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "generate-certs" >>"$STUB_LOG"
if [[ "$STUB_PHASE" == "cert-failure" ]]; then
  exit 21
fi
cert_dir="$1/tls.stub"
mkdir -p "$cert_dir"
printf '%s\n' "$cert_dir"
EOF

  cat >"$fixture/scripts/test-tls-fixtures.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "test-tls-fixtures" >>"$STUB_LOG"
EOF

  cat >"$bin_dir/nix-build" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "nix-build $*" >>"$STUB_LOG"
if [[ "$STUB_PHASE" == "build-failure" ]]; then
  exit 23
fi
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --argstr)
      case "$2" in
        imageName) printf '%s\n' "$3" >"$STUB_ROOT/docker-state/image-name" ;;
        imageOwner) printf '%s\n' "$3" >"$STUB_ROOT/docker-state/image-owner" ;;
      esac
      shift 3
      ;;
    *) shift ;;
  esac
done
archive="$STUB_ROOT/e2e-image.tar"
: >"$archive"
printf '%s\n' "$archive"
EOF

  cat >"$bin_dir/nix-shell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="${!#}"
exec /bin/bash "$script"
EOF

  cat >"$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "docker $*" >>"$STUB_LOG"

state_dir="$STUB_ROOT/docker-state"
image_present="$state_dir/image-present"
image_name="$(cat "$state_dir/image-name" 2>/dev/null || true):latest"
image_owner="$(cat "$state_dir/image-owner" 2>/dev/null || true)"
image_id="sha256:owned-$image_owner"

if [[ "$1" == "load" ]]; then
  touch "$image_present"
  case "$STUB_PHASE" in
    load-failure) exit 24 ;;
    load-signal)
      kill -TERM "$PPID"
      exit 0
      ;;
  esac
  exit 0
fi

if [[ "$1" == "image" && "$2" == "ls" ]]; then
  if [[ "$STUB_PHASE" == "stale-image-collision" \
    && ! -e "$state_dir/load-attempted" ]]; then
    printf '%s\n' "sha256:stale-image"
  elif [[ -e "$image_present" ]]; then
    printf '%s\n' "$image_id"
  fi
  exit 0
fi

if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  target="${!#}"
  if [[ "$STUB_PHASE" == "stale-tag-collision" \
    && "$target" == "$image_name" && ! -e "$image_present" ]]; then
    printf '%s\n' "stale-owner"
    exit 0
  fi
  if [[ -e "$image_present" \
    && ( "$target" == "$image_name" || "$target" == "$image_id" ) ]]; then
    printf '%s\n' "$image_owner"
    exit 0
  fi
  exit 1
fi

if [[ "$1" == "container" && "$2" == "ls" ]]; then
  if [[ "$STUB_PHASE" == "stale-compose-collision" ]]; then
    printf '%s\n' "stale-container"
  fi
  exit 0
fi

if [[ "$1" == "network" && "$2" == "ls" ]]; then
  exit 0
fi

if [[ "$1" == "volume" && "$2" == "ls" ]]; then
  exit 0
fi

if [[ "$1" == "compose" && " $* " == *" up "* ]]; then
  case "$STUB_PHASE" in
    compose-start-failure) exit 25 ;;
    compose-failure|primary-and-cleanup-failure) exit 42 ;;
    signal)
      kill -TERM "$PPID"
      exit 0
      ;;
  esac
  exit 0
fi

if [[ "$1" == "compose" && " $* " == *" down "* ]]; then
  if [[ "$STUB_PHASE" == "primary-and-cleanup-failure" \
    || "$STUB_PHASE" == "success-cleanup-failure" ]]; then
    exit 33
  fi
  exit 0
fi

if [[ "$1" == "image" && "$2" == "rm" ]]; then
  if [[ "$STUB_PHASE" == "image-cleanup-failure" ]]; then
    exit 34
  fi
  if [[ "${3:-}" == "sha256:preexisting-image" \
    || "${3:-}" == "sha256:stale-image" ]]; then
    exit 88
  fi
  rm -f "$image_present"
  exit 0
fi

exit 99
EOF

  chmod 700 \
    "$fixture/scripts/generate-test-tls-certs.sh" \
    "$fixture/scripts/test-tls-fixtures.sh" \
    "$bin_dir/docker" \
    "$bin_dir/nix-build" \
    "$bin_dir/nix-shell"

  printf '%s\n' "$fixture"
}

run_runner() {
  local fixture=$1
  local phase=$2
  local output=$3
  local log=$4

  PATH="$fixture/bin:$PATH" \
    STUB_LOG="$log" \
    STUB_PHASE="$phase" \
    STUB_ROOT="$fixture" \
    /bin/bash "$fixture/scripts/run-e2e-tests.sh" \
    >"$output" 2>&1
}

assert_status() {
  local expected=$1
  local actual=$2
  local scenario=$3
  if [[ "$actual" -ne "$expected" ]]; then
    fail "$scenario returned $actual; expected $expected"
  fi
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" ||
    fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file=$1
  local unexpected=$2
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

assert_ordered() {
  local file=$1
  shift
  local previous=0
  local expected
  local line

  for expected in "$@"; do
    line="$(grep -n -F -m1 -- "$expected" "$file" | cut -d: -f1)"
    if [[ -z "$line" || "$line" -le "$previous" ]]; then
      fail "$file does not contain ordered entry: $expected"
    fi
    previous=$line
  done
}

assert_runtime_removed() {
  local fixture=$1
  if [[ -e "$fixture/docker/standalone/.runtime" ]]; then
    fail "standalone TLS runtime directory survived cleanup"
  fi
}

run_case() {
  local name=$1
  local phase=$2
  local expected_status=$3
  local fixture
  local output
  local log
  local status

  fixture="$(create_fixture "$name")"
  output="$fixture/output"
  log="$fixture/commands.log"
  : >"$log"

  set +e
  run_runner "$fixture" "$phase" "$output" "$log"
  status=$?
  set -e
  assert_status "$expected_status" "$status" "$name"
  assert_runtime_removed "$fixture"
  printf '%s\n' "$fixture"
}

fixture="$(run_case success success 0)"
assert_ordered "$fixture/commands.log" \
  "generate-certs" \
  "nix-build --no-out-link --argstr imageName redis-client-e2e-tests-" \
  "docker image ls --quiet --no-trunc --filter label=com.redis-client.e2e.owner=" \
  "docker load" \
  "docker image inspect --format" \
  "docker container ls --all --quiet --filter label=com.docker.compose.project=" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm sha256:owned-"
assert_contains "$fixture/commands.log" \
  "docker compose -p redis-client-standalone-e2e-"
assert_contains "$fixture/commands.log" "--argstr imageOwner"
assert_contains "$fixture/commands.log" ":latest"
assert_not_contains "$fixture/commands.log" "sha256:preexisting-image"
first_sequential_owner="$(cat "$fixture/docker-state/image-owner")"

fixture="$(run_case restarted-success success 0)"
second_sequential_owner="$(cat "$fixture/docker-state/image-owner")"
if [[ "$first_sequential_owner" == "$second_sequential_owner" ]]; then
  fail "sequential invocations reused ownership token $first_sequential_owner"
fi

fixture="$(run_case cert-failure cert-failure 1)"
assert_contains "$fixture/output" \
  "failed to generate ephemeral TLS credentials"
assert_not_contains "$fixture/commands.log" "nix-build"
assert_not_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" "docker compose"

fixture="$(run_case build-failure build-failure 23)"
assert_contains "$fixture/commands.log" \
  "nix-build --no-out-link --argstr imageName redis-client-e2e-tests-"
assert_not_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" "docker compose"

fixture="$(run_case load-failure load-failure 24)"
assert_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" " compose "
assert_contains "$fixture/commands.log" "docker image rm sha256:owned-"

fixture="$(run_case load-signal load-signal 143)"
assert_ordered "$fixture/commands.log" \
  "docker load" \
  "docker image rm sha256:owned-"
assert_not_contains "$fixture/commands.log" " compose "

fixture="$(run_case stale-image-collision stale-image-collision 1)"
assert_contains "$fixture/output" \
  "image identity already exists; refusing to adopt it"
assert_not_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" "docker image rm"
assert_not_contains "$fixture/commands.log" "docker compose"

fixture="$(run_case stale-tag-collision stale-tag-collision 1)"
assert_contains "$fixture/output" \
  "image identity already exists; refusing to adopt it"
assert_not_contains "$fixture/commands.log" "docker load"
assert_not_contains "$fixture/commands.log" "docker image rm"
assert_not_contains "$fixture/commands.log" "docker compose"

fixture="$(run_case stale-compose-collision stale-compose-collision 1)"
assert_contains "$fixture/output" \
  "Compose identity already exists; refusing to adopt it"
assert_contains "$fixture/commands.log" "docker image rm sha256:owned-"
assert_not_contains "$fixture/commands.log" " up --exit-code-from e2etests"
assert_not_contains "$fixture/commands.log" " down"

fixture="$(run_case compose-start-failure compose-start-failure 25)"
assert_ordered "$fixture/commands.log" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm sha256:owned-"

fixture="$(run_case compose-failure compose-failure 42)"
assert_ordered "$fixture/commands.log" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm sha256:owned-"

fixture="$(run_case primary-and-cleanup-failure primary-and-cleanup-failure 42)"
assert_contains "$fixture/output" \
  "failed to stop the standalone E2E Compose project (exit 33)"
assert_contains "$fixture/commands.log" \
  "docker image rm sha256:owned-"

fixture="$(run_case success-cleanup-failure success-cleanup-failure 33)"
assert_contains "$fixture/output" \
  "failed to stop the standalone E2E Compose project (exit 33)"
assert_contains "$fixture/commands.log" \
  "docker image rm sha256:owned-"

fixture="$(run_case image-cleanup-failure image-cleanup-failure 34)"
assert_contains "$fixture/output" \
  "failed to remove the standalone E2E image (exit 34)"

fixture="$(run_case signal signal 143)"
assert_ordered "$fixture/commands.log" \
  " up --exit-code-from e2etests" \
  " down" \
  "docker image rm sha256:owned-"

first_fixture="$(create_fixture concurrent-first)"
second_fixture="$(create_fixture concurrent-second)"
: >"$first_fixture/commands.log"
: >"$second_fixture/commands.log"
run_runner "$first_fixture" success \
  "$first_fixture/output" "$first_fixture/commands.log" &
first_pid=$!
run_runner "$second_fixture" success \
  "$second_fixture/output" "$second_fixture/commands.log" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
first_owner="$(cat "$first_fixture/docker-state/image-owner")"
second_owner="$(cat "$second_fixture/docker-state/image-owner")"
if [[ "$first_owner" == "$second_owner" ]]; then
  fail "concurrent invocations reused ownership token $first_owner"
fi
if [[ ! "$first_owner" =~ ^[0-9a-f]{32}$ \
  || ! "$second_owner" =~ ^[0-9a-f]{32}$ ]]; then
  fail "concurrent invocation token was not 128-bit lowercase hex"
fi
assert_runtime_removed "$first_fixture"
assert_runtime_removed "$second_fixture"

fixture="$(create_fixture make-propagation)"
cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
: >"$fixture/commands.log"
set +e
PATH="$fixture/bin:$PATH" \
  STUB_LOG="$fixture/commands.log" \
  STUB_PHASE="compose-failure" \
  STUB_ROOT="$fixture" \
  make --no-print-directory -C "$fixture" test-e2e \
  >"$fixture/make.out" 2>&1
make_status=$?
set -e
# GNU Make normalizes a failed recipe to status 2 but retains the exact runner
# status in its diagnostic, so CI still fails and the primary code is visible.
assert_status 2 "$make_status" "make test-e2e"
assert_contains "$fixture/make.out" "Error 42"
assert_contains "$fixture/commands.log" "test-tls-fixtures"
assert_contains "$fixture/commands.log" " up --exit-code-from e2etests"
assert_contains "$fixture/commands.log" " down"

printf '%s\n' "Standalone E2E runner exit and cleanup checks passed."
