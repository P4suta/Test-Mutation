---
status: accepted
date: 2026-11-24
---
# Require every gate to count and to reject

## Context

The documentation gate accepted "no public symbols defined" as a pass.
Pod::Coverage skips a subroutine whose glob another package assigned, as `signature_for` and Moo do.
The gate checked 1 of 32 packages, and a module documented a method that was gone.

## Decision

Every gate file under `xt/` calls `Gate::checked` with a count and a floor.
Every gate file holds a subtest that feeds the gate a broken input.
`xt/gates.t` fails when a file lacks one of the two.
The documentation gate reads the public symbols from the source text.
`t/open-findings.tsv` lists each known violation with the work that removes it.
A violation outside the list fails, and so does a listed line that is gone.

## Alternatives

A trust list for Pod::Coverage keeps the guess that caused the gap.
The gates as they were let the next empty scan pass.

## Consequences

The list turns a gate green while a violation stands.
The last change of the rework requires an empty list and removes it.

## Confirmation

`xt/gates.t` rejects a file without a count or a rejecting subtest.
Reconsider when no broken input can express a check.
