---
status: proposed
date: 2026-11-23
---
# Ignore a survivor that compiles to known code

## Context

Some mutants can't change behavior: Perl folds `60 + 0` and `60 - 0` into one constant.
A survivor of that class asks for a test that can't exist.

## Decision

A mutant that passed every test gets one more step.
The test interpreter compiles the original file and the mutant with `-MO=Deparse`, and the run compares the digests of the two outputs.
An equal digest marks the mutant `Ignored`.
A survivor with the digest of an earlier survivor in the same file is `Ignored` too.
The original compiles twice, and a failed or unstable output turns the step off for the file.

## Alternatives

A walk over the op tree with `B` covers `__FILE__`, but a missed field would hide a real survivor.
A check of every mutant before the tests costs one process per mutant.

## Consequences

`B::Deparse` shows constant types, so `60 * 1` and `60 / 1` stay distinct.
A file that reads `__FILE__` at compile time never compares equal.
`--no-equivalence` turns the step off.

## Confirmation

`t/e2e/equivalence.t` fixes the statuses and reasons of a fixture with both cases.
