---
status: accepted
date: 2026-11-23
---
# Name the distribution Test::Mutation

## Context

The first name joined two words into one, and a reader of a module index learned nothing from it.
[The naming guide of PAUSE](https://pause.perl.org/pause/query?ACTION=pause_namingmodules) asks for a name that says what a module does, inside an existing namespace.

## Decision

The distribution is `Test-Mutation`, its modules live under `Test::Mutation`, and its command is `mutation`.
On 2026-11-23, the package index of CPAN held no `Test::Mutation`.

## Alternatives

`Devel::Mutation` sits next to `Devel::Cover`, but the guide keeps `Devel` for debugging inside Perl, and `Devel::Mutator` exists.
`App::Mutation` names a program without a library.
The first name costs nothing to keep and hides the purpose.

## Consequences

Every module, the command, and the files of a run change their names before the first release.
The main module exports the assertion for a test file.
The command name is a common word.

## Confirmation

`xt/distribution.t` checks the name of the distribution and the built command.
Reconsider when PAUSE refuses the namespace.
