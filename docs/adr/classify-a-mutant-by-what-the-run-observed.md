---
status: proposed
date: 2026-11-22
---
# Classify a mutant by what the run observed

## Context

A test can pass because it never loaded the mutant, and a test can fail because the mutant doesn't compile.

## Decision

The unmodified run serves the original sources through the hook, so a failure there stops the run before any mutant.
A test result counts for a mutant after the record shows that the test loaded it.
A mutant that no test loaded is `NoCoverage`.
The shim records the moment a mutant compiles.
A mutant without that record gets a syntax check: a failed check means `CompileError`, and otherwise the test result decides.
A target loaded around the hook means `RuntimeError`.
A time limit means `Timeout`, which the score leaves out.
The score divides `Killed` by the sum of `Killed`, `Survived`, and `NoCoverage`.

## Alternatives

The Stryker metrics count a timeout as detected, which credits a slow machine.

## Consequences

The bundled viewer applies the Stryker formula, so its score exceeds the terminal score when timeouts exist.
A run with a `RuntimeError` or without a valid mutant exits with status 4.

## Confirmation

`t/unit/verdict.t` enumerates every outcome, and `t/e2e/mechanics.t` fixes the statuses of each mechanism.
