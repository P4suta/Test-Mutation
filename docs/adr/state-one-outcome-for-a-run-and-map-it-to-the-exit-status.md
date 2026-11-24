---
status: accepted
date: 2026-11-24
---
# State one outcome for a run and map it to the exit status

## Context

Four places held exit numbers, and status 4 meant both a run without a score and a failed command.
Statuses 1, 3, and 4 printed no line, and a signal outside the pool left the work behind.

## Decision

`Test::Mutation::Exit` is the one table of exit statuses, and code names an outcome to get its number.
It holds 0 to 6, 125 for a failure of `exec` itself, and 128 plus the number of HUP, INT, QUIT, PIPE, and TERM.
Each outcome apart from success ends standard error with one line of the catalog.
`Test::Mutation::Signals` watches these signals for the whole command, and the owning process releases the work once.

## Alternatives

A number at each caller drifts, as status 4 did.
A handler that dies at once can die inside a library that catches errors, or inside a release.

## Consequences

The command still decides the outcome in the order of its checks until the planned `Outcome::of` takes over.

## Confirmation

`t/contract/tables.t` observes every status, and `xt/discovery/faults.t` sends each signal at each phase.
Reconsider when a platform numbers a signal otherwise.
