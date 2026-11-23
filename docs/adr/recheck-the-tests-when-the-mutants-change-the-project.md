---
status: proposed
date: 2026-11-23
---
# Recheck the tests when the mutants change the project

## Context

A mutant runs inside the project with the rights of the tests.
A run on a published library left two files there, and a test that expects their absence failed afterward.
Every later mutant that reached the test counted as detected.

## Decision

The run records the path, kind, size, and time of every project file after the unmodified run and after the mutants.
On a difference it warns with the paths and runs the unmodified tests once more.
A mutant that a now failing test detected gets no verdict, which makes the run inconclusive.
Such a run saves no cache and leaves the files in place.

## Alternatives

A copy of the project protects the files, but a change inside it misleads later mutants too.
Automatic removal may delete a file of the user.
The status quo reports false detections.

## Consequences

A changed project costs one more pass of the tests.
New content of equal size and time escapes the comparison.

## Confirmation

`t/unit/tree.t` covers the comparison, and `t/e2e/runner.t` covers a test that a stray file breaks.
Reconsider when the tests run inside a copy.
