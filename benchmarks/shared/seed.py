#!/usr/bin/env python3
"""Seed the SQLite database with 10,000 deterministic fake user rows."""

import os
import random
import sqlite3
import string

DB_PATH = os.environ.get("SQLITE_DB", os.path.join(os.path.dirname(__file__), "bench.db"))
SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")
NUM_USERS = 10_000
SEED = 42

FIRST_NAMES = [
    "Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Heidi",
    "Ivan", "Judy", "Karl", "Laura", "Mallory", "Niaj", "Olivia", "Pat",
    "Quentin", "Rupert", "Sybil", "Trent", "Ursula", "Victor", "Wendy",
    "Xander", "Yvonne", "Zach", "Amber", "Brian", "Chloe", "Derek",
]

LAST_NAMES = [
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
    "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
    "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin",
    "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez", "Clark",
    "Ramirez", "Lewis", "Robinson",
]

DOMAINS = ["example.com", "test.org", "bench.dev", "demo.net", "fake.io"]


def generate_bio(rng: random.Random) -> str:
    words = list(string.ascii_lowercase)
    length = rng.randint(5, 20)
    return " ".join(rng.choice(words) for _ in range(length))


def main() -> None:
    rng = random.Random(SEED)

    with sqlite3.connect(DB_PATH) as conn:
        # Drop and recreate schema (idempotent)
        with open(SCHEMA_PATH) as f:
            conn.executescript(f.read())

        rows = []
        for i in range(1, NUM_USERS + 1):
            first = rng.choice(FIRST_NAMES)
            last = rng.choice(LAST_NAMES)
            name = f"{first} {last}"
            domain = rng.choice(DOMAINS)
            email = f"user{i}@{domain}"
            bio = generate_bio(rng)
            # Deterministic timestamp based on id
            created_at = f"2025-01-{(i % 28) + 1:02d}T{(i % 24):02d}:{(i % 60):02d}:00"
            rows.append((i, name, email, bio, created_at))

        conn.executemany(
            "INSERT INTO users (id, name, email, bio, created_at) VALUES (?, ?, ?, ?, ?)",
            rows,
        )
        conn.commit()

    print(f"Seeded {NUM_USERS} users into {DB_PATH}")


if __name__ == "__main__":
    main()
