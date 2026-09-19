#!/bin/sh
set -eu

ROWS="${1:-1000000}"
BATCH="${2:-100000}"

for value in "$ROWS" "$BATCH"; do
  case "$value" in
    *[!0-9]*|'')
      echo "usage: $0 [prefill-rows] [batch-rows]" >&2
      exit 2
      ;;
  esac
done

docker compose up -d --wait
docker compose exec -T postgres psql \
  --username postgres \
  --dbname table_growth \
  --set ON_ERROR_STOP=1 \
  --set rows="$ROWS" \
  --set batch="$BATCH" \
  --file /benchmark/writes.sql

echo ''
echo '5. Heap-only tuple updates by table'
docker compose exec -T postgres psql \
  --username postgres \
  --dbname table_growth \
  -c "SELECT c.relname, pg_stat_get_tuples_updated(c.oid) AS updates, pg_stat_get_tuples_hot_updated(c.oid) AS hot_updates FROM pg_class c WHERE c.relname IN ('update_default', 'update_fillfactor') ORDER BY c.relname;"
