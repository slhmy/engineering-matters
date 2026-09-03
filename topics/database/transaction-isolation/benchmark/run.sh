#!/bin/sh
set -eu

work_dir="$(mktemp -d)"

cleanup() {
  docker compose down --volumes >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

psql_file() {
  file="$1"
  shift
  docker compose exec -T postgres psql \
    --username postgres \
    --dbname transaction_isolation \
    --set ON_ERROR_STOP=1 \
    "$@" \
    --file "/benchmark/$file"
}

psql_value() {
  docker compose exec -T postgres psql \
    --username postgres \
    --dbname transaction_isolation \
    --set ON_ERROR_STOP=1 \
    --tuples-only \
    --no-align \
    --command "$1"
}

show_logs_and_fail() {
  message="$1"
  shift
  printf 'FAILED: %s\n' "$message" >&2
  for log in "$@"; do
    printf '%s\n' "--- $log" >&2
    cat "$log" >&2
  done
  exit 1
}

run_repeated_read() {
  scenario="$1"
  isolation="$2"
  observed_barrier="$3"
  committed_barrier="$4"
  expected="$5"
  reader_log="$work_dir/$scenario-reader.log"
  writer_log="$work_dir/$scenario-writer.log"

  psql_value 'UPDATE account SET balance = 100 WHERE id = 1;' >/dev/null

  psql_file repeated-read-reader.sql \
    --set="scenario=$scenario" \
    --set="isolation=$isolation" \
    --set="observed_barrier=$observed_barrier" \
    --set="committed_barrier=$committed_barrier" >"$reader_log" 2>&1 &
  reader_pid=$!

  psql_file repeated-read-writer.sql \
    --set="observed_barrier=$observed_barrier" \
    --set="committed_barrier=$committed_barrier" >"$writer_log" 2>&1 &
  writer_pid=$!

  set +e
  wait "$reader_pid"
  reader_status=$?
  wait "$writer_pid"
  writer_status=$?
  set -e

  if [ "$reader_status" -ne 0 ] || [ "$writer_status" -ne 0 ]; then
    show_logs_and_fail "$scenario session failed" "$reader_log" "$writer_log"
  fi

  actual="$(grep '^RESULT|' "$reader_log" | paste -sd ',' -)"
  if [ "$actual" != "$expected" ]; then
    show_logs_and_fail "$scenario returned $actual, expected $expected" "$reader_log" "$writer_log"
  fi

  final_balance="$(psql_value 'SELECT balance FROM account WHERE id = 1;')"
  if [ "$final_balance" != "120" ]; then
    show_logs_and_fail "$scenario final balance was $final_balance, expected 120" "$reader_log" "$writer_log"
  fi

  printf '%s\n' "$actual"
  printf 'STATE|%s|final_balance=%s\n' "$scenario" "$final_balance"
}

run_write_skew() {
  scenario="$1"
  isolation="$2"
  barrier="$3"
  expect_serialization_failure="$4"
  alice_log="$work_dir/$scenario-alice.log"
  bob_log="$work_dir/$scenario-bob.log"

  psql_value 'UPDATE doctors SET on_call = true;' >/dev/null

  psql_file write-skew-session.sql \
    --set="scenario=$scenario" \
    --set="isolation=$isolation" \
    --set="barrier=$barrier" \
    --set="doctor=alice" >"$alice_log" 2>&1 &
  alice_pid=$!

  psql_file write-skew-session.sql \
    --set="scenario=$scenario" \
    --set="isolation=$isolation" \
    --set="barrier=$barrier" \
    --set="doctor=bob" >"$bob_log" 2>&1 &
  bob_pid=$!

  set +e
  wait "$alice_pid"
  alice_status=$?
  wait "$bob_pid"
  bob_status=$?
  set -e

  if [ "$expect_serialization_failure" = no ]; then
    if [ "$alice_status" -ne 0 ] || [ "$bob_status" -ne 0 ]; then
      show_logs_and_fail "$scenario expected both commits" "$alice_log" "$bob_log"
    fi
  else
    if ! { [ "$alice_status" -eq 0 ] && [ "$bob_status" -ne 0 ]; } && \
       ! { [ "$alice_status" -ne 0 ] && [ "$bob_status" -eq 0 ]; }; then
      show_logs_and_fail "$scenario expected exactly one failed session" "$alice_log" "$bob_log"
    fi

    failed_log="$alice_log"
    [ "$alice_status" -ne 0 ] || failed_log="$bob_log"
    if ! grep -Eq 'ERROR:  *40001:' "$failed_log"; then
      show_logs_and_fail "$scenario failure was not SQLSTATE 40001" "$alice_log" "$bob_log"
    fi
  fi

  on_call="$(psql_value 'SELECT count(*) FROM doctors WHERE on_call;')"
  states="$(psql_value "SELECT string_agg(name || '=' || on_call, ',' ORDER BY name) FROM doctors;")"

  if [ "$expect_serialization_failure" = no ] && [ "$on_call" != "0" ]; then
    show_logs_and_fail "$scenario had $on_call on-call doctors, expected 0" "$alice_log" "$bob_log"
  fi
  if [ "$expect_serialization_failure" = yes ] && [ "$on_call" != "1" ]; then
    show_logs_and_fail "$scenario had $on_call on-call doctors, expected 1" "$alice_log" "$bob_log"
  fi

  grep '^RESULT|' "$alice_log" || true
  grep '^RESULT|' "$bob_log" || true
  if [ "$expect_serialization_failure" = yes ]; then
    grep -E 'ERROR:  *40001:' "$failed_log"
  fi
  printf 'STATE|%s|%s|on_call=%s\n' "$scenario" "$states" "$on_call"
}

docker compose up -d --wait postgres
psql_file setup.sql

run_repeated_read \
  read_committed \
  'READ COMMITTED' \
  101 \
  102 \
  'RESULT|read_committed|first_balance=100,RESULT|read_committed|second_balance=120'

run_repeated_read \
  repeatable_read \
  'REPEATABLE READ' \
  103 \
  104 \
  'RESULT|repeatable_read|first_balance=100,RESULT|repeatable_read|second_balance=100'

run_write_skew read_committed_skew 'READ COMMITTED' 201 no
run_write_skew serializable_skew SERIALIZABLE 202 yes

printf '%s\n' 'PASS|all transaction-isolation assertions passed'
