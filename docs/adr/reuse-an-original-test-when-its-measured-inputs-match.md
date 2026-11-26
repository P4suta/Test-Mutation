---
date: 2026-11-26
status: proposed
---

# Reuse an original test when its measured inputs match

## Context

A local edit should cost a developer the original tests whose evidence it affects.
The baseline command must also serve a later mutation run.

## Decision

Store the passing test's duration, observed source lines, breakable lines, external library paths and source digests with the fingerprint of its measured inputs.
Mark an observation neutral when the test compiled no target.
An interrupted or abnormal observation supplies no reusable fact.
## Alternatives

Replaying every original test would reproduce any shared filesystem effects, but a change confined to one tested module would still cost a full baseline.

## Consequences

A baseline that writes project files must run again to reproduce its effects.

Validate stored observations before acquiring a workspace.
A baseline request with complete, current evidence returns immediately.
A mutation run still measures its sample of cached verdicts.

## Confirmation

Verify the behavior by changing a test, a loaded target and a shared project input independently.
Count the originals that run and the copies, scans and processes used by an unchanged baseline.
