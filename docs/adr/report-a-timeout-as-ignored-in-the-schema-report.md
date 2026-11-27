---
status: accepted
date: 2026-11-24
---
# Report a timeout as ignored in the schema report

## Context

The terminal report leaves a timeout out of the score.
The schema's viewer counts a `Timeout` as detected, so the HTML report showed a higher score.

## Decision

The JSON report writes the schema name of each status from the catalog: a `Timeout` is `Ignored`, and a `NoVerdict` is `RuntimeError`.
The viewer leaves both out of its score, as the run does.
The `testMutation` key of each mutant holds the status of the run and its reason, and `statusReason` holds the sentence about the case.
`Report::Json::parse` reads that key and refuses a schema name that differs from it.

## Alternatives

A timeout counted as detected in every report credits a slow machine.
Keeping `Timeout` in the file needs a fork of the viewer.

## Consequences

A reader that wants the status of the run reads `testMutation.status`.
`mutation merge` refuses a report from before this change.

## Confirmation

`t/contract/reports.t` computes the score of the viewer from the statuses of each written file, compares it with the run, and reads every report back.
`xt/report-schema.t` validates the reports against the pinned schema.
Reconsider when the schema gains a status for an inconclusive mutant.
