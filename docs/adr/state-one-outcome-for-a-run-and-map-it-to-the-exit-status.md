---
status: accepted
date: 2026-11-24
---
# State one outcome for a run and map it to the exit status

## Context

Four callers disagreed on exit status 4.
Failures lacked diagnostics and interrupted runs left temporary files.

## Decision

`Test::Mutation::Exit` assigns each outcome its exit status.
The table covers measurement, `exec`, and signal exits.
Each outcome apart from success ends standard error with one line of the catalog.
`Test::Mutation::Signals` watches these signals for the whole command, and the owning process releases the work once.
A signal outranks every other outcome, a refused plan included.

## Alternatives

Independent exit tables drifted.
A handler that dies at once can die inside a library that catches errors, or inside a release.

## Consequences

The command, merged shards, and the test assertion use `Outcome::of` to decide whether the requested threshold was met.
A shard defers its threshold until the complete measurement is available.
The saved report records the selection so the distinction survives a round trip.

## Confirmation

`t/contract/tables.t` observes every status, and `xt/discovery/faults.t` sends each signal at each phase.
Reconsider when a platform numbers a signal otherwise.
