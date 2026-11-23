---
status: proposed
date: 2026-11-23
---
# Ignore a survivor that compiles to known code

## Context

Perl folds `10 > 5` and `10 >= 5` into one constant, so no test can detect that mutant.

## Decision

For a mutant that no test detected, the test interpreter compiles the original file and the mutant with `-MO=Deparse`, and the run compares the two digests.
An equal digest marks the mutant `Ignored`.
A mutant with the digest of an earlier one in the same file is `Ignored` too.
The compiles use a fixed hash seed, and an original with failed or unstable output turns the step off with a warning.

## Alternatives

A walk over the op tree with `B` covers `__FILE__`, but a missed field would hide a real survivor.
A check before the tests costs one process per mutant.

## Consequences

`B::Deparse` shows constant types, so `60 * 1` and `60 / 1` stay distinct.
It prints no field and no `ADJUST` block, so a survivor there skips the step.
A file that reads `__FILE__` at compile time never compares equal.
`--no-equivalence` turns the step off.

## Confirmation

`t/e2e/equivalence.t` and `t/e2e/class.t` fix the statuses of fixtures with each case.
`t/assumptions/deparse-distinguishes.t` shows a change in every construct that holds a comparable site.
