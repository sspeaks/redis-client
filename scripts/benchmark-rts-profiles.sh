#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
wrapper="$repo_root/scripts/run-with-rts-profile.sh"
output_path="${1:-$repo_root/docs/benchmarks/issue-76-rts-matrix.json}"
tmpdir="$(mktemp -d)"
raw_path="$tmpdir/raw.jsonl"
mkdir -p "$(dirname "$output_path")"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require cabal
require redis-server
require redis-cli
require python3
require /usr/bin/time

visible_caps() {
  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
    return
  fi

  if command -v nproc >/dev/null 2>&1; then
    nproc
    return
  fi

  printf '1\n'
}

clamp_caps() {
  local caps="$1"
  local max_caps="$2"

  if [[ "$caps" -lt 1 ]]; then
    caps=1
  fi

  if [[ "$caps" -gt "$max_caps" ]]; then
    caps="$max_caps"
  fi

  printf '%s\n' "$caps"
}

profile_caps() {
  local profile="$1"
  local caps

  case "$profile" in
    conservative)
      printf '1\n'
      ;;
    legacy-high-memory)
      visible_caps
      ;;
    fill-throughput)
      caps="$(clamp_caps "$(visible_caps)" 4)"
      printf '%s\n' "$caps"
      ;;
    fill-bounded)
      caps="$(clamp_caps "$(visible_caps)" 2)"
      printf '%s\n' "$caps"
      ;;
    *)
      printf '1\n'
      ;;
  esac
}

standalone_pid=''
cluster_pids=()
tunnel_pid=''

