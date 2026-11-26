---
status: proposed
date: 2026-11-26
---
# Resolve the selection before acquiring a workspace

## Context

An unmatched explicit selector can make an empty measurement look successful.
Copying or starting tests before a refusal wastes work and obscures the diagnostic.

## Decision

Resolve patterns, revisions, operands, suppression directives, identifier prefixes, and the shard in one selection.
Keep the matches and the original source digests.
Check report destinations before acquisition and compare the copied bytes before starting a test.

## Alternatives

Validation in individual commands duplicates selection rules.
Validation after copying delays a usage error and measures bytes that may differ from the listed changes.

## Consequences

A valid empty diff succeeds.
An unmatched explicit pattern names the input that needs correction.
The interpreter and Git can run during resolution.

## Confirmation

The selector matrix counts copies and test starts on refused inputs.
An integration test changes a source between analysis and copying.
Revisit the digest check when the runner accepts generated sources.
