---
status: proposed
date: 2026-11-26
---
# Record target compilation in the test process

## Context

Perl can load a target by absolute path, evaluate its text, or start a child with an empty environment.
Source comparisons also observe bytes that Perl never executes.

## Decision

Insert a `UNITCHECK` block before the final statement in each copied target.
An inherited directory descriptor identifies the test when a child clears its environment.
Use the directory's device and inode to locate its records.
When a load bypasses the hook, repeat the passing test in a diagnostic copy with tracing active before the first statement.
Run byte-sensitive tests against raw source.

## Alternatives

A process identifier loses the link between parent and child.
A shared log mixes concurrent tests.

## Consequences

The driver retains the descriptor across process launches.
A source comparison can detect a change on an unexecuted line.

An in-place test that compiles a target around the module hook yields an inconclusive verdict.
A private control copy identifies otherwise unobserved loads while the project sources retain their bytes.

## Confirmation

Check reached and unreached lines under absolute loads, string evaluation, concurrent tests, and a tainted child.
Compare source bytes before and after measurement.
