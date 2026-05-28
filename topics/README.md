# Topics

The `topics` directory groups content by engineering problem. Each topic is an independent learning unit.

## Recommended Structure

```text
topic-name/
  README.md
  code/
  benchmark/
  result/
```

Not every topic needs complete code at the beginning. Early topics can start with only a `README.md`; add experiment code and results once the problem boundary becomes clear.

## Topic Template

Each topic should generally cover:

- Background: what business or system scenario exposes this problem.
- Intuition: what many engineers might try first.
- Options: which implementations or practices can be compared.
- Experiment: how to design the variables and observations.
- Results: experiment output and observed behavior.
- Explanation: why the behavior happens.
- Boundaries: when each choice is suitable or unsuitable.
- Misconceptions: where the topic is often misunderstood or overused.

## Categories

- `go`: Go language behavior, concurrency, runtime behavior, and performance experiments.
- `database`: Relational databases, indexes, transactions, table growth, and query plans.
- `cache`: Cache patterns, hot data, expiration strategies, and reliability issues.
- `queue`: Message queues, retries, backlog, and backpressure.
- `reliability`: Idempotency, rate limiting, timeouts, circuit breakers, and graceful degradation.
