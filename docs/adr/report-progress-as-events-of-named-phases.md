---
status: proposed
date: 2026-11-26
---
# Report progress as events of named phases

## Context

An unmodified test can run for minutes before the first mutant finishes.
A CI log and a terminal must both show which phase is running.

## Decision

The runner publishes phase changes, completed tests, completed mutants, and ticks at cooperative checkpoints.
A listener on standard error measures elapsed time with a monotonic clock and estimates remaining work from completed mutants.
The final counts come from the measured result.
A nonempty `NO_COLOR` disables color even with an explicit color option, as required by the project.
[NO_COLOR convention](https://no-color.org/)

## Alternatives

A separate process could print while Perl is blocked, but would need its own signal handling and a channel for the latest counts.

## Consequences

Logs retain complete lines and terminals update their current position in place.
An uninterruptible system call can delay a tick.
The command configures its two output streams once at startup.
[Perl binmode](https://perldoc.perl.org/functions/binmode)

## Confirmation

Clock-driven tests bound silence and compare the last position with the result.
Reconsider the tick source if a supported workload spends a long interval between checkpoints.
