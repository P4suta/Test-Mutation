---
status: proposed
date: 2026-11-23
---
# Merge shard reports only as one complete run

## Context

`--shard K/N` spreads a run over machines, and each machine writes a report.
A score threshold describes the whole run alone.
A merge that accepts any set of files passes the threshold on partial data.

## Decision

Every JSON report records its shard, the count of all mutants before the split, and a digest of their identifiers.
`mutation merge` rebuilds a result from the files alone.
It refuses a set unless every file names the same digest and the same `N`, and the parts 1 to `N` appear once each.
The merged result goes through the reporters and exit statuses of a run.

## Alternatives

A second analysis of the checkout at merge time needs the same options and the same tree as every shard.
Joining the files with a JSON tool, the status quo, checks nothing.

## Consequences

The report gains a `testMutation` key, which the schema allows.
Shards of different source states never merge, because their digests differ.

## Confirmation

`t/unit/merge.t` refuses a missing, repeated, or foreign part.
`t/e2e/merge.t` compares the merged statuses with an unsplit run.
Reconsider when a split by test duration replaces the split by position.
