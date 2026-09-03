# Row locking under concurrency

An order service debits account balances and runs a table-backed job queue. At low traffic, each statement appears independent. Under concurrent traffic, two requests can target the same account, queue workers can select the same pending job, and multi-account transfers can lock rows in conflicting orders.

The intuitive approach is to start a transaction, read or update whichever rows are needed, and assume unrelated sessions will continue normally. PostgreSQL row locks make that mostly true, but the row set, acquisition order, and choice between waiting, failing, or skipping determine the actual behavior.

This lab uses controlled concurrent `psql` sessions to demonstrate four foundations: same-row updates serialize, `NOWAIT` rejects contention, `SKIP LOCKED` divides available queue work, and opposite lock order can deadlock.

## Lock Mental Model

A row lock is held until its transaction ends, not merely until the locking statement finishes. A conflicting session must choose behavior through its SQL:

```text
ordinary UPDATE / FOR UPDATE: wait for the conflicting transaction
FOR UPDATE NOWAIT:            fail rather than wait
FOR UPDATE SKIP LOCKED:       ignore currently locked candidates
```

Locks are attached to rows, so locking account 1 does not by itself block an update to account 2. PostgreSQL still applies table-level locks and MVCC rules, but those are compatible for the statements in this experiment.

A deadlock differs from ordinary waiting. Waiting has a direction and can finish when the holder commits. A deadlock forms a cycle:

```text
transaction A holds row 1 and waits for row 2
transaction B holds row 2 and waits for row 1
```

Neither transaction can advance. PostgreSQL detects the cycle and aborts one transaction so the other can finish.

## Scenario And Experiment

The runnable experiment is in [`benchmark/`](benchmark/). It uses PostgreSQL 17.6 Alpine, database `row_locking`, Compose project `row-locking`, host address `127.0.0.1:15441`, and `tmpfs` database storage. Its only clients are POSIX shell and the image's `psql`.

Run all four scenarios:

```bash
cd topics/database/row-locking/benchmark
./run.sh
docker compose down --remove-orphans
```

The runner recreates this small deterministic data set:

| Table | Initial rows |
| --- | --- |
| `accounts` | `(1, 100)`, `(2, 200)` |
| `jobs` | Three jobs with status `pending` |

It opens long-lived `psql` processes through named pipes. Before starting a conflicting operation, it queries `pg_stat_activity` until the holder is `idle in transaction`. Before releasing the same-row holder, it verifies that the contender's `wait_event_type` is `Lock`. These state checks avoid relying on a guessed session-start delay.

Expected lock and deadlock errors are not ignored generically. The script requires SQLSTATE `55P03` for `NOWAIT`, requires exactly one SQLSTATE `40P01` deadlock victim, accepts only the corresponding `psql` success/error exit-status pair, and fails every other SQL error through `ON_ERROR_STOP`.

Local observations are recorded in [`result/2026-09-03-postgresql-17-darwin-arm64.md`](result/2026-09-03-postgresql-17-darwin-arm64.md).

## Timelines

### Same And Different Rows

```text
holder:    BEGIN -> update account 1 (+1) --------------------> COMMIT
waiter:                  update account 1 (+10) -> waits -----> succeeds
other row:               update account 2 (+20) -> COMMIT
runner:                   observes Lock wait -> holds 1 second -> releases holder
```

Account 2 reaches 220 before the holder is released. After both account-1 transactions commit, account 1 is 111. The final values prove that the same-row changes serialized without losing either increment while an unrelated row proceeded.

### NOWAIT

```text
holder: BEGIN -> update account 1 --------------------------> ROLLBACK
probe:                 SELECT ... FOR UPDATE NOWAIT -> 55P03
```

The probe reports the error immediately instead of joining the lock wait queue.

### Queue Workers

```text
worker 1: lock first pending job (1) -> mark running --------> COMMIT
worker 2:        scan pending jobs, skip locked 1 -> claim 2 -> COMMIT
```

Worker 1 deliberately keeps job 1 uncommitted while worker 2 selects. The `ORDER BY id` makes the candidate order deterministic; `SKIP LOCKED` changes worker 2's result from waiting on job 1 to claiming job 2.

### Deadlock

```text
A: BEGIN -> lock account 1 -> request account 2 -- waits --+-> survivor commits
B: BEGIN -> lock account 2 -> request account 1 -- waits --+-> victim aborts
```

The runner waits until both first updates are complete before sending either second update. Which transaction PostgreSQL chooses as victim is intentionally not asserted. Exactly one must be aborted, and final balances must contain all of A's increments (`110, 210`) or all of B's (`200, 300`), never a partial mixture.

## Experiment And Result Interpretation

| Scenario | Controlled observation | Meaning |
| --- | --- | --- |
| Same row | The second account-1 update appears in `pg_stat_activity` waiting on `Lock`; its measured wait includes a deliberate one-second hold. | Conflicting row updates serialize until the holder transaction ends. |
| Different row | Account 2 commits at 220 while account 1 remains locked. | Row-level conflict does not imply every update to the table waits. |
| `NOWAIT` | The locked-row probe returns SQLSTATE `55P03`. | The caller can choose immediate failure and implement retry, fallback, or user-visible contention handling. |
| `SKIP LOCKED` | Concurrent workers claim jobs 1 and 2. | Locked candidates can be omitted to keep queue consumers moving. |
| Deadlock | One session returns SQLSTATE `40P01`; the survivor commits both updates. | PostgreSQL resolves a lock cycle by aborting a whole transaction, which callers normally need to retry. |

