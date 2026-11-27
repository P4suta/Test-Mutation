---
status: proposed
date: 2026-11-22
---
# Activate mutants through an `@INC` hook

[Proposed successor for default activation](place-the-mutant-in-its-job-copy.md)

## Context

Earlier Perl tools write each mutant into the source tree or a copy of it.
An interrupted run then leaves a changed tree, and parallel runs need one copy for each worker.

## Decision

The shim serves the replacement through an `@INC` hook when a test requires the module.
A `#line` directive and the `%INC` entry give the served text the identity of the original file.
The shim records intercepted and bypassed loads.
The runner counts a test toward a mutant after the record shows that the test loaded it.

## Alternatives

Within a private tree, tests can run scripts or load modules by absolute path.
It costs a copy for each worker and changes every absolute path a test observes.

## Consequences

Scripts and files loaded by absolute path run unmutated, and the run reports them.
A child process in taint mode ignores `PERL5OPT` and runs the original code.

## Confirmation

`t/shim/` covers identity, `use lib`, forks, taint mode, and loads around the hook.
`t/e2e/mechanics.t` checks the statuses that follow.
