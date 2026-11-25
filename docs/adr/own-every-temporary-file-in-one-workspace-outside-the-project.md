---
status: proposed
date: 2026-11-26
---
# Own every temporary file in one workspace outside the project

## Context

Measurements must support read-only checkouts.
Tests can leave background processes and altered files.

## Decision

Keep the reference tree, job slots, and task files in one private directory outside the checkout.
Preserve the checkout basename for tests that inspect it.
Reclaim marked workspaces after their exclusive lock expires, except those retained by `--keep-work`.
Identify escaped descendants by an inherited shared lock.
Discard unrestorable slots and report their verdicts as inconclusive.

## Alternatives

Project-local storage requires write access.
The operating system reuses process IDs.

## Consequences

Concurrent runs have independent lifetimes.
Descendant lookup requires procfs on Linux or `lsof` on macOS.

## Confirmation

Tests cover concurrent runs, escaped descendants, interruption, and same-size rewrites with restored timestamps.
Revisit descendant lookup for each new operating system.
