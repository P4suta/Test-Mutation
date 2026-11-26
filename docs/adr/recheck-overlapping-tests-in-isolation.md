---
status: proposed
date: 2026-11-26
---
# Recheck overlapping tests in isolation

## Context

Concurrent tests can fail when they compete for a port, file lock, or database.

## Decision

Apply the project's `testrules.yml` through the scheduler used by `prove`.
When an original test fails in parallel and passes alone, repeat the suite in separate directories.
Keep the requested jobs if the copies pass and use one job if the conflict persists.

Repeat an overlapping failure or timeout in a fresh mutant slot while other invocations of the same test wait.
If the repeat passes, report the conflict and serialize later invocations of that test.
An independent reproducible failure can still detect the mutant.

## Alternatives

Serializing the entire measurement prevents independent tests from using the available jobs.
Accepting the first failure can blame a mutant for an unavailable shared resource.

## Consequences

A contested failure costs one verification.
Projects can declare resource constraints in advance to avoid the retry.

A parallel rule in `t/testrules.yml` orders Test::Mutation's unit and shim tests before nested measurements.
A focused assertion can detect a broken compiler transition before a nested run reaches its deadline.

## Confirmation

Tests cover local directories, an external lock, independent assertions, and the distribution's suite order.
