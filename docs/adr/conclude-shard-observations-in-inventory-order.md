---
status: proposed
date: 2026-11-27
---

# Conclude shard observations in inventory order

## Context

The [earlier merge decision](merge-shard-reports-only-as-one-complete-run.md) checks the advertised inventory.
In the Fold fixture a duplicate spans shards, lowering the score from 75.0% to 66.7%.
The same mutant identifiers can also occur in runs with different tests.

## Decision

Keep the test observations and compiler comparison with each measured mutant.
Bind the measurement to its sources, tests, execution settings, interpreter, and dependencies.
Interleave the shards, verify the digest of the resulting sequence, and apply the same duplicate rule as a whole run.
Keep the first undetected mutant with each compiled digest in each source file.

## Alternatives

Sharding by file keeps duplicates together but can overload one worker.
Recompiling requires the original interpreter and dependencies.

## Consequences

Shard reports carry enough information for an offline merge.
Earlier reports remain readable and require remeasurement to merge.

## Confirmation

Compare each verdict, its reason, the score, and the exit status for the Fold fixture across both measurement modes.
Reject reordered mutants and shards with different inputs.
Revisit the inputs when the launcher gains a dependency.
