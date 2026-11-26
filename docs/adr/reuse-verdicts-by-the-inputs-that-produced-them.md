---
status: proposed
date: 2026-11-26
---

# Reuse verdicts by the inputs that produced them

## Context

A test can read data files, environment variables and modules outside the distribution.
A new module earlier in Perl's include path can shadow a module that the previous test loaded.

## Decision

Fingerprint the interpreter, observers, include directories, launch settings, environment and project support files.
Key each test by its source and compiled targets.
A kill depends on its detecting test.
A surviving mutant depends on every covering test.
Check a sample against fresh measurements on each reuse and discard the store if a verdict differs.
Keep only digests of environment values.

## Alternatives

Recording only loaded modules misses a new file earlier in the search path.
Hashing all target contents into one run key invalidates independent tests.

## Consequences

The first run reads the external libraries to establish their contents.
A later selection can reuse the first run's verdicts.

## Confirmation

The differential tests change one input at a time and compare the result with an uncached run.
The sampling test changes a stored verdict and checks the fresh result and exit status.

## Related decisions

[Earlier cache decision](key-a-cached-result-by-the-files-it-depends-on.md)
