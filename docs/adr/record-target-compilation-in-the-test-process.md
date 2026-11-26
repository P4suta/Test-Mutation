---
status: proposed
date: 2026-11-26
---
# Record target compilation in the test process

## Context

Perl can load an absolute path, compile a string with `eval`, or start a child with an empty environment.
Source comparisons also observe bytes that Perl never executes.

## Decision

Insert a `UNITCHECK` block before the final statement in each copied target.
An inherited directory descriptor identifies the test by device and inode even after a child clears its environment.
When a load bypasses the hook, repeat the passing test in a diagnostic copy with tracing active before the first statement.
Give byte-sensitive tests the original source bytes.

## Alternatives

A process identifier loses the link between parent and child.
A shared log mixes concurrent tests.

## Consequences

A source comparison can detect a change on an unexecuted line.

An in-place test that compiles a target around the module hook yields an inconclusive verdict.
A private control copy identifies unobserved loads and preserves project sources.

## Confirmation

Check reached and unreached lines under absolute loads, string evaluation, concurrent tests, and a tainted child.
Compare source bytes before and after measurement.
Revisit the record channel if a supported child closes inherited descriptors before compiling its target.
