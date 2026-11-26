---
status: proposed
date: 2026-11-22
---
# Name the injected shim by generation

## Context

The tests of the tool start its command, so a run of the tool on itself nests one run inside another.
A shim loaded as `Test::Mutation::Shim` would also occupy the `%INC` entry of the file under test, and no mutant of the shim could load.

## Decision

The driver writes its copy of the shim under the package `Test::Mutation::Shim::G1`, with environment variables named for that generation.
A driver that finds a generation in its environment uses the next number and appends to the inherited `PERL5OPT`.
The driver reads the shim source through `@INC`, hooks included, so a nested run injects a mutated shim.

## Alternatives

One shared package name works for a single run and hides every mutant of the shim from a nested run.

## Consequences

Each generation installs its own hook, and the debugger dispatcher calls the tracer of every generation.
Tests that count hooks subtract the hooks of their own process.

## Confirmation

`xt/literals.t` checks the generation-specific environment names.
`xt/release/self-mutation.t` requires detected shim changes in a complete self-measurement.
