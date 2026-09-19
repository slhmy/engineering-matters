#!/bin/sh
set -eu

ROWS="${1:-100000}"

case "$ROWS" in
  *[!0-9]*|'')
    echo "usage: $0 [row-count]" >&2
    exit 2
    ;;
esac

PSQL="docker compose exec -T postgres psql --username postgres --dbname table_growth"
PGBENCH="docker compose exec -T -e PGPASSWORD=postgres postgres pgbench --host 127.0.0.1 --username postgres --dbname table_growth"

docker compose up -d --wait

# shellcheck disable=SC2086
$PSQL --set ON_ERROR_STOP=1 --set rows="$ROWS" --file /benchmark/concurrency-setup.sql

for mode in read write; do
  for clients in 1 8; do
    echo ''
    echo "### workload=$mode clients=$clients rows=$ROWS"
    # shellcheck disable=SC2086
    $PSQL -c 'SELECT pg_stat_reset();' >/dev/null
    # shellcheck disable=SC2086
    $PGBENCH --no-vacuum --client="$clients" --jobs="$clients" --time=5 --protocol=prepared \
      --define=rows="$ROWS" --file "/benchmark/pgbench-$mode.sql"
    # shellcheck disable=SC2086
    $PSQL -t -A -c "SELECT heap_blks_hit, heap_blks_read, idx_blks_hit, idx_blks_read FROM pg_statio_user_tables WHERE relname = 'bench_orders';"
  done
done
