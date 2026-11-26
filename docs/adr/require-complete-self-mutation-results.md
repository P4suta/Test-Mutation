---
status: proposed
date: 2026-11-26
---
# Require complete self-mutation results

## Context

A score can reach 100 percent after a timeout or a missing source removed a change from its denominator.
Users need a release check that detects a lost measurement as well as a missed change.

## Decision

Measure the complete project without a cache or a selector.
Recompute the source and mutant inventories from the checkout and compare them with the saved report.
Require a score of 100 percent and a completed verdict for every eligible change.
Verify suppressions against named source directives with reasons.
Repeat the shim measurement on Perl 5.10, 5.14, and 5.18.
Compare statement and branch coverage with their separate measured floors.

## Alternatives

A threshold by itself needs only the report's scored entries.
It accepts a passing subset even when the generator or the report loses a file.

## Consequences

The release takes several measurements on distinct interpreters.
Pinned CPAN distributions supply independent test results for the behavior of the released command.

## Confirmation

`t/unit/self-measurement.t` exercises missing inventory, interrupted runs, fabricated suppressions, and zero-mutant sources.
`t/unit/library-coverage.t` rejects a decline in either coverage fraction.
Reconsider the scope when a new executable makes release decisions outside the measured files.
