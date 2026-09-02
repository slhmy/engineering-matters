#!/bin/sh
set -eu

ROWS="${1:-100000}"

case "$ROWS" in
  *[!0-9]*|'')
    echo "usage: $0 [row-count]" >&2
    exit 2
    ;;
esac

if [ "$ROWS" -lt 10000 ] || [ "$ROWS" -gt 1000000 ]; then
  echo "row count must be between 10000 and 1000000" >&2
  exit 2
fi

docker compose up -d --wait mysql
docker compose exec -T -e MYSQL_PWD=root mysql mysql \
  --user=root \
  --database=composite_index_order \
  --init-command="SET @rows = $ROWS" \
  < sql/mysql.sql
