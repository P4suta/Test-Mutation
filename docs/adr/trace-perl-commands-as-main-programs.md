---
status: proposed
date: 2026-11-26
---
# Trace Perl commands as main programs

## Context

A distribution can expose all its behavior through a command under `bin` or `script`.
Perl opens its main program before the module-loading hook can supply source text.

## Decision

Select Perl scripts in both directories by default.
An explicit source pattern replaces the defaults.
Match the program that Perl opens by device and inode.
A matching built command keeps the interpreter line that its installer wrote.
Record executed and executable lines through a source filter in the child process.
For an extracted program, use the source probe to map the interpreter's line numbers to physical source lines.

## Alternatives

Replacing the command with a wrapper changes the program name and data handle.

## Consequences

A distribution can test an installed command by its invocation path and see the results for its source.

## Confirmation

Exercise direct commands, nested sources, installed names, extracted programs, and unused subroutines.
Check the command's name, source filename, line number, data handle, and interpreter line.