The wait duration is deliberately produced, not a performance benchmark. The transferable observations are blocked versus runnable state, selected job IDs, SQLSTATEs, and committed values. Docker scheduling can change the displayed milliseconds and PostgreSQL can choose either deadlock victim.

## Source And Pseudocode Walkthrough

[`benchmark/run.sh`](benchmark/run.sh) starts the healthy Compose service, initializes tables with [`benchmark/sql/setup.sql`](benchmark/sql/setup.sql), and runs each session from a focused SQL file. Named pipes keep transactions open without embedding sleeps in the database sessions.

The same-row orchestration is conceptually:

```text
start holder psql
holder: begin; update account 1
wait until holder is idle in transaction

start waiter: update account 1
wait until waiter reports wait_event_type = Lock

update account 2 and commit; require balance 220
hold for one measured second
commit holder
require waiter to commit; inspect final balances
```

The queue claim in [`benchmark/sql/queue-worker.sql`](benchmark/sql/queue-worker.sql) keeps selection and state change in one transaction:

```sql
SELECT id
FROM jobs
WHERE status = 'pending'
ORDER BY id
FOR UPDATE SKIP LOCKED
LIMIT 1;

UPDATE jobs
SET status = 'running', claimed_by = current_worker
WHERE id = selected_id;
```

Conceptually, a production worker then processes or records ownership according to its delivery model. This lab commits the claim only; it does not define retry, lease, or completion semantics.

For the deadlock, [`benchmark/sql/deadlock-a-first.sql`](benchmark/sql/deadlock-a-first.sql) and [`benchmark/sql/deadlock-b-first.sql`](benchmark/sql/deadlock-b-first.sql) acquire different first rows. The runner waits for both transactions, then sends the second-row scripts together. Validation counts error codes rather than assuming A or B will lose.

## Detailed Explanation

An `UPDATE` takes a row-level lock as part of producing a new tuple version. A concurrent update of that logical row cannot safely choose its final value until the earlier transaction commits or rolls back, so it waits. After commit, PostgreSQL rechecks the visible row and applies the second increment. Updating another row has no such row-level conflict.

`SELECT ... FOR UPDATE` locks selected rows without changing application columns. `NOWAIT` modifies conflict handling, not lock strength: it raises `lock_not_available` (`55P03`) if a selected row cannot be locked immediately. Applications should distinguish this expected contention signal from connectivity, syntax, and integrity errors.

`SKIP LOCKED` also modifies conflict handling. It is useful when each queue row is interchangeable work and temporarily omitting a locked row is acceptable. It returns an intentionally inconsistent view with respect to locked rows, so it is unsuitable for reports, complete scans, or operations where every qualifying row must participate. A frequently locked low-ID job can also starve while later jobs keep being claimed.

Deadlock detection is recovery, not prevention. PostgreSQL waits briefly because many ordinary waits resolve, then examines dependencies when deadlock detection runs. Aborting one transaction removes its updates and releases its locks. Applications should keep transactions small, acquire comparable resources in a consistent order, and be prepared to retry `40P01` transactions from the beginning.

## Boundaries

- The tables contain only a few rows and all storage is local `tmpfs`; this isolates lock semantics rather than production throughput.
- The same-row duration includes an intentional one-second hold and orchestration overhead. It is not PostgreSQL lock-manager latency.
- Default `deadlock_timeout` is used. Changing it changes detection latency, not the existence of the cycle.
- `READ COMMITTED` is the default isolation level here. Higher isolation levels can add serialization failures and different retry requirements.
- `SKIP LOCKED` is shown for a simple single-table queue. Priorities, leases, worker crashes, retries, idempotency, and job completion require additional design.
- The claim query uses an index-backed primary-key order on three rows. Large queues need indexes matching their pending-job predicate and ordering.
- Row locks do not replace constraints, optimistic version checks, advisory locks, or application-level idempotency; those solve different coordination problems.
- Table-level locks still exist alongside row locks. DDL and stronger table lock modes can block operations that touch different rows.

## Common Misconceptions

- "A row lock blocks the whole table." Compatible operations on other rows can proceed, although table-level lock conflicts and resource saturation can still create broad blocking.
- "An ordinary blocked update is a deadlock." One-way waiting is not a cycle and normally resolves when the holder ends its transaction.
- "`NOWAIT` retries automatically." It returns an error immediately; retry policy belongs to the caller.
- "`SKIP LOCKED` fairly distributes every job." It improves worker progress but can omit and starve repeatedly locked rows.
- "A deadlock rolls back only the failed statement." PostgreSQL aborts the victim transaction; all work in that transaction must be retried if still needed.
- "Consistent lock order eliminates every possible deadlock." It prevents this class of cycle, but applications can involve indexes, foreign keys, advisory locks, and other resources that create additional dependency patterns.

## Small Conclusion

Row locks preserve correctness by serializing conflicting work while allowing unrelated rows to proceed. `NOWAIT` and `SKIP LOCKED` deliberately trade waiting for failure or an incomplete candidate set. When several rows are required, consistent acquisition order reduces deadlocks, but callers still need transaction-level retry handling and short lock-holding periods.
