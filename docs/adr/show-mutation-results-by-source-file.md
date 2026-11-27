---
status: proposed
date: 2026-11-26
---
# Show mutation results by source file

## Context

A developer needs to locate a surviving change, inspect the test that reached it, and measure the repair.
A CI reader needs the same score and threshold decision.

## Decision

The terminal and GitHub summary group entries by source path and use the measurement's outcome and score functions.
The terminal lists changes that need attention.
The summary lists every measured change.
The first surviving identifier supplies a copyable `mutation show` command.
Inspection selects matching reports by descending modification time.
When modification times match, the command reads the JSON measurement first so it can skip decoding the HTML presentation.

## Alternatives

Grouping by status separates changes that one test can cover.

## Consequences

Standard error carries at most ten workflow annotations per level.
The job summary retains the complete list in Markdown.
[GitHub Actions workflow commands](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands)

## Confirmation

Command-line journeys cover a first measurement, a repaired survivor, and a threshold decision.
Reconsider the file table if its path and coordinates leave a mutation site ambiguous.
