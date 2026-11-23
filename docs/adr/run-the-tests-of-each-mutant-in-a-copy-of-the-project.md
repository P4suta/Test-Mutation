---
status: proposed
date: 2026-11-23
---
# Run the tests of each mutant in a copy of the project

## Context

[The recheck](recheck-the-tests-when-the-mutants-change-the-project.md) leaves stray files, and a mutant behind a broken test gets no verdict.
On one published library, 67 of 881 mutants lost their verdict.

## Decision

The run copies the project into the temporary directory, without `.git`, the work directory, and the reports, and links `local`.
The unmodified run happens in that copy.
Each job then works in its own copy of the result.
After every mutant, the run compares that copy with its recorded state and restores a changed one.
`--in-place` keeps the recheck.

## Alternatives

One shared copy protects the project, but a change inside it misleads later mutants.
The status quo leaves files behind and loses verdicts.

## Consequences

A run costs one copy per job and one comparison per mutant.
An absolute path, a symbolic link, and `local` still lead outside the copy.
Tests that need the repository data fail in the copy, and the message names `--in-place`.

## Confirmation

`t/e2e/runner.t` shows a mutant that creates a file: the project stays unchanged, and every mutant gets its verdict.
Reconsider when the copies cost more than the tests.
