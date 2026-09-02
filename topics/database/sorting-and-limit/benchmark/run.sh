#!/bin/sh
set -eu

ROWS="${1:-100000}"

case "$ROWS" in
  *[!0-9]*|'')
    echo "usage: $0 [row-count]" >&2
    exit 2
    ;;
esac

if [ "$ROWS" -lt 10000 ]; then
  echo "row count must be at least 10000" >&2
  exit 2
fi

docker compose up -d --wait postgres
docker compose exec -T postgres psql \
  --username postgres \
  --dbname sorting_and_limit \
  --set ON_ERROR_STOP=1 \
  --set rows="$ROWS" \
  --file /benchmark/run.sql
