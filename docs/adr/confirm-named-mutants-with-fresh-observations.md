---
status: proposed
date: 2026-11-25
---
# Confirm named mutants with fresh observations

## Context

Developers use `Survived` to find a missing test and `Killed` to identify a test that detects the change.
Two mutants of `CPAN-Audit` both passed and failed under serial `prove` runs with a passing unmodified test, as recorded in [issue #45](https://github.com/P4suta/Test-Mutation/issues/45).

## Decision

When a developer selects mutant identifiers, bypass cached verdicts and repeat each candidate for `Killed` or `Survived`.
In copy mode both attempts start from the unmodified test run's final tree.
Confirm `Killed` when the same test detects the change twice, and `Survived` when both attempts survive.
Report conflicting observations as `NoVerdict` with the test and both outcomes, exclude the entry from the score and cache, and exit with status 4.

## Alternatives

A fixed hash order in production changes the environment of the tests.
Repeating every candidate raised the measured `TOML-Tiny` shard time from 50–57 seconds to 93 seconds.

## Consequences

Full runs keep their process count and can reuse confirmed verdicts.
An inconclusive reproduction evicts the earlier verdict.
Two agreeing observations cover the hash orders observed.

## Confirmation

Exercise both orders of a pass and a failure, cache eviction, interruption, and the process count of a full run.
