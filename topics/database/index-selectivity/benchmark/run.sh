#!/bin/sh
set -eu

ROWS="${1:-100000}"

case "$ROWS" in
  100000|1000000)
    ;;
  *)
    echo "usage: $0 {100000|1000000}" >&2
    exit 2
    ;;
esac

docker compose up -d --wait
docker compose exec -T postgres psql \
  --username postgres \
  --dbname index_selectivity \
  --set ON_ERROR_STOP=1 \
  --set rows="$ROWS" \
  --file /benchmark/run.sql
