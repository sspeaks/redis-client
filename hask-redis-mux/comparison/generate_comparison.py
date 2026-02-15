#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: [ ps.markdown ps.pygments ])"
"""
Generate a comprehensive comparison document between hask-redis-mux and
StackExchange.Redis.

Usage:
    python3 generate_comparison.py [connection-string]

Produces:
    comparison/output/comparison.md
    comparison/output/comparison.html
"""

import argparse
import importlib.machinery
import importlib.util
import json
import os
import socket
import subprocess
import sys
from pathlib import Path

# Resolve paths relative to this script
SCRIPT_DIR = Path(__file__).parent.resolve()
TEMPLATES_DIR = SCRIPT_DIR / "templates" / "sections"
OUTPUT_DIR = SCRIPT_DIR / "output"


def _log(msg: str) -> None:
    """Log progress to stderr."""
    print(f"[generate_comparison] {msg}", file=sys.stderr)


def _load_module(name: str, path: Path):
    """Dynamically load a Python module from a file path."""
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        loader = importlib.machinery.SourceFileLoader(name, str(path))
        spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _check_redis(host: str, port: int) -> bool:
    """Check if Redis is reachable."""
    try:
        with socket.create_connection((host, port), timeout=3):
            return True
    except (socket.error, OSError):
        return False


def _start_redis_docker() -> bool:
    """Try to start a Redis cluster via Docker using the project's cluster-host setup."""
    _log("Redis not reachable. Attempting to start cluster via Docker...")
    cluster_dir = SCRIPT_DIR.parent.parent / "docker" / "cluster-host"
    if not cluster_dir.exists():
        _log(f"Cluster docker dir not found at {cluster_dir}")
        return False

    make_cluster = cluster_dir / "make_cluster.sh"
    if not make_cluster.exists():
        _log(f"make_cluster.sh not found at {make_cluster}")
        return False

    try:
        result = subprocess.run(
            ["bash", str(make_cluster)],
            cwd=str(cluster_dir),
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            _log(f"Cluster start failed: {result.stderr.strip()}")
            return False

        _log("Redis cluster started via Docker (host networking, ports 7000-7004).")
        if _check_redis("localhost", 7000):
            return True

        _log("Redis cluster started but seed node not yet reachable.")
    except FileNotFoundError:
        _log("Docker or bash not found in PATH.")
    except subprocess.TimeoutExpired:
        _log("Cluster start timed out (120s).")
    except Exception as e:
        _log(f"Failed to start Redis cluster via Docker: {e}")
    return False


def _parse_conn_string(conn_str: str):
    """Parse host:port from connection string."""
    parts = conn_str.split(":")
    host = parts[0]
    port = int(parts[1]) if len(parts) > 1 else 6379
    return host, port


def load_section_templates():
    """Load all markdown section templates in order."""
    sections = {}
    for f in sorted(TEMPLATES_DIR.glob("*.md")):
        # Extract section number from filename (e.g., 01_executive_summary.md -> 01)
        name = f.stem
        sections[name] = f.read_text()
    return sections


def assemble_markdown(sections: dict, benchmark_md: str) -> str:
    """Assemble all sections into a single Markdown document."""
    parts = []

    # Title
    parts.append("# hask-redis-mux vs StackExchange.Redis: A Comprehensive Comparison\n")

    # Sections 01-05
    for key in sorted(sections.keys()):
        num = key.split("_")[0]
        if int(num) <= 5:
            parts.append(sections[key])
            parts.append("")

    # Section 6: Benchmarks
    parts.append(benchmark_md)
    parts.append("")

    # Sections 07-08
    for key in sorted(sections.keys()):
        num = key.split("_")[0]
        if int(num) >= 7:
            parts.append(sections[key])
            parts.append("")

    return "\n".join(parts)


def main():
    parser = argparse.ArgumentParser(
        description="Generate hask-redis-mux vs StackExchange.Redis comparison document"
    )
    parser.add_argument(
        "connection_string",
        nargs="?",
        default="localhost:7000",
        help="Redis connection string (default: localhost:7000 for cluster seed node)",
    )
    parser.add_argument(
        "--skip-benchmarks",
        action="store_true",
        help="Skip running benchmarks (use placeholder content)",
    )
    args = parser.parse_args()

    host, port = _parse_conn_string(args.connection_string)
    _log(f"Redis target: {host}:{port}")

    # Ensure output directory exists
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Load section templates
    _log("Loading section templates...")
    sections = load_section_templates()
    _log(f"Loaded {len(sections)} section templates")

    # Run benchmarks
    benchmark_md = ""
    chart_data = {}
    haskell_data = None
    csharp_data = None

    if args.skip_benchmarks:
        _log("Benchmarks skipped (--skip-benchmarks flag)")
        skip_reason = "Skipped via --skip-benchmarks flag"
    else:
        # Check Redis connectivity
        redis_available = _check_redis(host, port)
        if not redis_available:
            redis_available = _start_redis_docker()
            if redis_available:
                host, port = "localhost", 7000

        if not redis_available:
            _log("WARNING: Redis is not reachable. Benchmarks will be skipped.")
            skip_reason = f"Redis not reachable at {host}:{port}"
        else:
            skip_reason = None
            conn_str = f"{host}:{port}"

            # Load benchmark runner
            try:
                runner = _load_module("benchmark_runner", SCRIPT_DIR / "benchmark_runner.py")

                _log("Running Haskell benchmarks...")
                haskell_data = runner.run_haskell_benchmarks(conn_str)
                if haskell_data:
                    _log("Haskell benchmarks completed successfully.")
                else:
                    _log("Haskell benchmarks failed or skipped.")

                _log("Running C# benchmarks...")
                csharp_data = runner.run_csharp_benchmarks(conn_str)
                if csharp_data:
                    _log("C# benchmarks completed successfully.")
                else:
                    _log("C# benchmarks failed or skipped.")

            except Exception as e:
                _log(f"ERROR loading benchmark runner: {e}")
                skip_reason = f"Benchmark runner error: {e}"

    # Render Section 6
    _log("Rendering benchmark section...")
    try:
        tmpl = _load_module("benchmarks_tmpl",
                            TEMPLATES_DIR / "06_benchmarks.md.tmpl")
        if haskell_data or csharp_data:
            benchmark_md, chart_data = tmpl.render_benchmarks(haskell_data, csharp_data)
        else:
            benchmark_md, chart_data = tmpl.render_benchmarks(
                reason=skip_reason or "No benchmark data available"
            )
    except Exception as e:
        _log(f"ERROR rendering benchmarks: {e}")
        benchmark_md = f"# 6. Benchmark Results\n\n> Benchmarks could not be rendered: {e}\n"

    # Assemble full Markdown
    _log("Assembling Markdown document...")
    full_md = assemble_markdown(sections, benchmark_md)

    # Write Markdown output
    md_path = OUTPUT_DIR / "comparison.md"
    md_path.write_text(full_md)
    _log(f"Written: {md_path}")

    # Render HTML
    _log("Rendering HTML document...")
    try:
        renderer = _load_module("html_renderer", SCRIPT_DIR / "html_renderer.py")
        html = renderer.render_html(full_md, chart_data)
        html_path = OUTPUT_DIR / "comparison.html"
        html_path.write_text(html)
        _log(f"Written: {html_path}")
    except Exception as e:
        _log(f"ERROR rendering HTML: {e}")
        _log("Markdown output is still available.")

    _log("Done!")


if __name__ == "__main__":
    main()
