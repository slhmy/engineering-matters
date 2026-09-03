# Transaction isolation under concurrent decisions

An incident-response service stores which doctors are on call. The service first checks that two doctors remain available, then lets one doctor go off call. That check looks safe in a single request, but two concurrent requests can both make a valid local decision and leave nobody available.

A smaller account example exposes the snapshot behavior behind the problem. One transaction reads the same balance twice while another transaction commits an update between those reads. This lab compares PostgreSQL `READ COMMITTED`, `REPEATABLE READ`, and `SERIALIZABLE` with controlled concurrent sessions.

## Isolation Mental Model

Isolation controls which committed database state a transaction may observe and whether PostgreSQL rejects a set of concurrent decisions that cannot be arranged into a valid serial order.

```text
READ COMMITTED   one fresh snapshot for each statement
REPEATABLE READ  one snapshot fixed by the transaction's first query
SERIALIZABLE     repeatable-read snapshots plus conflict detection
```

PostgreSQL implements `SERIALIZABLE` with Serializable Snapshot Isolation (SSI). Transactions still run concurrently. PostgreSQL tracks read/write dependencies and aborts a transaction with SQLSTATE `40001` when allowing all of them to commit could produce a result inconsistent with every serial execution.

Stronger isolation does not mean other sessions stop running, and a stable snapshot alone does not protect a constraint spanning multiple rows. The write-skew case changes different rows, so ordinary row locks on the updated rows do not create a direct write/write conflict.

## Scenario And Experiment

The runnable lab is in [`benchmark/`](benchmark/). Its Compose project is named `transaction-isolation`; it runs PostgreSQL 17.6 Alpine, database `transaction_isolation`, on `127.0.0.1:15440`. PostgreSQL data is stored on `tmpfs` and removed when the runner exits.

Run all four cases:

```bash
cd topics/database/transaction-isolation/benchmark
./run.sh
```

The script starts a healthy container, rebuilds the schema, runs paired `psql` processes, validates every final state, and removes the container even after failure. No host PostgreSQL client is required. Local observations are recorded in [`result/2026-09-03-postgresql-17-darwin-arm64.md`](result/2026-09-03-postgresql-17-darwin-arm64.md).

The account case starts with balance `100`; the writer changes it to `120`. The barriers enforce this timeline:

```text
Reader                                      Writer
BEGIN at selected isolation                BEGIN
read balance = 100
join observed barrier -------------------- join observed barrier
                                            UPDATE balance = 120
                                            COMMIT
join committed barrier ------------------- join committed barrier
read balance again
COMMIT
```

The doctor case starts with Alice and Bob both on call. Each transaction reads the count before updating its own row:

```text
Alice transaction                          Bob transaction
BEGIN                                       BEGIN
observe on_call count = 2                   observe on_call count = 2
join decision barrier -------------------- join decision barrier
set Alice off call                          set Bob off call
COMMIT                                      COMMIT
```

The barrier guarantees that neither update happens until both transactions have observed two doctors. It uses shared PostgreSQL advisory locks only for experiment orchestration; those locks are not part of the business solution.

## Experiment And Result Interpretation

The local run produced:

| Case | First observation | Second observation / commits | Final state |
| --- | --- | --- | --- |
| Repeated read, `READ COMMITTED` | balance `100` | balance `120` | balance `120` |
| Repeated read, `REPEATABLE READ` | balance `100` | balance `100` | balance `120` |
| Write skew, `READ COMMITTED` | both saw 2 on call | both committed | Alice off, Bob off; 0 on call |
| Write skew, `SERIALIZABLE` | both saw 2 on call | one committed; one failed with `40001` | one on call |

`READ COMMITTED` takes a snapshot at the start of each statement. The first account query finishes before the writer updates, while the second starts after the writer commits, so it sees `120`.

`REPEATABLE READ` keeps the reader's transaction snapshot. Its second query still sees `100`, although a separate query after both sessions finish confirms that the database contains `120`. The old value is transaction-local visibility, not a lost writer update.

In the `READ COMMITTED` doctor case, both decisions are valid against their own observations. Because the transactions update different rows, both commits succeed and the cross-row invariant is violated. Under `SERIALIZABLE`, the same read/write dependency cycle cannot be equivalent to Alice acting entirely before Bob or Bob acting entirely before Alice. PostgreSQL cancels one participant; the surviving transaction turns off one doctor and the other remains on call.

The identity of the transaction aborted by SSI is intentionally unspecified. Applications using `SERIALIZABLE` must retry the complete transaction after `40001`, including all reads that informed its decision.

## Source And Pseudocode Walkthrough

