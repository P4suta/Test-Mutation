---
status: proposed
date: 2026-11-23
---
# Key a cached result by the files it depends on

## Context

A second run on an unchanged project repeats every test.
A stale result is worse than a slow run, so reuse needs a key that changes with every input.

## Decision

`--cache` stores each result in `.mutation/cache.json` with a digest.
The digest covers the mutant, the interpreter, the switches, each test that reaches the mutant, and each analyzed source those tests load.
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
