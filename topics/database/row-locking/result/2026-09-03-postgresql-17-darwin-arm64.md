# Row locking results

These are local observations of transaction state and outcomes. The displayed durations are not throughput measurements or universal latency claims.

## Environment

- Date: 2026-09-03
- Host: macOS 26.5.1, Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Compose project: `row-locking`
- Database and address: `row_locking` at `127.0.0.1:15441`
- Storage: Docker `tmpfs`
- Command: `./run.sh`
- Isolation and deadlock settings: PostgreSQL defaults (`READ COMMITTED`, default `deadlock_timeout`)

## Observations

| Scenario | Observed result |
| --- | --- |
| Same account row | The waiter was confirmed in `wait_event_type = 'Lock'`, then completed after 1,256 ms. Account 1 ended at 111, preserving the holder's `+1` and waiter's `+10`. |
| Different account row | Account 2 committed at 220 before the account-1 holder was released. |
| `NOWAIT` | The locking statement returned `55P03: could not obtain lock on row in relation "accounts"` in 0.386 ms locally. |
| `SKIP LOCKED` | Worker 1 claimed job 1; while it held that lock, worker 2 claimed job 2. Job 3 remained pending. |
| Deadlock | Session A returned `40P01: deadlock detected` with exit status 3; session B exited 0 and committed. Final balances were 200 and 300. |

The same-row final state was:

```text
 id | balance
----+--------
  1 |     111
  2 |     220
```

The queue final state was:

```text
 id | status  | claimed_by
----+---------+-----------
  1 | running | worker-1
  2 | running | worker-2
  3 | pending |
```

The deadlock victim is not stable API behavior. A valid later run may abort B instead, producing balances 110 and 210 after A commits. The runner accepts either complete transaction outcome and rejects partial or mixed results.

## Interpretation

The lock wait was established from server state before the one-second measurement hold, while the different-row update completed during that hold. This separates row-level conflict behavior from process-start timing.

The two explicit error paths were handled narrowly. `55P03` was accepted only in the `NOWAIT` scenario, and one `40P01` plus one successful session was required in the deadlock scenario. Other `psql` failures stop the run.

## Caveats

- The 1,256 ms wait includes an intentional one-second delay, activity polling, Docker execution, and scheduling.
- `NOWAIT` timing varies at sub-millisecond to millisecond scale locally and is less useful than its immediate `55P03` outcome.
- Deadlock detection waits according to PostgreSQL configuration; the selected victim can change between runs.
- Tiny local tables make lock outcomes clear but do not model queue throughput, connection-pool contention, or production transaction duration.
