---
status: proposed
date: 2026-11-23
---
# Try a later test after a timeout

## Context

[The classification](classify-a-mutant-by-what-the-run-observed.md) ended the work on a mutant at the first test over its time limit.
When the runner ordered tests by their measured durations, a test that reached its time limit could hide a later failure.
The runner now visits covering tests in [project-relative path order](order-covering-tests-by-project-relative-path.md).

## Decision

A timeout leaves the decision to the next test.
A later failure means `Killed`, and otherwise the mutant stays `Timeout`, outside the score.
The second timeout ends the work on the mutant.
In the self-run and five libraries, 21 of 152 timeouts became `Killed`.

## Alternatives

A verdict at the first timeout costs one time limit and loses those 21 verdicts.
A third try decided none of 17 further mutants in two libraries.

## Consequences

A mutant that stops every test costs two time limits.
The test time of the 103 library mutants rose from 1057 to 1618 seconds.

## Confirmation

`t/unit/verdict.t` checks pairs of outcomes and the two-timeout limit.
`t/e2e/repeated-verdicts.t` exercises conflicting attempts.
Reconsider when a third test would decide the verdict.
