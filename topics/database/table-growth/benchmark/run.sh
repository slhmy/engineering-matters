#!/bin/sh
set -eu

EXPERIMENT="${1:-table-growth}"
ROWS="${2:-100000}"

# Keep the original ./run.sh 100000 form for the base experiment.
case "$EXPERIMENT" in
  *[!0-9]*) ;;
  *)
    ROWS="$EXPERIMENT"
    EXPERIMENT="table-growth"
    ;;
esac

case "$EXPERIMENT" in
  table-growth) SQL_FILE="table-growth.sql" ;;
  uuid-ids) SQL_FILE="uuid-ids.sql" ;;
  kth-largest) SQL_FILE="kth-largest.sql" ;;
  *)
    echo "usage: $0 {table-growth|uuid-ids|kth-largest} [row-count]" >&2
    exit 2
    ;;
esac

case "$ROWS" in
  *[!0-9]*|'')
    echo "usage: $0 {table-growth|uuid-ids|kth-largest} [row-count]" >&2
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
  --file "/benchmark/$SQL_FILE"
