---
status: accepted
date: 2026-11-26
---
# Place a mutator in the default profile by measured rates

## Context

A survivor should identify a test worth improving.
Equivalent code gives the developer nothing to distinguish.

## Decision

Require zero invalid mutants and zero unresolved calls.
Limit structural equivalence to 2% in each corpus and load failures to 10% across pinned distributions.
Probe up to four mutants per family per archive in fresh Perl processes after the original loads.

## Alternatives

Keeping every mutator enabled gives wider coverage at the cost of uninformative survivors.

## Consequences

Keep `comparison-boundary`, `call-swap`, and `bitwise` in the extended profile.
Boundary changes reproduced the original code in 2/74 project cases and 0/62 dependency cases.
Call swaps reproduced it in 0/97 and 2/64 respectively.
In a fresh dependency install, 1 of 8 sampled bitwise changes reproduced the original code.
Perl removed the debugger branch containing the bitwise operation in `namespace::clean`.
All 25 boundary probes and all 22 call swaps loaded.
Among default candidates, statement removal failed 1/32 load probes.
Every other candidate loaded throughout its sample.

## Confirmation

Reevaluate the catalog with `mise run discover-mutants` and `mise run realworld` whenever the generator or corpus changes.
