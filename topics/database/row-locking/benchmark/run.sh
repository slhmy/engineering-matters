#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE="docker compose --file $SCRIPT_DIR/compose.yaml"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/row-locking.XXXXXX")
PIDS=""
FINISHED=0

cleanup() {
  set +e
  exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 2>/dev/null || true
  if [ "$FINISHED" -eq 0 ] && [ -n "$PIDS" ]; then
    kill $PIDS 2>/dev/null || true
    wait $PIDS 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

psql_exec() {
  # shellcheck disable=SC2086
  $COMPOSE exec -T postgres psql --username postgres --dbname row_locking --set ON_ERROR_STOP=1 "$@"
}

session() {
  app_name=$1
  shift
  # shellcheck disable=SC2086
  $COMPOSE exec -T -e "PGAPPNAME=$app_name" postgres \
    psql --username postgres --dbname row_locking --set ON_ERROR_STOP=1 "$@"
}

wait_for_activity() {
  app_name=$1
  condition=$2
  attempts=0
  while [ "$attempts" -lt 100 ]; do
    found=$(psql_exec --tuples-only --no-align --command \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$app_name' AND $condition);")
    [ "$found" = "t" ] && return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  echo "timed out waiting for session $app_name: $condition" >&2
  return 1
}

require_text() {
  file=$1
  pattern=$2
  description=$3
  if ! grep -Eq "$pattern" "$file"; then
    echo "missing expected $description in $file" >&2
    return 1
  fi
}

start_pipe_session() {
  fd=$1
  pipe=$2
  output=$3
  app_name=$4
  eval "exec $fd<>\"$pipe\""
  session "$app_name" < "$pipe" > "$output" 2>&1 &
  SESSION_PID=$!
  PIDS="$PIDS $SESSION_PID"
}

# shellcheck disable=SC2086
$COMPOSE up -d --wait
psql_exec --file /benchmark/setup.sql >/dev/null

printf '\n=== 1. Same row waits; different row proceeds ===\n'
mkfifo "$TMP_DIR/same-holder.pipe"
start_pipe_session 3 "$TMP_DIR/same-holder.pipe" "$TMP_DIR/same-holder.out" same-row-holder
same_holder_pid=$SESSION_PID
printf '\\i /benchmark/same-row-holder.sql\n' >&3
wait_for_activity same-row-holder "state = 'idle in transaction'"

session same-row-waiter --file /benchmark/same-row-waiter.sql > "$TMP_DIR/same-waiter.out" 2>&1 &
same_waiter_pid=$!
PIDS="$PIDS $same_waiter_pid"
wait_for_activity same-row-waiter "wait_event_type = 'Lock'"

session different-row --file /benchmark/different-row.sql > "$TMP_DIR/different-row.out" 2>&1
require_text "$TMP_DIR/different-row.out" '^[[:space:]]*2[[:space:]]*\|[[:space:]]*220[[:space:]]*$' 'different-row result'

# Keep the waiter blocked long enough to make the measured serialization visible.
sleep 1
printf 'COMMIT;\n\\q\n' >&3
exec 3>&-
wait "$same_holder_pid"
wait "$same_waiter_pid"
require_text "$TMP_DIR/same-waiter.out" 'same_row_wait_ms' 'same-row wait measurement'
psql_exec --command "SELECT id, balance FROM accounts ORDER BY id;"
grep -E 'same_row_wait_ms|^[[:space:]]*[0-9]+[[:space:]]*$' "$TMP_DIR/same-waiter.out"
grep -E 'different_row_balance|^[[:space:]]*2[[:space:]]*\|[[:space:]]*220[[:space:]]*$' "$TMP_DIR/different-row.out"

printf '\n=== 2. NOWAIT fails immediately on a locked row ===\n'
psql_exec --file /benchmark/reset-accounts.sql >/dev/null
mkfifo "$TMP_DIR/nowait-holder.pipe"
start_pipe_session 4 "$TMP_DIR/nowait-holder.pipe" "$TMP_DIR/nowait-holder.out" nowait-holder
nowait_holder_pid=$SESSION_PID
printf '\\i /benchmark/same-row-holder.sql\n' >&4
wait_for_activity nowait-holder "state = 'idle in transaction'"

if session nowait-probe --set VERBOSITY=verbose --file /benchmark/nowait.sql > "$TMP_DIR/nowait.out" 2>&1; then
  echo "NOWAIT unexpectedly acquired the locked row" >&2
  exit 1
fi
require_text "$TMP_DIR/nowait.out" '55P03:.*could not obtain lock on row' 'NOWAIT SQLSTATE 55P03'
grep -E '55P03:.*could not obtain lock on row|^Time:' "$TMP_DIR/nowait.out"
printf 'ROLLBACK;\n\\q\n' >&4
exec 4>&-
wait "$nowait_holder_pid"

printf '\n=== 3. SKIP LOCKED workers claim different jobs ===\n'
psql_exec --file /benchmark/reset-jobs.sql >/dev/null
mkfifo "$TMP_DIR/worker-one.pipe"
start_pipe_session 5 "$TMP_DIR/worker-one.pipe" "$TMP_DIR/worker-one.out" queue-worker-1
worker_one_pid=$SESSION_PID
printf '\\set worker worker-1\n\\i /benchmark/queue-worker.sql\n' >&5
wait_for_activity queue-worker-1 "state = 'idle in transaction'"

session queue-worker-2 --set worker=worker-2 --file /benchmark/queue-worker.sql --command COMMIT > "$TMP_DIR/worker-two.out" 2>&1
require_text "$TMP_DIR/worker-one.out" 'worker-1[^0-9]*1' 'worker 1 claim'
require_text "$TMP_DIR/worker-two.out" 'worker-2[^0-9]*2' 'worker 2 claim'
printf 'COMMIT;\n\\q\n' >&5
exec 5>&-
wait "$worker_one_pid"
grep -E 'worker-[12]|claimed_job' "$TMP_DIR/worker-one.out"
grep -E 'worker-[12]|claimed_job' "$TMP_DIR/worker-two.out"
psql_exec --command "SELECT id, status, claimed_by FROM jobs ORDER BY id;"

printf '\n=== 4. Opposite lock order deadlocks ===\n'
psql_exec --file /benchmark/reset-accounts.sql >/dev/null
mkfifo "$TMP_DIR/deadlock-a.pipe" "$TMP_DIR/deadlock-b.pipe"
start_pipe_session 6 "$TMP_DIR/deadlock-a.pipe" "$TMP_DIR/deadlock-a.out" deadlock-a
deadlock_a_pid=$SESSION_PID
start_pipe_session 7 "$TMP_DIR/deadlock-b.pipe" "$TMP_DIR/deadlock-b.out" deadlock-b
deadlock_b_pid=$SESSION_PID
printf '\\i /benchmark/deadlock-a-first.sql\n' >&6
printf '\\i /benchmark/deadlock-b-first.sql\n' >&7
wait_for_activity deadlock-a "state = 'idle in transaction'"
wait_for_activity deadlock-b "state = 'idle in transaction'"

printf '\\i /benchmark/deadlock-a-second.sql\n\\q\n' >&6
printf '\\i /benchmark/deadlock-b-second.sql\n\\q\n' >&7
exec 6>&- 7>&-
if wait "$deadlock_a_pid"; then deadlock_a_rc=0; else deadlock_a_rc=$?; fi
if wait "$deadlock_b_pid"; then deadlock_b_rc=0; else deadlock_b_rc=$?; fi

deadlock_count=0
if grep -Eq '40P01:.*deadlock detected' "$TMP_DIR/deadlock-a.out"; then deadlock_count=$((deadlock_count + 1)); fi
if grep -Eq '40P01:.*deadlock detected' "$TMP_DIR/deadlock-b.out"; then deadlock_count=$((deadlock_count + 1)); fi
if [ "$deadlock_count" -ne 1 ]; then
  echo "expected exactly one deadlock victim, found $deadlock_count" >&2
  exit 1
fi
if ! { [ "$deadlock_a_rc" -eq 0 ] && [ "$deadlock_b_rc" -eq 3 ]; } && \
   ! { [ "$deadlock_a_rc" -eq 3 ] && [ "$deadlock_b_rc" -eq 0 ]; }; then
  echo "unexpected deadlock session statuses: A=$deadlock_a_rc B=$deadlock_b_rc" >&2
  exit 1
fi
grep -E '40P01:.*deadlock detected' "$TMP_DIR/deadlock-a.out" "$TMP_DIR/deadlock-b.out" || true
final_balances=$(psql_exec --tuples-only --no-align --field-separator=, --command \
  "SELECT string_agg(balance::text, ',' ORDER BY id) FROM accounts;")
case "$final_balances" in
  110,210|200,300) ;;
  *) echo "unexpected balances after deadlock: $final_balances" >&2; exit 1 ;;
esac
psql_exec --command "SELECT id, balance FROM accounts ORDER BY id;"
printf 'deadlock victim count: %s (session exit statuses: A=%s, B=%s)\n' "$deadlock_count" "$deadlock_a_rc" "$deadlock_b_rc"

printf '\nAll row-locking scenarios passed.\n'
FINISHED=1
