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
