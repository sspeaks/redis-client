#!/usr/bin/env python3
"""
Benchmark runner module for hask-redis-mux comparison.

Builds, runs, and collects results from both Haskell and C# benchmark programs.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional


BENCHMARKS_DIR = Path(__file__).parent / "benchmarks"
HASKELL_DIR = BENCHMARKS_DIR / "haskell"
CSHARP_DIR = BENCHMARKS_DIR / "csharp"


def _log(msg: str) -> None:
    """Log a message to stderr."""
    print(f"[benchmark_runner] {msg}", file=sys.stderr)


def _parse_rts_stats(stderr_output: str) -> Optional[dict]:
    """Parse GHC RTS stats from stderr output."""
    stats: dict = {}
    patterns = {
        "max_residency_bytes": r"(\d[\d,]*)\s+bytes maximum residency",
        "total_alloc_bytes": r"(\d[\d,]*)\s+bytes allocated in the heap",
        "gc_pause_max_ms": r"max pause\s+([\d.]+)\s*ms",
        "productivity_pct": r"Productivity\s+([\d.]+)%",
        "total_gc_time_s": r"GC\s+time\s+([\d.]+)s",
        "total_elapsed_s": r"Total\s+time\s+([\d.]+)s.*elapsed",
    }
    for key, pattern in patterns.items():
        m = re.search(pattern, stderr_output)
        if m:
            val_str = m.group(1).replace(",", "")
            stats[key] = float(val_str) if "." in val_str else int(val_str)

    return stats if stats else None


def run_haskell_benchmarks(connection_string: str) -> Optional[dict]:
    """
    Build and run the Haskell benchmark program.

    Args:
        connection_string: Redis connection string (host:port)

    Returns:
        Dict with benchmark results, or None on failure.
    """
    # Check for cabal
    cabal = shutil.which("cabal")
    if not cabal:
        _log("ERROR: cabal not found in PATH. Install GHC and Cabal to run Haskell benchmarks.")
        return None

    _log("Building Haskell benchmark...")
    try:
        build_result = subprocess.run(
            [cabal, "build"],
            cwd=str(HASKELL_DIR),
            capture_output=True,
            text=True,
            timeout=300,
        )
        if build_result.returncode != 0:
            _log(f"ERROR: Haskell benchmark build failed:\n{build_result.stderr}")
            return None
    except subprocess.TimeoutExpired:
        _log("ERROR: Haskell benchmark build timed out (300s)")
        return None
    except Exception as e:
        _log(f"ERROR: Failed to build Haskell benchmark: {e}")
        return None

    # Find the built executable
    _log("Finding Haskell benchmark executable...")
    try:
        list_result = subprocess.run(
            [cabal, "list-bin", "redis-benchmark"],
            cwd=str(HASKELL_DIR),
            capture_output=True,
            text=True,
            timeout=30,
        )
        if list_result.returncode != 0:
            _log(f"ERROR: Could not find benchmark binary:\n{list_result.stderr}")
            return None
        exe_path = list_result.stdout.strip()
    except Exception as e:
        _log(f"ERROR: Failed to locate benchmark binary: {e}")
        return None

    # Run the benchmark with RTS stats
    _log(f"Running Haskell benchmark against {connection_string}...")
    try:
        run_result = subprocess.run(
            [exe_path, connection_string],
            capture_output=True,
            text=True,
            timeout=600,
        )
        if run_result.returncode != 0:
            _log(f"ERROR: Haskell benchmark failed:\n{run_result.stderr}")
            return None
    except subprocess.TimeoutExpired:
        _log("ERROR: Haskell benchmark timed out (600s)")
        return None
    except Exception as e:
        _log(f"ERROR: Failed to run Haskell benchmark: {e}")
        return None

    # Parse JSON output from stdout
    try:
        benchmarks = json.loads(run_result.stdout)
    except json.JSONDecodeError as e:
        _log(f"ERROR: Failed to parse Haskell benchmark JSON output: {e}")
        _log(f"stdout was: {run_result.stdout[:500]}")
        return None

    # Parse RTS stats from stderr
    rts_stats = _parse_rts_stats(run_result.stderr)

    result = {
        "benchmarks": benchmarks,
        "memory": rts_stats,
        "language": "Haskell",
        "library": "hask-redis-mux",
    }

    _log("Haskell benchmarks complete.")
    return result


def run_csharp_benchmarks(connection_string: str) -> Optional[dict]:
    """
    Build and run the C# benchmark program.

    Args:
        connection_string: Redis connection string (host:port)

    Returns:
        Dict with benchmark results, or None on failure.
    """
    # Check for dotnet
    dotnet = shutil.which("dotnet")
    if not dotnet:
        _log("ERROR: dotnet not found in PATH. Install .NET SDK 8.0+ to run C# benchmarks.")
        return None

    _log("Building C# benchmark...")
    try:
        build_result = subprocess.run(
            [dotnet, "build", "-c", "Release", "--nologo"],
            cwd=str(CSHARP_DIR),
            capture_output=True,
            text=True,
            timeout=300,
        )
        if build_result.returncode != 0:
            _log(f"ERROR: C# benchmark build failed:\n{build_result.stderr}\n{build_result.stdout}")
            return None
    except subprocess.TimeoutExpired:
        _log("ERROR: C# benchmark build timed out (300s)")
        return None
    except Exception as e:
        _log(f"ERROR: Failed to build C# benchmark: {e}")
        return None

    # Run the benchmark
    _log(f"Running C# benchmark against {connection_string}...")
    try:
        run_result = subprocess.run(
            [dotnet, "run", "-c", "Release", "--no-build", "--", connection_string],
            cwd=str(CSHARP_DIR),
            capture_output=True,
            text=True,
            timeout=600,
        )
        if run_result.returncode != 0:
            _log(f"ERROR: C# benchmark failed:\n{run_result.stderr}")
            return None
    except subprocess.TimeoutExpired:
        _log("ERROR: C# benchmark timed out (600s)")
        return None
    except Exception as e:
        _log(f"ERROR: Failed to run C# benchmark: {e}")
        return None

    # Parse JSON output from stdout
    try:
        data = json.loads(run_result.stdout)
    except json.JSONDecodeError as e:
        _log(f"ERROR: Failed to parse C# benchmark JSON output: {e}")
        _log(f"stdout was: {run_result.stdout[:500]}")
        return None

    # Separate GC stats from benchmark data
    gc_stats = data.pop("gc", None)

    result = {
        "benchmarks": data,
        "memory": gc_stats,
        "language": "C#",
        "library": "StackExchange.Redis",
    }

    _log("C# benchmarks complete.")
    return result


CSHARP_REST_DIR = CSHARP_DIR / "RestServer"


def _wait_for_health(url: str, timeout: int = 15) -> bool:
    """Wait for a health endpoint to return 200."""
    import time
    import urllib.request
    import urllib.error

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            resp = urllib.request.urlopen(url, timeout=2)
            if resp.status == 200:
                return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(0.5)
    return False


def _run_rest_scenario(base_url: str, scenario: str, make_path,
                       num_requests: int = 500, num_threads: int = 8) -> Optional[dict]:
    """
    Run a single REST load test scenario against a server.

    Returns dict with p50/p95/p99/ops_per_sec, or None on failure.
    """
    import time
    import http.client
    import urllib.request
    from urllib.parse import urlparse
    from concurrent.futures import ThreadPoolExecutor, as_completed

    parsed = urlparse(base_url)
    host = parsed.hostname
    port = parsed.port or 80

    def _percentile(sorted_list: list, p: float) -> float:
        idx = max(0, min(len(sorted_list) - 1, int(p / 100.0 * len(sorted_list))))
        return sorted_list[idx]

    # Warmup: ensure backend connections (Redis, DB, etc.) are established
    _log("  Warming up server connections...")
    for i in range(10):
        try:
            urllib.request.urlopen(f"{base_url}/item/{i}", timeout=15).read()
        except Exception:
            time.sleep(1)
    time.sleep(1)

    # Pre-populate for cache_hit scenario
    if scenario == "cache_hit":
        try:
            urllib.request.urlopen(f"{base_url}/item/1", timeout=5).read()
        except Exception:
            pass

    def _run_thread_batch(thread_id: int) -> list:
        """Each thread uses a single keep-alive connection for its batch."""
        batch_latencies = []
        batch_size = num_requests // num_threads
        start_idx = thread_id * batch_size
        conn = http.client.HTTPConnection(host, port, timeout=3)
        try:
            for i in range(start_idx, start_idx + batch_size):
                try:
                    path = make_path(i)
                    t0 = time.perf_counter()
                    conn.request("GET", path)
                    resp = conn.getresponse()
                    resp.read()
                    elapsed_us = (time.perf_counter() - t0) * 1_000_000
                    if resp.status == 200:
                        batch_latencies.append(elapsed_us)
                except Exception:
                    # Reconnect on failure
                    try:
                        conn.close()
                    except Exception:
                        pass
                    conn = http.client.HTTPConnection(host, port, timeout=3)
        finally:
            conn.close()
        return batch_latencies

    latencies = []
    wall_start = time.perf_counter()

    with ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = [executor.submit(_run_thread_batch, t) for t in range(num_threads)]
        for future in as_completed(futures):
            try:
                latencies.extend(future.result())
            except Exception:
                pass

    wall_elapsed = time.perf_counter() - wall_start

    if not latencies:
        _log(f"  WARNING: No successful requests for {scenario}")
        return None

    latencies.sort()
    ops_per_sec = len(latencies) / wall_elapsed

    result = {
        "p50_us": round(_percentile(latencies, 50), 1),
        "p95_us": round(_percentile(latencies, 95), 1),
        "p99_us": round(_percentile(latencies, 99), 1),
        "ops_per_sec": round(ops_per_sec),
    }
    _log(f"  {scenario}: p50={result['p50_us']}us, ops/sec={result['ops_per_sec']}")
    return result


def run_haskell_rest_benchmarks(connection_string: str) -> Optional[dict]:
    """
    Build, start, load-test, and collect results from the Haskell REST server.

    Returns dict with 'cache_hit' and 'cache_miss' sub-dicts, or None on failure.
    """
    cabal = shutil.which("cabal")
    if not cabal:
        _log("ERROR: cabal not found, skipping Haskell REST benchmarks.")
        return None

    _log("Building Haskell REST server...")
    try:
        build_result = subprocess.run(
            [cabal, "build", "rest-server"],
            cwd=str(HASKELL_DIR),
            capture_output=True,
            text=True,
            timeout=300,
        )
        if build_result.returncode != 0:
            _log(f"ERROR: Haskell REST server build failed:\n{build_result.stderr}")
            return None
    except Exception as e:
        _log(f"ERROR: Failed to build Haskell REST server: {e}")
        return None

    # Find executable
    try:
        list_result = subprocess.run(
            [cabal, "list-bin", "rest-server"],
            cwd=str(HASKELL_DIR),
            capture_output=True,
            text=True,
            timeout=30,
        )
        if list_result.returncode != 0:
            _log(f"ERROR: Could not find rest-server binary:\n{list_result.stderr}")
            return None
        exe_path = list_result.stdout.strip()
    except Exception as e:
        _log(f"ERROR: Failed to locate rest-server binary: {e}")
        return None

    port = 3000
    _log(f"Starting Haskell REST server on port {port}...")
    server_proc = None
    try:
        server_proc = subprocess.Popen(
            [exe_path, "--port", str(port), "--redis", connection_string],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        if not _wait_for_health(f"http://localhost:{port}/health"):
            _log("ERROR: Haskell REST server failed to start (health check timeout)")
            return None

        _log("Haskell REST server ready, running load test...")
        results = {}
        for scenario, make_path in [
            ("cache_hit", lambda i: "/item/1"),
            ("cache_miss", lambda i: f"/item/{10000 + i}"),
        ]:
            data = _run_rest_scenario(f"http://localhost:{port}", scenario, make_path)
            if data:
                results[scenario] = data
        return results if results else None
    except Exception as e:
        _log(f"ERROR: Haskell REST benchmark failed: {e}")
        return None
    finally:
        if server_proc:
            server_proc.terminate()
            try:
                server_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server_proc.kill()


def _expand_cluster_endpoints(connection_string: str) -> str:
    """
    Expand a single cluster seed to all known cluster endpoints.

    SE.Redis connects faster and more reliably when given all cluster endpoints
    upfront, rather than discovering them from a single seed node.
    """
    host, port_str = connection_string.split(":")
    port = int(port_str)

    try:
        import socket
        # Try connecting to ports 7000-7004 (standard cluster-host setup)
        endpoints = []
        for p in range(7000, 7005):
            try:
                with socket.create_connection((host, p), timeout=1):
                    endpoints.append(f"{host}:{p}")
            except (socket.error, OSError):
                pass
        if len(endpoints) >= 3:
            return ",".join(endpoints)
    except Exception:
        pass

    return connection_string


def run_csharp_rest_benchmarks(connection_string: str) -> Optional[dict]:
    """
    Build, start, load-test, and collect results from the C# REST server.

    Returns dict with 'cache_hit' and 'cache_miss' sub-dicts, or None on failure.
    """
    dotnet = shutil.which("dotnet")
    if not dotnet:
        _log("ERROR: dotnet not found, skipping C# REST benchmarks.")
        return None

    _log("Building C# REST server...")
    try:
        build_result = subprocess.run(
            [dotnet, "build", "-c", "Release", "--nologo"],
            cwd=str(CSHARP_REST_DIR),
            capture_output=True,
            text=True,
            timeout=300,
        )
        if build_result.returncode != 0:
            _log(f"ERROR: C# REST server build failed:\n{build_result.stderr}\n{build_result.stdout}")
            return None
    except Exception as e:
        _log(f"ERROR: Failed to build C# REST server: {e}")
        return None

    port = 3001
    # Expand seed node to all cluster endpoints for faster connection setup
    cluster_conn = _expand_cluster_endpoints(connection_string)

    results = {}
    scenarios = [
        ("cache_hit", lambda i: "/item/1"),
        ("cache_miss", lambda i: f"/item/{10000 + i}"),
    ]

    for scenario, make_path in scenarios:
        _log(f"Starting C# REST server on port {port} for {scenario} (Redis: {cluster_conn})...")
        server_proc = None
        try:
            server_proc = subprocess.Popen(
                [dotnet, "run", "-c", "Release", "--no-build",
                 "--project", str(CSHARP_REST_DIR),
                 "--", "--port", str(port), "--redis", cluster_conn],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            if not _wait_for_health(f"http://localhost:{port}/health"):
                _log(f"ERROR: C# REST server failed to start for {scenario}")
                continue

            _log(f"C# REST server ready, running {scenario}...")
            data = _run_rest_scenario(f"http://localhost:{port}", scenario, make_path)
            if data:
                results[scenario] = data
        except Exception as e:
            _log(f"ERROR: C# REST {scenario} failed: {e}")
        finally:
            if server_proc:
                server_proc.terminate()
                try:
                    server_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server_proc.kill()

    return results if results else None


if __name__ == "__main__":
    conn = sys.argv[1] if len(sys.argv) > 1 else "localhost:6379"
    print("=== Haskell Benchmarks ===")
    h = run_haskell_benchmarks(conn)
    if h:
        print(json.dumps(h, indent=2))
    else:
        print("Haskell benchmarks skipped or failed.")

    print("\n=== C# Benchmarks ===")
    c = run_csharp_benchmarks(conn)
    if c:
        print(json.dumps(c, indent=2))
    else:
        print("C# benchmarks skipped or failed.")
