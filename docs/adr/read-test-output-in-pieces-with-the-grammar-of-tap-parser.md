---
status: accepted
date: 2026-11-24
---
# Read test output in pieces with the grammar of TAP::Parser

## Context

The reader of test output passed eleven kinds of stream that `prove` fails, such as a second plan.
One thread of the driver reads the output of every job, in pieces that end anywhere.

## Decision

`Test::Mutation::Tap` holds one table of the kinds of line, with the patterns and the phases of `TAP::Parser`.
It takes pieces of any size and gives one verdict for every cut.
`TAP::Parser::YAMLish::Reader` judges a YAML block.

## Alternatives

One `TAP::Parser` for each test process costs 48 microseconds, where the process costs 19 milliseconds.
Each line costs the parser 5.3 microseconds and the table 1.8.
The parser pulls its lines, so a pipe needs a second model of lines.
Its YAML reader never ends on a text at the indentation of the block.

## Consequences

The table follows `TAP::Parser` 3.52 on a text.
`prove` also decodes UTF-8 after a version line and drops an empty line at the end of each read.

## Confirmation

`xt/discovery/tap.t` compares the reader with `TAP::Parser` on 38,570 streams, each cut byte by byte.
`t/unit/tap.t` states 132 verdicts by hand, and `TAP::Parser` confirms 122.
Reconsider when `TAP::Parser` takes pieces.
