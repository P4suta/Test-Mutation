---
status: proposed
date: 2026-11-22
---
# Find mutation sites with `PPI` behind a site model

## Context

No static parser reads all Perl.
A mutation tool needs exact spans of operators and statements.

## Decision

`Permutl::Syntax::PPI` parses with `PPI` and converts the tree to parser-independent sites.
Mutators read sites and return replacement text.
A mutant replaces a span of the original text, and the serializer of the parser plays no part.
The analysis drops any span whose text differs from the token the parser reported.

## Alternatives

`tree-sitter-perl` recognizes class syntax, `isa`, and `^^`, which `PPI` reads as plain words.
Its Perl binding needs a native library and has no release since 2024.
Mutating the compiled tree gives exact semantics and loses the source columns that reports need.

## Consequences

Code in class syntax gets token-level mutators plus method bodies, and a misread region yields mutants that fail to compile.
The site model lets another parser replace `PPI` without touching a mutator.

## Confirmation

`t/assumptions/ppi-lossless.t` checks the round trip and the token locations on a corpus of modern syntax.
`t/unit/mutators.t` checks that every corpus mutant changes its span alone.
Reconsider when the binding matures or misread regions dominate a report.
