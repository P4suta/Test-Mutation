---
status: accepted
date: 2026-11-25
---
# Order covering tests by project-relative path

## Context

The runner tries another covering test after one timeout and stops after two.
For `TOML-Tiny` mutant `d348447604fe`, running `t/strict_arrays.t` first produced `Killed`.
Running two table tests first produced `Timeout` with the same ten-second limit.

## Decision

Visit the selected tests in ascending order of their project-relative paths.
Use each measured duration to set its test deadline.

## Alternatives

Trying tests with shorter measured durations first can save time, but changes in the measurements can change the verdict.
Running every covering test can expose a later failure at the cost of more timeouts.

## Consequences

A slow test can now precede a fast test that detects the mutant.
In two runs of shard `1/4`, `Moo` took 31.0–31.6 seconds before the change and 29.0–30.6 seconds after it.
`TOML-Tiny` took 81.4–89.0 seconds before and 50.1–57.2 seconds after.

## Confirmation

The coverage tests vary the unmodified durations and check which test decides the verdict.
Repeated runs agreed on each of the 298 `Moo` mutants and 157 `TOML-Tiny` mutants.
Reconsider the order if either shard exceeds its time budget or its verdicts depend on the order again.
