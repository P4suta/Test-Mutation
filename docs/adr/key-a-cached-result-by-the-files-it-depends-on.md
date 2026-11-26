---
status: proposed
date: 2026-11-23
---
# Key a cached result by the files it depends on

[Proposed successor for cache identity](reuse-verdicts-by-the-inputs-that-produced-them.md)

## Context

A second run on an unchanged project repeats every test.
A changed input can invalidate a stored result.

## Decision

`--cache` stores each result in `.mutation/cache.json` with a digest.
The digest covers the mutant, interpreter, switches, hash traversal settings, covering tests, and analyzed sources they load.
Every analyzed source goes through the hook, so the unmodified run records the loads.
Other files under the top-level source and test directories enter every key.
The cache keeps `Killed`, `Survived`, `CompileError`, and `Ignored`, and a timeout runs again.
The cache is off by default.

## Alternatives

A digest of the whole project is simpler, but one edit would measure every mutant again.
A key of the mutated file and its tests alone misses a change in another module that the tests load.

## Consequences

A dependency upgrade needs a run without the cache.
The unmodified run still executes every test.

## Confirmation

`t/e2e/cache.t` changes a test, a helper, a source, and a source without mutants, and counts the reused results.
