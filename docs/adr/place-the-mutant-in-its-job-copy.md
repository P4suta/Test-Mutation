---
status: proposed
date: 2026-11-26
---
# Place the mutant in its job copy

## Context

A test can load Perl code through another process, an absolute filename, or a direct read.
Some tests leave files that affect a second invocation.

## Decision

Write the replacement into the job's private project tree and into byte-identical built copies.
Preserve the mode of each file through an atomic rename.
Run an explicit reproduction command in a copy.
A failure can detect a mutant only after the original test passes in the same state.

## Alternatives

A module search hook alone misses direct reads and tainted children.
Writing into the working project would expose unrelated processes to the mutation.

## Consequences

Each job restores its copy before handing it to another mutant.
In-place measurements use the module hook and serialize mutants because they share one working tree.
The runner restores test-created changes between mutants and replays earlier original tests when setup populated the tree.

## Confirmation

Compare direct reads and child processes with patched source files.
Test read-only copies, external links, interruptions, and a test whose setup fails twice.