cleanup() {
  if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" 2>/dev/null; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi

  if [[ -n "$standalone_pid" ]] && kill -0 "$standalone_pid" 2>/dev/null; then
    kill "$standalone_pid" 2>/dev/null || true
    wait "$standalone_pid" 2>/dev/null || true
  fi

  if ((${#cluster_pids[@]} > 0)); then
    for pid in "${cluster_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      fi
    done
  fi

  rm -rf "$tmpdir"
}
trap cleanup EXIT

standalone_dir="$tmpdir/standalone"
mkdir -p "$standalone_dir"
cat >"$standalone_dir/redis.conf" <<EOF
save ""
appendonly no
bind 127.0.0.1
port 6391
tls-port 6392
tls-cert-file $repo_root/docker/standalone/certs/redis-server.crt
tls-key-file $repo_root/docker/standalone/certs/redis-server.key
tls-ca-cert-file $repo_root/docker/standalone/certs/redis-ca.crt
tls-dh-params-file $repo_root/docker/standalone/certs/redis.dh
tls-auth-clients no
protected-mode no
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
maxmemory-policy allkeys-lru
timeout 0
stop-writes-on-bgsave-error no
EOF

redis-server "$standalone_dir/redis.conf" >"$standalone_dir/server.log" 2>&1 &
standalone_pid="$!"
for _ in $(seq 1 50); do
  if redis-cli -p 6391 ping >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
redis-cli -p 6391 ping >/dev/null

cluster_dir="$tmpdir/cluster"
mkdir -p "$cluster_dir"
for port in 7000 7001 7002; do
  node_dir="$cluster_dir/$port"
  mkdir -p "$node_dir"
  cat >"$node_dir/redis.conf" <<EOF
save ""
appendonly no
bind 127.0.0.1
protected-mode no
port $port
dir $node_dir
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-announce-ip 127.0.0.1
cluster-announce-port $port
cluster-announce-bus-port $((port + 10000))
EOF
  redis-server "$node_dir/redis.conf" >"$node_dir/server.log" 2>&1 &
  cluster_pids+=("$!")
done

for port in 7000 7001 7002; do
  for _ in $(seq 1 50); do
    if redis-cli -p "$port" ping >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  redis-cli -p "$port" ping >/dev/null
done

printf 'yes\nyes\n' | redis-cli --cluster create \
  127.0.0.1:7000 \
  127.0.0.1:7001 \
  127.0.0.1:7002 \
  --cluster-replicas 0 >/dev/null

for _ in $(seq 1 50); do
  if redis-cli -p 7000 cluster info | grep -q "cluster_state:ok"; then
    break
  fi
  sleep 0.2
done
redis-cli -p 7000 cluster info | grep -q "cluster_state:ok"

cabal build redis-client >/dev/null
bin_path="$(cabal list-bin redis-client)"

run_stats_cmd() {
  local profile="$1"
  local scenario="$2"
  local iteration="$3"
  local throughput_unit="$4"
  local throughput_value="$5"
  shift 5

  local caps ghcrts flags_text stats_path stdout_path stderr_path elapsed_path
  caps="$(profile_caps "$profile")"
  flags_text="$("$wrapper" --print-flags "$profile")"
  ghcrts="-s"
  if [[ -n "$flags_text" ]]; then
    ghcrts="$flags_text -s"
  fi
  stats_path="$tmpdir/${scenario}-${profile}-${iteration}.stats"
  stdout_path="$tmpdir/${scenario}-${profile}-${iteration}.stdout"
  stderr_path="$tmpdir/${scenario}-${profile}-${iteration}.stderr"
  elapsed_path="$tmpdir/${scenario}-${profile}-${iteration}.elapsed"

  env GHCRTS="$ghcrts" /usr/bin/time -f "%e" -o "$elapsed_path" \
    "$@" >"$stdout_path" 2>"$stderr_path"

  cat "$stderr_path" >"$stats_path"

  python3 - "$raw_path" "$scenario" "$profile" "$iteration" "$throughput_unit" "$throughput_value" "$elapsed_path" "$stdout_path" "$stats_path" "$flags_text" "$caps" <<'PY'
import json
import pathlib
import re
import sys

raw_path, scenario, profile, iteration, throughput_unit, throughput_value, elapsed_path, stdout_path, stats_path, flags, caps = sys.argv[1:]
stats = pathlib.Path(stats_path).read_text()
stdout = pathlib.Path(stdout_path).read_text()
elapsed = float(pathlib.Path(elapsed_path).read_text().strip())

def grab(pattern, cast=float):
    match = re.search(pattern, stats)
    if not match:
        return None
    return cast(match.group(1).replace(",", ""))

mut = grab(r"MUT\s+time\s+([0-9.]+)s")
gc = grab(r"GC\s+time\s+([0-9.]+)s")
peak = grab(r"([0-9,]+)\s+bytes maximum residency", int)
alloc = grab(r"([0-9,]+)\s+bytes allocated in the heap", int)
alloc_rate = grab(r"Alloc rate\s+([0-9,]+)\s+bytes per MUT second", float)
record = {
    "scenario": scenario,
    "profile": profile,
    "iteration": int(iteration),
    "elapsed_sec": elapsed,
    "throughput_unit": throughput_unit or None,
    "throughput_value": None if throughput_value == "NA" else float(throughput_value),
    "stdout": stdout,
    "rts_flags": flags or "",
    "capabilities": int(caps),
    "bytes_allocated": alloc,
    "max_residency_bytes": peak,
    "alloc_rate_bytes_per_mut_sec": alloc_rate,
    "mut_cpu_sec": mut,
    "gc_cpu_sec": gc,
    "gc_cpu_pct": None if mut is None or gc is None or (mut + gc) == 0 else (gc / (mut + gc) * 100.0),
}
with open(raw_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

measure_tunnel() {
  local profile="$1"
  for iteration in 1 2 3 4 5; do
    local log_path="$tmpdir/tunnel-${profile}-${iteration}.log"
    local err_path="$tmpdir/tunnel-${profile}-${iteration}.err"
    local ready_path="$tmpdir/tunnel-${profile}-${iteration}.ready"
    local ping_elapsed_path="$tmpdir/tunnel-${profile}-${iteration}.ping"
    : >"$log_path"
    : >"$err_path"

    local caps flags_text ghcrts
    caps="$(profile_caps "$profile")"
    flags_text="$("$wrapper" --print-flags "$profile")"
    ghcrts="${flags_text:+$flags_text }"

    local start_ns
    start_ns="$(date +%s%N)"
    env GHCRTS="${ghcrts}" "$bin_path" tunn -h 127.0.0.1 -p 7000 -c --tunnel-mode smart >"$log_path" 2>"$err_path" &
    tunnel_pid="$!"

    python3 - "$log_path" "$ready_path" "$start_ns" <<'PY'
import pathlib
import sys
import time

log_path = pathlib.Path(sys.argv[1])
ready_path = pathlib.Path(sys.argv[2])
start_ns = int(sys.argv[3])
needle = "Smart proxy listening on localhost:6379"
deadline = time.time() + 15
while time.time() < deadline:
    if needle in log_path.read_text():
        elapsed = (time.time_ns() - start_ns) / 1_000_000_000
        ready_path.write_text(str(elapsed))
        sys.exit(0)
    time.sleep(0.05)
sys.exit(1)
PY

    python3 - "$ping_elapsed_path" <<'PY'
import pathlib
import subprocess
import sys
import time

start = time.perf_counter()
subprocess.run(["redis-cli", "-p", "6379", "ping"], check=True, stdout=subprocess.DEVNULL)
pathlib.Path(sys.argv[1]).write_text(str(time.perf_counter() - start))
PY
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    tunnel_pid=''

    python3 - "$raw_path" "$profile" "$iteration" "$ready_path" "$ping_elapsed_path" "$flags_text" "$caps" <<'PY'
import json
import pathlib
import sys

raw_path, profile, iteration, ready_path, ping_elapsed_path, flags_text, caps = sys.argv[1:]
elapsed = float(pathlib.Path(ready_path).read_text() if pathlib.Path(ready_path).exists() else "0")
ping_elapsed = float(pathlib.Path(ping_elapsed_path).read_text().strip())
record = {
    "scenario": "tunnel-smart-proxy",
    "profile": profile,
    "iteration": int(iteration),
    "elapsed_sec": elapsed,
    "throughput_unit": "ops/sec",
    "throughput_value": 1.0 / ping_elapsed if ping_elapsed > 0 else None,
    "stdout": "",
    "rts_flags": flags_text,
    "capabilities": int(caps),
    "bytes_allocated": None,
    "max_residency_bytes": None,
    "alloc_rate_bytes_per_mut_sec": None,
    "mut_cpu_sec": None,
    "gc_cpu_sec": None,
    "gc_cpu_pct": None,
    "tunnel_ping_elapsed_sec": ping_elapsed,
}
with open(raw_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
  done
}

profiles=(legacy-high-memory conservative fill-throughput)

for profile in "${profiles[@]}"; do
  for iteration in 1 2 3 4 5; do
    run_stats_cmd "$profile" "cli-startup-standalone" "$iteration" "ops/sec" "NA" \
      bash -lc "printf 'exit\n' | \"$bin_path\" cli -h 127.0.0.1 -p 6391"
    run_stats_cmd "$profile" "cli-ping-standalone" "$iteration" "ops/sec" "NA" \
      bash -lc "printf 'PING\nexit\n' | \"$bin_path\" cli -h 127.0.0.1 -p 6391"
    run_stats_cmd "$profile" "cli-startup-cluster" "$iteration" "ops/sec" "NA" \
      bash -lc "printf 'exit\n' | \"$bin_path\" cli -h 127.0.0.1 -p 7000 -c"
    run_stats_cmd "$profile" "cli-ping-cluster" "$iteration" "ops/sec" "NA" \
      bash -lc "printf 'PING\nexit\n' | \"$bin_path\" cli -h 127.0.0.1 -p 7000 -c"
  done

  run_stats_cmd "$profile" "fill-standalone" 1 "MiB/sec" "1024" \
    "$bin_path" fill -h 127.0.0.1 -p 6391 -f -d 1

  run_stats_cmd "$profile" "bench-cluster-mixed" 1 "ops/sec" "NA" \
    "$bin_path" bench -h 127.0.0.1 -p 7000 -c --duration 5 --operation mixed -n 4 --key-size 64 --value-size 64
done

run_stats_cmd "fill-bounded" "fill-standalone-bounded" 1 "MiB/sec" "1024" \
  "$bin_path" fill -h 127.0.0.1 -p 6391 -f -d 1 --pipeline 1024

measure_tunnel legacy-high-memory
measure_tunnel conservative
measure_tunnel fill-throughput

python3 - "$raw_path" "$output_path" <<'PY'
import json
import math
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
records = [json.loads(line) for line in raw_path.read_text().splitlines() if line.strip()]

def percentile(values, pct):
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)

grouped = {}
for record in records:
    grouped.setdefault((record["scenario"], record["profile"]), []).append(record)

summary = []
for (scenario, profile), rows in sorted(grouped.items()):
    elapsed = [row["elapsed_sec"] for row in rows if row.get("elapsed_sec") is not None]
    throughput = []
    for row in rows:
      value = row.get("throughput_value")
      unit = row.get("throughput_unit")
      if scenario == "fill-standalone" and value is not None and row.get("elapsed_sec"):
        throughput.append(value / row["elapsed_sec"])
      elif scenario == "fill-standalone-bounded" and value is not None and row.get("elapsed_sec"):
        throughput.append(value / row["elapsed_sec"])
      elif scenario == "bench-cluster-mixed":
        try:
          payload = json.loads(row.get("stdout", "").strip())
        except Exception:
          payload = {}
        ops = payload.get("ops_per_sec")
        if ops is not None:
          throughput.append(float(ops))
      elif scenario.startswith("cli-") and row.get("elapsed_sec"):
        throughput.append(1.0 / row["elapsed_sec"])
      elif value is not None:
        throughput.append(float(value))
    residency = [row["max_residency_bytes"] for row in rows if row.get("max_residency_bytes") is not None]
    alloc_rate = [row["alloc_rate_bytes_per_mut_sec"] for row in rows if row.get("alloc_rate_bytes_per_mut_sec") is not None]
    gc_cpu = [row["gc_cpu_pct"] for row in rows if row.get("gc_cpu_pct") is not None]
    tunnel_ping = [row["tunnel_ping_elapsed_sec"] for row in rows if row.get("tunnel_ping_elapsed_sec") is not None]
    summary.append({
        "scenario": scenario,
        "profile": profile,
        "samples": len(rows),
        "rts_flags": rows[0].get("rts_flags", ""),
        "capabilities": rows[0].get("capabilities"),
        "elapsed_p50_sec": percentile(elapsed, 0.50),
        "elapsed_p95_sec": percentile(elapsed, 0.95),
        "elapsed_p99_sec": percentile(elapsed, 0.99),
        "throughput_unit": rows[0].get("throughput_unit"),
        "throughput_p50": percentile(throughput, 0.50),
        "throughput_p95": percentile(throughput, 0.95),
        "throughput_p99": percentile(throughput, 0.99),
        "max_residency_bytes_peak": max(residency) if residency else None,
        "alloc_rate_bytes_per_mut_sec_p50": percentile(alloc_rate, 0.50),
        "gc_cpu_pct_p50": percentile(gc_cpu, 0.50),
        "tunnel_ping_p50_sec": percentile(tunnel_ping, 0.50),
        "tunnel_ping_p95_sec": percentile(tunnel_ping, 0.95),
        "tunnel_ping_p99_sec": percentile(tunnel_ping, 0.99),
    })

payload = {
    "methodology": {
        "profiles": {
            "legacy-high-memory": "-N -H1024M -A128m -n8m -qb",
            "conservative": "GHC RTS defaults (no -with-rtsopts)",
            "fill-throughput": "-N<visible capped at 4> -A64m -n4m -qb",
            "fill-bounded": "-N<visible capped at 2> -A16m -n4m -qb",
        },
        "scenarios": [
            "cli-startup-standalone",
            "cli-ping-standalone",
            "cli-startup-cluster",
            "cli-ping-cluster",
            "fill-standalone",
            "fill-standalone-bounded",
            "tunnel-smart-proxy",
            "bench-cluster-mixed",
        ],
    },
    "summary": summary,
    "raw": records,
}
output_path.write_text(json.dumps(payload, indent=2) + "\n")
print(output_path)
PY
