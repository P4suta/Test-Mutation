---
status: proposed
date: 2026-11-27
---

# Index measurements by source and mutant

## Context

Looking up one of 7,723 mutants took 15.73 seconds.

## Decision

SQLite indexes analysis inputs and mutant locations.
Separate transactions commit dated verdicts and reusable observations before notifying listeners.
Scopes sort by completion time, then insertion order.
Inspection and gap searches order observations by measurement time, then insertion order.
Shard timestamps preserve newer detections across merges.
Inconclusive rechecks preserve known gaps.
Retry busy writes between pipe reads and deadline checks.
The driver verifies input fingerprints before reusing imported JSON records.
Report directories record project-relative paths and SHA-256 digests so copied or edited reports count as test inputs.
Target Perl needs no database driver.

## Alternatives

A JSON index needs atomic updates across files.
Individual JSON files need an index for prefix searches and inventory order.

## Consequences

The driver gains two runtime dependencies.
SQLite serializes writers and rolls back interrupted transactions.
The [SQLite documentation](https://www.sqlite.org/transactional.html) describes atomic commits, and the [Perl driver](https://metacpan.org/pod/DBD::SQLite) provides transaction support.

## Confirmation

Tests exercise concurrent writers and count source parses and report reads during indexed lookups.
Revisit the indexes if a lookup exceeds one second or 128 MiB on the fixed macOS workload.
