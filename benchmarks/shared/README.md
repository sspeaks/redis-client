# Shared Benchmark Data

This directory contains the SQLite schema and seed script used by both the Haskell and C# benchmark apps.

## Files

- `schema.sql` — DDL for the `users` table
- `seed.py` — Python script that inserts 10,000 deterministic fake rows
- `bench.db` — Generated SQLite database (created by the seed script, not committed)

## Prerequisites

- Python 3.6+
- No external dependencies (uses only the standard library)

## Usage

```bash
# From the repository root:
python3 benchmarks/shared/seed.py

# Or with a custom database path:
SQLITE_DB=/tmp/mytest.db python3 benchmarks/shared/seed.py
```

Running the script multiple times is safe — it drops and recreates the table each time, producing identical data thanks to a fixed random seed.
