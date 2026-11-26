---
status: proposed
date: 2026-11-26
---
# Require complete self-mutation results

## Context

Timeouts and missing files can leave a perfect score.
A four-CPU Linux run exceeded seven hours before reaching half its inventory, beyond the [hosted job limit](https://docs.github.com/en/actions/reference/limits).

## Decision

Measure the complete project without cached verdicts.
The manual workflow merges eight uncached shards and checks whether their inventory matches the checkout.
Require 100 percent, a completed verdict for every eligible mutant, and named suppressions with reasons.
Measure the shim on Perl 5.10, 5.14, and 5.18.
Require both statement coverage and branch coverage to meet their recorded floors.

## Alternatives

A threshold alone accepts an incomplete report.
One hosted job can expire before it produces a report.

## Consequences

Each shard repeats the original tests.
Eleven release cases exercise eight distributions.

## Confirmation

`t/unit/self-measurement.t` rejects incomplete inventories, interrupted runs, and fabricated suppressions.
`t/unit/library-coverage.t` rejects regressions in either coverage fraction.
Revisit sharding when an individual part approaches the hosted limit.
