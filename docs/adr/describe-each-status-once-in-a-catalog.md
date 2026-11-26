---
status: accepted
date: 2026-11-24
---
# Describe each status once in a catalog

## Context

Seven modules listed the statuses of a mutant, and four decided their roles in the score.
A mutant without a verdict had no status, and a reason was a sentence without a cause.

## Decision

`Test::Mutation::Status` holds one row per status: its names in the run and in the report schema, counting word, heading, role in the score, whether the cache keeps it, reasons, and description.
The statuses are `Killed`, `Survived`, `NoCoverage`, `Timeout`, `CompileError`, `NoVerdict`, `Ignored`, and `Pending`.
Every status but `Killed` and `Survived` carries a reason from its closed list, and the type `Entry` refuses any other pair.
Every reader of a status reads the catalog.

## Alternatives

A list in each module needs a test that compares the lists, which missed the viewer's score.
An extra status breaks the pinned schema.

## Consequences

A new status or reason is one row and a case that gives it.

## Confirmation

`t/unit/status.t` pins the rows, `xt/literals.t` refuses status lists elsewhere, and `t/contract/reasons.t` gives each reason.
Reconsider when a report format needs a status that the schema lacks.
