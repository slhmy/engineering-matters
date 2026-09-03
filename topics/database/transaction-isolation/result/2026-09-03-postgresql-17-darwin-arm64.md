# Transaction isolation results

These are local observations from a deterministic concurrency lab. They demonstrate visibility and commit outcomes, not throughput or serialization-failure rates under production load.

## Environment

- Date: 2026-09-03
- Host: macOS 26.5.1 (build 25F80), Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Compose project: `transaction-isolation`
- Database: `transaction_isolation`
- Host port: `127.0.0.1:15440`
- Storage: Docker `tmpfs`
- Command: `./run.sh`
- Repetition: three consecutive complete runs

## Observations

All three runs passed every session-status and final-state assertion.

| Case | Session observations | Commit outcome | Final database state |
| --- | --- | --- | --- |
| Repeated read, `READ COMMITTED` | `first_balance=100`, `second_balance=120` | reader and writer committed | `final_balance=120` |
| Repeated read, `REPEATABLE READ` | `first_balance=100`, `second_balance=100` | reader and writer committed | `final_balance=120` |
| Write skew, `READ COMMITTED` | Alice and Bob each observed `on_call=2` | Alice and Bob committed | `alice=false,bob=false`, `on_call=0` |
| Write skew, `SERIALIZABLE` | Alice and Bob each observed `on_call=2` | one committed; one failed with `40001` | exactly one doctor on call |

A representative run ended its serializable case with Alice committed and Bob aborted:

```text
RESULT|serializable_skew|alice_observed_on_call=2
RESULT|serializable_skew|alice_commit=committed
RESULT|serializable_skew|bob_observed_on_call=2
psql:/benchmark/write-skew-session.sql:30: ERROR:  40001: could not serialize access due to read/write dependencies among transactions
STATE|serializable_skew|alice=false,bob=true|on_call=1
PASS|all transaction-isolation assertions passed
```

The other two recorded runs chose Alice as the serialization victim and ended with `alice=true,bob=false,on_call=1`. This scheduling variation is expected. The invariant and SQLSTATE were stable even though victim identity was not.

The `READ COMMITTED` write-skew result is the unsafe contrast: both transactions read committed data, updated separate rows, committed successfully, and left zero doctors on call. The serializable runs converted the dangerous concurrent outcome into one successful transaction and one retryable failure.

## Verification Notes

- Advisory-lock barriers forced both write-skew transactions to observe the initial two-doctor state before either update.
- The account writer committed before the reader's second query in both isolation cases.
- The runner accepted the serializable failure only when exactly one process failed and its output contained SQLSTATE `40001`.
- Exact account values and on-call counts were queried after each pair and compared with expected values.
- `sh -n benchmark/run.sh` completed successfully.
- The runner's exit trap removed the container, network, and temporary logs after each run; `docker compose ps --all` was empty afterward.

## Caveats

- Three runs verify repeatability on this host, not all possible operating-system schedules.
- The 10 ms barrier polling and 50 ms rendezvous hold are orchestration details, not measured database behavior.
- The tiny `tmpfs` dataset excludes durability latency, connection pooling, application retries, and sustained contention.
- Either serializable participant may receive `40001`; code must not rely on a particular victim.
