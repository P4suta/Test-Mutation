---
status: proposed
date: 2026-11-27
---

# Conclude shard observations in inventory order

## Context

The [existing merge](merge-shard-reports-only-as-one-complete-run.md) checks inventory.
Splitting a Fold duplicate lowers its score from 75.0% to 66.7%.
Different tests can share an inventory.

## Decision

Store test observations and compiler comparisons per mutant.
Fingerprint sources, tests, execution settings, interpreter, and dependencies.
Verify the prepared copy and key cached observations to its inputs.
Compare shared compiler inputs by content because shards can compile different modules.
Exclude unchanged published reports at their recorded paths from isolated copies and fingerprints.
Fingerprint reports visible in place or through linked inputs.
Reuse a detection when every covering test through its first failure matches.
Interleave shards and verify inventory order before classifying duplicates.
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
