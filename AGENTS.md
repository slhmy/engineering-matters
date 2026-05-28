# AGENTS.md

## North Star

`engineering-matters` exists to help readers understand why engineering choices matter.

This repository is not a collection of slogans, benchmark screenshots, or absolute best practices. It should teach judgment through small, concrete, reproducible examples.

Every topic should help a reader answer three questions:

- What problem appears when the system grows or the access pattern changes?
- What tradeoffs do common solutions make?
- Under what conditions does one choice become better or worse?

## Audience

Write for engineers who already know basic backend development, but may not yet have a strong mental model for performance, concurrency, scaling, reliability, and operational tradeoffs.

Prefer clear Chinese explanations with English names for files, directories, commands, APIs, and technical terms that are commonly used in code.

## Content Shape

Each topic should feel like a small lab:

- Start from a realistic story or scenario.
- Name the naive or intuitive solution.
- Compare a few practical alternatives.
- Design an experiment with explicit variables.
- Show how to reproduce the result.
- Explain why the result happens.
- End with boundaries, not universal rules.

When adding a new topic, prefer this structure:

```text
topics/<category>/<topic>/
  README.md
  code/
  benchmark/
  result/
```

It is acceptable for early topics to start with only `README.md`. Add runnable code when the scenario and variables are clear enough.

## Writing Principles

- Explain the scenario before explaining the solution.
- Prefer concrete examples over abstract advice.
- Prefer reproducible experiments over claims.
- Prefer tradeoffs over rankings.
- Avoid saying one option is always best.
- State assumptions and test conditions near the conclusion.
- Keep conclusions small enough to be true.
- Use diagrams or tables when they make comparison easier.

## Experiment Principles

Experiments should be simple enough to understand and controlled enough to be useful.

For benchmarks and demos:

- Document the command used to run them.
- Document important environment details when they affect results.
- Vary one important factor at a time when possible.
- Include enough cases to reveal the shape of the tradeoff.
- Treat benchmark numbers as local observations, not universal truth.

Good experiments compare behavior across scenarios, such as:

- read-heavy vs write-heavy
- small key space vs large key space
- uniform access vs hot keys
- low concurrency vs high concurrency
- small table vs large table
- indexed query vs full scan

## Engineering Style

Keep the repository boring and easy to navigate.

- Use plain Markdown for explanations.
- Use Go for Go-specific experiments.
- Use Docker Compose only when a topic needs external services.
- Do not introduce heavy frameworks for a small demonstration.
- Keep scripts and commands obvious.
- Prefer standard library tools before adding dependencies.

## What Not To Do

- Do not turn this into a generic awesome-list.
- Do not add best-practice claims without a scenario.
- Do not add benchmark results without reproduction steps.
- Do not overfit conclusions to one machine or one run.
- Do not add broad abstractions before there are several topics that need them.
- Do not make a topic only about tool usage; explain the engineering pressure behind the tool.

## Definition Of Done For A Topic

A mature topic should include:

- A realistic problem statement.
- A simple mental model or analogy.
- Runnable code or commands.
- A small experiment matrix.
- Observed results.
- Explanation of the results.
- Practical guidance with boundaries.
- Common misconceptions.

If a topic is still a stub, say so clearly and list the next concrete additions.
