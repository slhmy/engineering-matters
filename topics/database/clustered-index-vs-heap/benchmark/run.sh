#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
rows="${1:-100000}"
out="${2:-result/run-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
exec python3 code/lab.py --rows "$rows" --out "$out" --run
