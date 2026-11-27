---
status: accepted
date: 2026-11-24
---
# Require every gate to count and to reject

## Context

The documentation gate accepted "no public symbols defined" as a pass.
Pod::Coverage skips a subroutine whose glob another package assigned, as `signature_for` and Moo do.
The gate checked 1 of 32 packages and accepted documentation for a removed method.

## Decision

Every gate file under `xt/` calls `Gate::checked` with a count and a floor.
Every gate file holds a subtest that feeds the gate a broken input.
`xt/gates.t` fails when a file lacks one of the two.
The documentation gate reads the public symbols from the source text.
A gate fails when it reports a violation.

## Alternatives

A trust list for Pod::Coverage keeps the guess that caused the gap.
The earlier gates accepted an empty scan.

## Consequences

A failing gate reports the complete set of violations for the checked inputs.

## Confirmation

`xt/gates.t` rejects a file without a count or a rejecting subtest.
Reconsider when no broken input can express a check.
