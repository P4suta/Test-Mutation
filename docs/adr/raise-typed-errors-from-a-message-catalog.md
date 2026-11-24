---
status: accepted
date: 2026-11-24
---
# Raise typed errors from a message catalog

## Context

Each error was a string from `die`, worded where the code raised it.
A string carried no kind, so four places guessed an exit status from it.

## Decision

`Test::Mutation::Message` holds each message of a failure or a warning once: identifier, kind, text with `{name}` slots, and a sentence for the manual.
`Test::Mutation::Error::raise` dies with the kind `usage` or `environment`, the identifier, and the filled text.
`Test::Mutation::Try::attempt` holds the one `eval` of the driver.
An exception without a type ends the command as an internal error with status 6.
The shim runs on Perl 5.10 without the catalog and copies its two lines.

## Alternatives

A class for each error scatters the words and gives the manual no list.
A module of exception classes adds a runtime dependency.
A prefix on each string leaves kind and identifier unchecked.

## Consequences

A new failure needs a row of the catalog and a case that raises it.

## Confirmation

`xt/literals.t` refuses words of its own in a `die`, an unknown or unused identifier, a differing shim copy, and a second `eval`.
`t/contract/messages.t` raises every identifier.
Reconsider when a value outgrows a slot.
