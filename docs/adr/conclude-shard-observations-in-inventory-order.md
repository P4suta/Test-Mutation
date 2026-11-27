---
status: proposed
date: 2026-11-27
---

# Conclude shard observations in inventory order

## Context

The [earlier merge decision](merge-shard-reports-only-as-one-complete-run.md) checks the advertised inventory.
In the Fold fixture a duplicate spans shards, lowering the score from 75.0% to 66.7%.
Different tests or project data can produce the same inventory.

## Decision

Keep the test observations and compiler comparison with each measured mutant.
Bind the measurement to its sources, tests, execution settings, interpreter, and dependencies.
Exclude published reports only while their project-relative paths and content digests match the publication record.
Reuse a detection when every covering test through its first failure matches.
Interleave shards and verify the resulting inventory digest before classifying duplicates.
Keep the first undetected mutant with each compiled digest in each source file.

## Alternatives

Sharding by file keeps duplicates together but can overload one worker.
Recompiling requires the original interpreter and dependencies.

## Consequences

Shard reports support offline merging.
Earlier reports remain readable and require remeasurement to merge.

## Confirmation

Compare Fold verdicts, reasons, scores, and exit statuses across both modes.
Reject reordered mutants and shards with different inputs.
Revisit the inputs when the launcher gains a dependency.