[`benchmark/run.sh`](benchmark/run.sh) launches two independent `psql` clients for each case and captures their statuses separately. It checks exact account observations, requires both `READ COMMITTED` skew transactions to commit, and requires exactly one serializable transaction to fail specifically with SQLSTATE `40001`. Any timeout, connection error, SQL error, wrong number of failures, or unexpected final state fails the run.

[`benchmark/sql/setup.sql`](benchmark/sql/setup.sql) creates the two small tables and `wait_for_barrier`. The function takes a shared advisory lock, counts granted participants in `pg_locks`, and polls at 10 ms intervals. After observing both participants it holds the rendezvous for another 50 ms so both waiters can observe it; it raises a query-canceled error after 10 seconds rather than hanging indefinitely.

[`benchmark/sql/repeated-read-reader.sql`](benchmark/sql/repeated-read-reader.sql) and [`benchmark/sql/repeated-read-writer.sql`](benchmark/sql/repeated-read-writer.sql) implement:

```text
reader.begin(isolation)
first = reader.read_balance()
barrier("first observation complete", reader, writer)
barrier("writer committed", reader, writer)
second = reader.read_balance()
reader.commit()

writer.begin()
barrier("first observation complete", reader, writer)
writer.update_balance(120)
writer.commit()
barrier("writer committed", reader, writer)
```

[`benchmark/sql/write-skew-session.sql`](benchmark/sql/write-skew-session.sql) is run once for each doctor:

```text
transaction.begin(isolation)
observed = count(on_call doctors)
assert observed == 2
barrier("both decisions made", alice, bob)
update my doctor to off_call
transaction.commit()
```

The SQL scripts contain the transactions and observations; the shell is limited to concurrent process orchestration, status handling, output validation, and cleanup. There are no sleeps in the shell. The short polling and rendezvous sleeps exist only inside the explicit database barrier.

## Detailed Explanation

PostgreSQL's `READ COMMITTED` level prevents a statement from reading uncommitted data, but it does not promise that two statements in one transaction see identical committed state. Every command gets a snapshot containing transactions committed before that command began. This is often appropriate for short operations that should see recent commits and do not derive a later write from a multi-statement invariant.

At `REPEATABLE READ`, the first non-transaction-control statement fixes a snapshot for the transaction. Later statements continue to resolve row visibility against it. PostgreSQL's implementation also prevents serialization anomalies beyond the SQL standard's minimum repeatable-read requirements, but it can still permit write skew: Alice and Bob can each update a row the other transaction read without updating the same row.

The doctor invariant is a predicate over the set of rows: at least one row must remain `on_call`. A per-row update does not make that predicate atomic. At lower isolation, practical solutions include locking a shared coordination row, taking an appropriate explicit lock covering the decision, or redesigning the data so the invariant is enforced by one contended row or another database constraint. These choices trade concurrency and schema complexity for deterministic coordination.

`SERIALIZABLE` lets the transactions optimistically proceed and detects dangerous dependency structures. Its protection is not free: conflicting workloads can generate retries, and a retry may fail again under sustained contention. The application must make the whole operation retryable and avoid exposing irreversible external side effects before commit.

## Boundaries

- The lab isolates visibility and write-skew behavior with two rows and two clients; it is not a throughput benchmark.
- Advisory locks are synchronization instruments for deterministic reproduction, not a recommendation for implementing the on-call invariant.
- PostgreSQL `REPEATABLE READ` uses snapshot isolation and is stronger than some systems' interpretation of that SQL level. Results do not transfer mechanically across database engines.
- PostgreSQL accepts `READ UNCOMMITTED` but treats it as `READ COMMITTED`; dirty reads are therefore outside this PostgreSQL lab.
- `SERIALIZABLE` preserves serial equivalence by aborting transactions, not by guaranteeing that every transaction commits. Production code must bound and observe retries.
- A database constraint is preferable when the invariant can be expressed directly, but ordinary `CHECK` constraints cannot enforce this multi-row count.
- The `tmpfs` database and local Docker environment do not model production durability latency or contention.

## Common Misconceptions

- "A transaction always reads one snapshot." At PostgreSQL `READ COMMITTED`, each statement receives a new snapshot.
- "Repeatable read prevents every concurrency anomaly." A stable snapshot can still allow write skew when transactions update different rows based on a shared predicate.
- "No dirty reads means the decision is safe." Both doctor transactions read only committed data and still violate the invariant.
- "Serializable means transactions run one at a time." PostgreSQL runs them concurrently and may abort one when their combined dependencies are not serializable.
- "Retry only the failed `COMMIT`." A serialization retry must rerun the complete transaction so its reads and decisions use a new consistent execution.
- "The serializable loser is deterministic." Scheduling and SSI conflict detection may abort either participant; only the preserved invariant and `40001` contract matter.
