---
status: proposed
date: 2026-11-23
---
# Try a later test after a timeout

## Context

[The classification](classify-a-mutant-by-what-the-run-observed.md) ended the work on a mutant at the first test over its time limit.
The tests run in the order of their durations, so a short test that never ends hid a later test that fails.

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

`t/unit/verdict.t` checks every pair of outcomes, and `t/e2e/runner.t` shows the change of status.
Reconsider the limit of two when a measured run decides mutants at a third try.
