---
status: accepted
date: 2026-11-24
---
# Describe each setting once under one name

## Context

A setting had up to four names: a flag, a key in a section of the file, an attribute, and the words of the help.
Five places described it by hand, and the surfaces drifted apart.

## Decision

`Test::Mutation::Settings` holds one row for each setting: name, kind, type, default from the facts of a run, help, group, and surfaces.
The flag, the key, and the argument of a call come from the name: `--min-score`, `min-score`, `min_score`.
The file has no sections.
Each surface decodes what the user wrote into a layer that keeps the spelling, and `resolve` alone builds a `Config`.
The nearest layer gives the whole value, and the table lists the only interactions.
The file leaves out `root` and `config`, which find the file.

## Alternatives

Getopt::Long accepts abbreviations and words its refusals itself.
Sections keep a second name for each setting.

## Consequences

A new setting is one row, and its flag, key, argument, help line, and type follow.

## Confirmation

`t/contract/arguments.t`, `settings.t`, and `pairs.t` try each name and value on each surface.
Reconsider if a surface needs a setting that the others lack.
