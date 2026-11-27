---
status: proposed
date: 2026-11-26
---
# Launch tests with the interpreter settings of prove

## Context

A passing Perl test can fail during mutation measurement if its module paths or harness variables differ from those under `prove`.

## Decision

Build test and compile commands from a shared launch description.
Resolve library paths in the active copy.
Read project defaults from `.proverc` and derive taint handling from the Perl source handler used by `prove`.
Carry library paths and interpreter options to child Perl processes.

## Alternatives

Invoking `prove` for each mutant starts another harness and hides the individual test process.
Passing only interpreter switches leaves child processes without the requested libraries.

## Consequences

The driver can observe each test and enforce its time and output limits.
A project that requests a different test executor receives a diagnostic.

## Confirmation

Compare the observed environment, module paths, taint mode, and test result with the installed `prove`.
Recheck the comparison when the supported harness changes.
