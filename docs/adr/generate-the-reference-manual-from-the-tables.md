---
status: proposed
date: 2026-11-26
---
# Generate the reference manual from the tables

## Context

People consult `perldoc mutation` after installation and read the same command in a source checkout.
A setting documented independently from its implementation can give different answers in those two places.

## Decision

Track generated reference sections in the executable's Plain Old Documentation (POD).
Generate each section from the command, configuration, status, environment, or exit table that defines the behavior.
Write the introduction and examples by hand.
Execute the public examples with the distributed command or Perl API.

## Alternatives

Generating documentation during installation keeps generated text out of source control.
It leaves a source checkout without the manual that users receive.

## Consequences

Changing a table requires regenerating the installed command with `xt/bin/generate-manual`.
The freshness check compares the complete reference byte for byte.

## Confirmation

`xt/manual.t` rejects missing, repeated, and stale sections and executes the command and Perl examples.
`xt/literals.t` compares environment lookups with the table and manual.
Reconsider the sections when an API needs guidance beyond its governing table.
