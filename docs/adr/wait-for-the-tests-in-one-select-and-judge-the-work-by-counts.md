---
status: accepted
date: 2026-11-24
---
# Wait for the tests in one select and judge the work by counts

## Context

The pool polled its pipes and spun once a test held no open pipe.
It read the clock of the machine, so no test could place a deadline.
A mutant that warned in a loop filled 1.5 GB of scratch space through standard error.
The engine harness judged the pool by time, which load changes.

## Decision

The pool waits in one `select` on both pipes of each test and on a pipe that the handlers of `CHLD` and of the signals write, until the nearest deadline.
A clock object from the caller gives the time and the wait.
Both streams stay in memory, and a test past its output limit ends as a timeout with its reason.
`Result->stats` counts the work of a run.

## Alternatives

A shorter poll keeps the loop busy.
A check of the file size needs a poll.

## Consequences

A task names its output limit, and a result holds standard error.

## Confirmation

`t/unit/pool-deadlines.t` moves a clock across each deadline, and `t/e2e/work.t` asserts exact counts.
Reconsider when Perl runs a handler inside `select`.
