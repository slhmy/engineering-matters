#!/usr/bin/env python3
"""Standard-library-only layout experiment. Never contacts an external database."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
TABLES = ('rows_seq', 'rows_shuffled')


def row(i):
    return (i, (i * 7919) % 1000, hashlib.sha256(str(i).encode()).hexdigest() * 4)


def ids(n, shuffled):
    values = list(range(1, n + 1))
    if shuffled:
        values.sort(key=lambda i: hashlib.sha256(f'layout-2026:{i}'.encode()).digest())
    return values


def fingerprint(rows):
    # Canonical numeric PK order; no SQL ORDER BY is added to timed queries.
    values = sorted(rows, key=lambda r: int(r[0]))
    raw = ''.join('\t'.join(map(str, r)) + '\n' for r in values)
    return {'rows': len(values), 'sha256': hashlib.sha256(raw.encode()).hexdigest()}


def cases(n, width):
    lo = n // 2
    return {
        'pk_range_payload': (f'id >= {lo} AND id < {lo + width}', 'id, bucket, payload',
                             [row(i) for i in range(lo, lo + width)]),
        'secondary_payload': ('bucket = 42', 'id, bucket, payload',
                              [row(i) for i in range(1, n + 1) if (i * 7919) % 1000 == 42]),
        'secondary_covering': ('bucket = 42', 'id, bucket',
                               [row(i)[:2] for i in range(1, n + 1) if (i * 7919) % 1000 == 42]),
    }


def generate(out, n, width):
    manifest = {'rows': n, 'range_rows': width, 'payload_bytes': 256,
                'shuffle': 'ascending SHA256(layout-2026:<decimal id>)',
                'full_table': fingerprint(row(i) for i in range(1, n + 1)),
                'cases': {k: fingerprint(v[2]) for k, v in cases(n, width).items()}}
    for engine in ('pg', 'mysql'):
        with (out / f'{engine}-load.sql').open('w') as f:
            for table in TABLES:
                suffix = ' ENGINE=InnoDB' if engine == 'mysql' else ''
                f.write(f'CREATE TABLE {table} (id BIGINT PRIMARY KEY, bucket INTEGER NOT NULL, payload VARCHAR(256) NOT NULL){suffix};\n')
                # Build indexes before load: insertion history affects both structures.
                f.write(f'CREATE INDEX {table}_bucket_id ON {table} (bucket, id);\n')
                order = ids(n, table == 'rows_shuffled')
                for start in range(0, n, 1000):
                    vals = [row(i) for i in order[start:start+1000]]
                    f.write(f'INSERT INTO {table} (id,bucket,payload) VALUES\n')
                    f.write(',\n'.join(f"({i},{b},'{p}')" for i, b, p in vals) + ';\n')
            # Separate statements, outside a transaction: establish PG visibility map.
            for table in TABLES:
                f.write(f'VACUUM (ANALYZE) {table};\n' if engine == 'pg' else f'ANALYZE TABLE {table};\n')
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def run_cmd(cmd, **kwargs):
    p = subprocess.run(cmd, text=True, capture_output=True, **kwargs)
    if p.returncode:
        raise RuntimeError(f'Command failed: {shlex.join(cmd)}\n{p.stderr}\n{p.stdout}')
    return p.stdout


def metrics(engine, text):
    if engine == 'pg':
        plan = json.loads(text)[0]
        root = plan['Plan']
        return {'server_ms': plan['Execution Time'], 'root_rows': root['Actual Rows'],
                'root_loops': root['Actual Loops'], 'metric': 'pg_execution_time_ms'}
    # First iterator is the root. Keep raw plan; fail if output grammar changes.
    root_line = next((line for line in text.splitlines() if line.strip()), '')
    m = re.search(r'actual time=([\d.eE+-]+)\.\.([\d.eE+-]+) rows=([\d.eE+-]+) loops=(\d+)', root_line)
    if not m:
        raise ValueError('Could not parse MySQL root iterator; inspect saved plan')
    return {'server_ms': float(m[2]), 'root_rows': float(m[3]),
            'root_loops': int(m[4]), 'metric': 'mysql_root_iterator_last_row_ms'}


def execute(out, args, manifest):
    project = 'index-layout-' + uuid.uuid4().hex[:12]
    compose = ['docker', 'compose', '-p', project, '-f', str(ROOT / 'benchmark/compose.yaml')]
    # Deliberately no automatic volume deletion, including on failure.
    (out / 'project.txt').write_text(project + '\n')
    (out / 'stop-command.txt').write_text(shlex.join(compose + ['down']) + '\n')
    (out / 'delete-this-run-command.txt').write_text(shlex.join(compose + ['down', '--volumes']) + '\n')
    print(f'Results and diagnostics: {out}\nStop containers: {shlex.join(compose + ["down"])}', flush=True)
    run_cmd(['docker', 'info'])
    env = {'host': platform.platform(), 'python': sys.version, 'rows': args.rows,
           'repetitions': args.repetitions, 'warmups': args.warmups,
           'PG_IMAGE': os.getenv('PG_IMAGE', 'postgres:17'),
           'MYSQL_IMAGE': os.getenv('MYSQL_IMAGE', 'mysql:8.4'),
           'docker_version': run_cmd(['docker', 'version']),
           'docker_info': run_cmd(['docker', 'info']),
           'compose_config': run_cmd(compose + ['config'])}
    (out / 'environment.json').write_text(json.dumps(env, indent=2))
    run_cmd(compose + ['up', '-d', '--wait', '--wait-timeout', '240'])

    def sql(engine, query=None, path=None):
        if engine == 'pg':
            cmd = compose + ['exec', '-T', 'pg', 'psql', '-X', '-q', '-A', '-t',
                             '-F', '\t', '-v', 'ON_ERROR_STOP=1', '-U', 'lab', '-d', 'lab']
        else:
            cmd = compose + ['exec', '-T', '-e', 'MYSQL_PWD=disposable-lab-only',
                             'mysql', 'mysql', '-uroot', '--batch', '--raw',
                             '--skip-column-names', '--default-character-set=utf8mb4', 'lab']
        if path:
            with path.open() as f:
                return run_cmd(cmd, stdin=f)
        return run_cmd(cmd, input=query + '\n')

    versions = {}
    images = {}
    for engine in ('pg', 'mysql'):
        container = run_cmd(compose + ['ps', '-q', engine]).strip()
        images[engine] = run_cmd(['docker', 'inspect', '--format', '{{.Image}}', container]).strip()
        versions[engine] = sql(engine, 'SELECT version();')
        (out / f'{engine}-load.log').write_text(sql(engine, path=out / f'{engine}-load.sql'))
    (out / 'versions.json').write_text(json.dumps({'versions': versions, 'image_ids': images}, indent=2))
    pg_settings = "SELECT name, setting, unit FROM pg_settings WHERE name IN ('block_size','shared_buffers','effective_cache_size','random_page_cost','seq_page_cost','max_parallel_workers_per_gather','jit');"
    my_settings = "SHOW VARIABLES WHERE Variable_name IN ('innodb_page_size','innodb_buffer_pool_size','optimizer_switch','version','version_compile_machine');"
    (out / 'pg-settings.tsv').write_text(sql('pg', pg_settings))
    (out / 'mysql-settings.tsv').write_text(sql('mysql', my_settings))
    (out / 'pg-correlation.tsv').write_text(sql('pg', "SELECT tablename,attname,correlation FROM pg_stats WHERE tablename IN ('rows_seq','rows_shuffled') AND attname='id';"))
    (out / 'pg-sizes.tsv').write_text(sql('pg', "SELECT relname,pg_relation_size(relid),pg_indexes_size(relid),pg_total_relation_size(relid) FROM pg_stat_user_tables ORDER BY relname;"))
    (out / 'mysql-sizes.tsv').write_text(sql('mysql', "SELECT TABLE_NAME,DATA_LENGTH,INDEX_LENGTH FROM information_schema.tables WHERE TABLE_SCHEMA='lab' ORDER BY TABLE_NAME;"))
    checks = {}
    queries = {}
    for table in TABLES:
        for name, (predicate, projection, expected) in cases(args.rows, args.range_rows).items():
            queries[(table, name)] = f'SELECT {projection} FROM {table} WHERE {predicate};'
    (out / 'queries.sql').write_text('\n'.join(queries.values()) + '\n')
    for engine in ('pg', 'mysql'):
        for table in TABLES:
            actual = fingerprint(line.split('\t') for line in sql(engine, f'SELECT id,bucket,payload FROM {table};').splitlines())
            checks[f'{engine}/{table}/full_table'] = actual
            if actual != manifest['full_table']:
                raise AssertionError(f'Full table mismatch: {engine}/{table}')
        for (table, name), query in queries.items():
            actual = fingerprint(line.split('\t') for line in sql(engine, query).splitlines())
            checks[f'{engine}/{table}/{name}'] = actual
            if actual != manifest['cases'][name]:
                raise AssertionError(f'Result mismatch: {engine}/{table}/{name}')
    (out / 'verified-checksums.json').write_text(json.dumps(checks, indent=2))
    plans = out / 'plans'
    plans.mkdir()
    jobs = [(e, t, n) for e in ('pg', 'mysql') for t, n in queries]
    records = []
    schedule = []
    # A fixed seed randomizes round order, avoiding all PG measurements first.
    rng = random.Random(731)
    for round_no in range(-args.warmups, args.repetitions):
        rng.shuffle(jobs)
        for engine, table, name in jobs:
            query = queries[(table, name)]
            prefix = 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' if engine == 'pg' else 'EXPLAIN ANALYZE FORMAT=TREE '
            text = sql(engine, prefix + query)
            filename = f'{engine}-{table}-{name}-{round_no}.txt'
            (plans / filename).write_text(text)
            m = metrics(engine, text)
            # MySQL can round displayed row counts; exact SELECT hashes above
            # remain authoritative. PostgreSQL JSON preserves the exact count.
            wrong_rows = engine == 'pg' and m['root_rows'] != manifest['cases'][name]['rows']
            if wrong_rows or m['root_loops'] != 1:
                raise AssertionError(f'Unexpected root row count or loops: {filename}')
            schedule.append(filename)
            if round_no >= 0:
                records.append({'engine': engine, 'table': table, 'case': name, 'repeat': round_no, **m})
    (out / 'execution-order.json').write_text(json.dumps(schedule, indent=2))
    with (out / 'measurements.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    summary = []
    for engine, table, name in sorted(jobs):
        samples = [r['server_ms'] for r in records if (r['engine'], r['table'], r['case']) == (engine, table, name)]
        summary.append({'engine': engine, 'table': table, 'case': name,
                        'median_ms': statistics.median(samples), 'min_ms': min(samples),
                        'max_ms': max(samples), 'samples': len(samples)})
    (out / 'summary.json').write_text(json.dumps(summary, indent=2))
    (out / 'STATUS.txt').write_text('DATABASE RUN COMPLETED; checksums, root loops and PostgreSQL plan row counts verified.\nRead README caveats before comparing timings.\n')
    print(f'Results: {out}\nStop containers: {shlex.join(compose + ["down"])}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rows', type=int, default=100000)
    p.add_argument('--range-rows', type=int, default=1000)
    p.add_argument('--warmups', type=int, default=3)
    p.add_argument('--repetitions', type=int, default=10)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--run', action='store_true', help='Start isolated Docker containers and run the experiment')
    args = p.parse_args()
    if args.rows < 2000 or not 1 <= args.range_rows <= args.rows // 2 or args.warmups < 1 or args.repetitions < 2:
        p.error('Need rows>=2000, 1<=range-rows<=rows/2, warmups>=1, repetitions>=2')
    if args.run and not shutil.which('docker'):
        p.error('Docker is not installed/on PATH; no database tests ran. Generate without --run.')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'STATUS.txt').write_text('GENERATED ONLY; database execution not yet completed.\n')
    manifest = generate(out, args.rows, args.range_rows)
    if args.run:
        execute(out, args, manifest)
    else:
        print(f'Generated deterministic inputs: {out}; no database was run.')


if __name__ == '__main__':
    main()
