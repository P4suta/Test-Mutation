---
status: proposed
date: 2026-11-27
---

# Index measurements by source and mutant

## Context

Opening one of 7,723 mutants took 15.73 seconds to reparse sources and restore the report.

## Decision

SQLite indexes analysis by digest and settings, and mutant IDs by file and position.
Separate transactions publish dated verdicts and commit reusable observations before notifying listeners.
Scopes sort by completion time, then insertion order.
Merged observations keep shard timestamps in JSON.
Retry busy writes between pipe reads and deadline checks.
The driver verifies input fingerprints before reusing imported JSON records.
Report directories record project-relative paths and SHA-256 digests so copied or edited reports count as test inputs.
Target Perl needs no database driver.

## Alternatives

A separate JSON index requires coordinating interrupted writes across two files.
Individual JSON files need an index for prefix searches and inventory order.

## Consequences

The driver gains two runtime dependencies.
SQLite serializes writers and rolls back interrupted transactions.
The [SQLite documentation](https://www.sqlite.org/transactional.html) describes atomic commits, and the [Perl driver](https://metacpan.org/pod/DBD::SQLite) provides transaction support.

## Confirmation

Tests exercise concurrent writers and query a warm index while counting source parses and report reads.
Revisit the indexes if a lookup exceeds one second or 128 MiB on the fixed macOS workload.
