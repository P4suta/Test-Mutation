---
status: proposed
date: 2026-11-22
---
# Activate mutants through an `@INC` hook

## Context

Earlier Perl tools write each mutant into the source tree or a copy of it.
An interrupted run then leaves a changed tree, and parallel runs need one copy for each worker.

## Decision

The shim puts a hook at the front of `@INC` and serves the mutated text when a test requires the target file.
A `#line` directive and the `%INC` entry give the served text the identity of the original file.
The shim records each served target, and it records a target that a process loaded around the hook.
The runner counts a test toward a mutant after the record shows that the test loaded it.

## Alternatives

A copy of the tree works with every loading style, including scripts and absolute paths.
It costs a copy for each worker and changes every absolute path a test observes.

## Consequences

Scripts and files loaded by absolute path run unmutated, and the run reports them.
A child process in taint mode ignores `PERL5OPT` and runs the original code.

## Confirmation

`t/shim/` covers identity, `use lib`, forks, taint mode, and loads around the hook.
`t/e2e/mechanics.t` checks the statuses that follow.
