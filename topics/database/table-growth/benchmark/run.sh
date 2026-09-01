#!/bin/sh
set -eu

ROWS="${1:-100000}"

case "$ROWS" in
  *[!0-9]*|'')
    echo "usage: $0 [positive-row-count]" >&2
    exit 2
    ;;
esac

if [ "$ROWS" -lt 1000 ]; then
  echo "row count must be at least 1000" >&2
  exit 2
fi

docker compose up -d --wait
docker compose exec -T postgres psql \
  --username postgres \
  --dbname table_growth \
  --set ON_ERROR_STOP=1 \
  --set rows="$ROWS" \
  --file /benchmark/run.sql
