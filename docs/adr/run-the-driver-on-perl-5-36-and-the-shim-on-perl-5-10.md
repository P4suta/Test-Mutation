---
status: proposed
date: 2026-11-22
---
# Run the driver on Perl 5.36 and the shim on Perl 5.10

## Context

The driver analyzes sources and schedules tests.
The shim runs inside every test process of the project, and such projects often use an older Perl than a new tool prefers.

## Decision

The driver requires Perl 5.36.
The shim is one file that loads core modules alone and runs on Perl 5.10.
The driver copies the shim into its work directory, so the project's Perl needs no installation, and `--perl` names the test interpreter.

## Alternatives

A Rust binary with a tree-sitter parser recognizes more syntax and has no Perl floor.
It leaves the usual installation path of Perl tools and closes the tool to extension in Perl.

## Consequences

A project on an older Perl needs a second interpreter for the driver.
Linux and macOS are the supported platforms, because the pool relies on `fork` and process groups.

## Confirmation

`t/shim/` passes on Perl 5.34 and 5.44, and `t/e2e/second-perl.t` runs a 5.44 driver with tests on 5.34.
A run on Perl 5.10 itself is still missing, so the decision stays proposed.
Reconsider when a project needs an older Perl or a platform without `fork`.
