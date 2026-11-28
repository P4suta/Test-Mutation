---
status: proposed
date: 2026-11-22
---
# Name the injected shim by generation

## Context

The tool's tests start nested runs.
Loading injected code as `Test::Mutation::Shim` or `Test::Mutation::CompilerInputs` can hide project modules with those names.

## Decision

The driver writes `Test::Mutation::Shim::G1` with generation-specific environment variables.
Nested runs increment the generation and append their shim to `PERL5OPT`.
The driver reads shim source through `@INC` hooks so nested runs can inject a mutated shim.
Only standalone compilers receive the observer directory and preload its generation-specific package.

## Alternatives

A shared name reserves the project's `%INC` entry, even with a separate directory.

## Consequences

Each generation installs its own hook, and the debugger dispatcher calls the tracer of every generation.
Tests that count hooks subtract the hooks of their own process.

## Confirmation

`xt/literals.t` checks the environment names.
`xt/release/self-mutation.t` requires detected shim changes.
`t/e2e/library.t` exercises project imports in tests and standalone compilations.
