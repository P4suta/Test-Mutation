---
status: proposed
date: 2026-11-26
---
# Report a compile error with its cause

## Context

A failing test can encounter an invalid replacement or an exception the target raises during compilation.
A module can also require initialization that its tests normally provide.

## Decision

Compare the original and the changed file with the selected Perl interpreter.
Distinguish Perl's rejection of the replacement from a failure in a compilation block.
Read the binding introduced by a function replacement when the target compiles.
Report an invalid replacement as a tool defect and identify its file and cause in the report.

## Alternatives

Counting every loading failure as a detected mutation awards credit for invalid code.
Checking only the changed file hides failures that occur when the original needs its usual initialization.

## Consequences

A run that exposes invalid generated code can preserve its report for diagnosis.

## Confirmation

The tests exercise each cause, imported and missing functions, and exceptions that resemble Perl diagnostics.
Revisit classification if equivalent Perl diagnostics conceal different compilation failures.
