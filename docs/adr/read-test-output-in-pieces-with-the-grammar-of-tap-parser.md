---
status: accepted
date: 2026-11-24
---
# Read test output in pieces with the grammar of TAP::Parser

## Context

The reader of test output passed eleven kinds of stream that `prove` fails.
One thread of the driver reads every job in pieces that end anywhere.

## Decision

`Test::Mutation::Tap` holds one table of line kinds, with the patterns and phases of `TAP::Parser`.
It takes pieces of any size and gives one verdict for every cut.
After a version line of 13 or 14 it decodes each line from UTF-8, as `prove` does for a process.
`TAP::Parser::YAMLish::Reader` judges a YAML block.

## Alternatives

One `TAP::Parser` for each process costs 48 microseconds, where the process costs 19 milliseconds.
The parser pulls its lines, so a pipe needs a second model of lines.
Its YAML reader never ends on a text at the indentation of the block.

## Consequences

`prove` drops an empty line that ends one read of the pipe.
Under `strict` its verdict then follows where the system cuts the output, so no function of the stream can match it.

## Confirmation

`xt/discovery/tap.t` compares the reader with `TAP::Parser` on 38,570 texts cut byte by byte, and on 30 processes.
Reconsider when `TAP::Parser` takes pieces.
