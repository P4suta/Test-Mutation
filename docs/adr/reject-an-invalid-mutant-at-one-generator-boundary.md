---
status: accepted
date: 2026-11-24
---
# Reject an invalid mutant at one generator boundary

## Context

Each mutator kept its own guards, and the generator checked nothing.
`call-swap` wrote `all` where the file imports `any` alone.
`return-value` removed the start of a here-document and left its text behind as code.
A run counted the resulting failures as detected mutants.

## Decision

The generator passes every proposed change through the rules of `Test::Mutation::Mutant::Validity`.
A change keeps its line count, a here-document whole, a declaration that later code names, and a statement that holds a value alone.
A change that calls another function gets a name that the file resolves.
Two changes with one resulting text count once.
The generator returns each refused change with its mutator, line, and rule.

## Alternatives

Guards in each mutator leave the next mutator without them.
A compile of every mutant costs one process for each, and a call that fails at run time passes it.

## Consequences

The rules read the span and never the replacement, so a change that wraps its span needs a narrower rule.

## Confirmation

`t/unit/validity.t` holds each rule, and `t/unit/mutators.t` compiles each swapped call with Perl.
Reconsider when a rule refuses a provably valid change.
