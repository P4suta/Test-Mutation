---
status: accepted
date: 2026-11-24
---
# Fail the run on a malformed or unused suppression

## Context

A misspelt suppression comment, an unknown name, or a block without its end suppressed other mutants than meant, and the run said nothing.

## Decision

`Test::Mutation::Suppression` recognizes a trailing comment, a block ending in `## use mutate`, and a comment before a named routine.
The settings `suppress-require-names` and `suppress-require-reason` can require mutator names and a reason independently.
The parser checks every comment that resembles a directive.
The analysis rejects a directive that covers no mutant in the catalog and reports all errors before running tests.

## Alternatives

A warning lets a run measure the wrong mutants and pass.
Stopping at the first refusal makes one run per broken comment.
Judging only the chosen mutators refuses a comment for a profile that a project runs elsewhere.

## Consequences

Changing the profile leaves a valid suppression usable.
The analysis also considers mutants outside the selected profile.

## Confirmation

`t/discovery/suppressions.t` and `xt/mutants/suppressions.t` compare the parser with an independent interpreter over every layout.
