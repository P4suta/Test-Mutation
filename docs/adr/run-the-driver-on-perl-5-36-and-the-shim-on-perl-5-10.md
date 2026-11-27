---
status: proposed
date: 2026-11-22
---
# Run the driver on Perl 5.36 and the shim on Perl 5.10

## Context

The driver analyzes sources and schedules tests.
The shim runs inside every test process, and many projects use an older Perl than a new tool prefers.

## Decision

The driver requires Perl 5.36.
The shim is one file that loads only core modules and runs on Perl 5.10.
The driver copies the shim into its work directory, so the project's Perl needs no installation, and `--perl` names the test interpreter.

## Alternatives

A Rust binary with a tree-sitter parser recognizes more syntax and has no Perl floor.
It leaves the usual installation path of Perl tools and closes extension in Perl.

## Consequences

A project on an older Perl needs a second interpreter for the driver.
Linux and macOS are the supported platforms, because the pool relies on `fork` and process groups.

## Confirmation

`mise run shim-mutation` measures the shim on Perl 5.10, 5.14, and 5.18.
`t/e2e/second-perl.t` compares the two interpreters' verdicts.
The CI driver matrix spans Perl 5.36 through 5.42.
Reconsider when a supported platform lacks `fork`.
