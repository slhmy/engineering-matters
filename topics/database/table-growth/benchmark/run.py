#!/usr/bin/env python3
"""Run small, reproducible SQLite table-growth experiments."""

import argparse
import json
import os
import random
import sqlite3
import statistics
import tempfile
import time
from pathlib import Path


PAGE_SIZE = 50
LOOKUP_REPEATS = 200
PAGINATION_REPEATS = 30


def build_database(path: Path, rows: int) -> None:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA journal_mode = OFF")
    connection.execute("PRAGMA synchronous = OFF")
    connection.execute(
        "CREATE TABLE orders ("
        "id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL, "
        "created_at INTEGER NOT NULL, payload TEXT NOT NULL)"
    )

    randomizer = random.Random(42)
    batch = []
    for order_id in range(1, rows + 1):
        # A modest key space makes the lookup query return several rows.
        customer_id = randomizer.randrange(max(1, rows // 100))
        batch.append((order_id, customer_id, order_id, "x" * 80))
        if len(batch) == 10_000:
            connection.executemany("INSERT INTO orders VALUES (?, ?, ?, ?)", batch)
            batch.clear()
    if batch:
        connection.executemany("INSERT INTO orders VALUES (?, ?, ?, ?)", batch)
    connection.commit()
    connection.close()


def median_query_time(connection: sqlite3.Connection, sql: str, params: tuple, repeats: int) -> float:
    for _ in range(5):
        connection.execute(sql, params).fetchall()

    samples = []
    for _ in range(repeats):
        started = time.perf_counter_ns()
        connection.execute(sql, params).fetchall()
        samples.append((time.perf_counter_ns() - started) / 1_000)
    return statistics.median(samples)


def lookup_experiment(connection: sqlite3.Connection, rows: int) -> list[dict]:
    customer_id = (rows // 100) // 2
    query = "SELECT id, created_at, payload FROM orders WHERE customer_id = ?"
    results = []
    for indexed in (False, True):
        connection.execute("DROP INDEX IF EXISTS orders_customer_id")
        if indexed:
            connection.execute("CREATE INDEX orders_customer_id ON orders(customer_id)")
        connection.commit()
        plan = connection.execute("EXPLAIN QUERY PLAN " + query, (customer_id,)).fetchone()[3]
        results.append(
            {
                "experiment": "customer_lookup",
                "variant": "indexed" if indexed else "no_index",
                "median_us": median_query_time(connection, query, (customer_id,), LOOKUP_REPEATS),
                "query_plan": plan,
            }
        )
    return results


def pagination_experiment(connection: sqlite3.Connection, rows: int) -> list[dict]:
    connection.execute("CREATE INDEX IF NOT EXISTS orders_created_id ON orders(created_at, id)")
    connection.commit()
    offset = max(0, rows - PAGE_SIZE * 20)
    cursor = offset
    offset_query = "SELECT id, created_at FROM orders ORDER BY created_at, id LIMIT ? OFFSET ?"
    cursor_query = (
        "SELECT id, created_at FROM orders "
        "WHERE (created_at, id) > (?, ?) ORDER BY created_at, id LIMIT ?"
    )
    results = []
    for variant, query, params in (
        ("offset", offset_query, (PAGE_SIZE, offset)),
        ("cursor", cursor_query, (cursor, cursor, PAGE_SIZE)),
    ):
        plan = connection.execute("EXPLAIN QUERY PLAN " + query, params).fetchone()[3]
        results.append(
            {
                "experiment": "deep_pagination",
                "variant": variant,
                "median_us": median_query_time(connection, query, params, PAGINATION_REPEATS),
                "query_plan": plan,
                "position": offset,
            }
        )
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, default=100_000)
    parser.add_argument("--database", type=Path)
    parser.add_argument("--json", action="store_true", help="print machine-readable results")
    args = parser.parse_args()
    if args.rows < PAGE_SIZE:
        parser.error("--rows must be at least 50")

    temporary = args.database is None
    if args.database:
        database = args.database
    else:
        descriptor, temporary_path = tempfile.mkstemp(prefix="table-growth-", suffix=".db")
        os.close(descriptor)
        database = Path(temporary_path)
    database.parent.mkdir(parents=True, exist_ok=True)
    try:
        if database.exists():
            os.unlink(database)
        build_database(database, args.rows)
        connection = sqlite3.connect(database)
        results = lookup_experiment(connection, args.rows) + pagination_experiment(connection, args.rows)
        output = {"sqlite_version": sqlite3.sqlite_version, "rows": args.rows, "results": results}
        if args.json:
            print(json.dumps(output, indent=2))
        else:
            print(f"SQLite {output['sqlite_version']}, rows={args.rows}")
            for result in results:
                print(f"{result['experiment']:18} {result['variant']:10} {result['median_us']:10.1f} us  {result['query_plan']}")
        connection.close()
    finally:
        if temporary and database.exists():
            database.unlink()


if __name__ == "__main__":
    main()
