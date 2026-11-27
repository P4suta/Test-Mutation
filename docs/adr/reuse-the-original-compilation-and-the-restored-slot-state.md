---
status: proposed
date: 2026-11-26
---
# Reuse the original compilation and the restored slot state

## Context

A mutant can change a file outside its source, including between two checks in the same second.
Concurrent jobs can request compilation of the same original file.

## Decision

Record file signatures while copying the project into each slot.
Walk the slot after a mutant finishes.
Refresh the signatures of restored paths before returning the slot to the pool.
Keep one original compilation per source and give waiting jobs its result and elapsed time.
Compare uncovered mutants in the private compile workspace.

## Alternatives

Walking before each mutant repeats a scan of a slot just restored.
Separate original compilations repeat work and can impose different time limits on the same source.

## Consequences

The comparison retains file identity, change times, and the digest of recently changed files.
A failed restoration retires the slot.

## Confirmation

The work counters and filesystem tests cover reuse, same-size replacements, missing tests, and concurrent compilation.
Revisit the signatures if an independent snapshot finds changed files in a restored slot.
