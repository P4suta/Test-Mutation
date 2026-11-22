---
status: proposed
date: 2026-11-22
---
# Select tests with a built-in line trace

## Context

Running every test for every mutant makes mutation testing slow.

## Decision

The unmodified run serves every target through the hook and records which test loaded which file.
In line mode the shim compiles targets with debugger statements and records each line that runs.
A mutant runs the tests that reached a line of its statement, shortest first, until one fails.
A statement without an observable runtime line falls back to every test that loaded the file.
A mutant run serves every target through the hook too.

## Alternatives

File-level selection needs no tracing and runs more tests for each mutant.

## Consequences

A mutant that no test reaches gets `NoCoverage` without running a test.
The compiler attributes an `elsif` condition to the line of its `if`, so the scope of a site is its whole statement.
Code inside the debugger callback leaves no trace, so a run of permutl on itself reports three detectable tracer mutants as `NoCoverage`.

## Confirmation

`t/shim/trace.t` fixes the recorded lines.
`t/e2e/selection.t` checks that line and file selection detect the same mutants on every fixture.
Reconsider when another statement runs without a recorded line.
