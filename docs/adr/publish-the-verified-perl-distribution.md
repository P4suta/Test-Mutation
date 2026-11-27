---
status: proposed
date: 2026-11-28
---

# Publish the verified Perl distribution after merging its release proposal

## Context

Perl installers use the module version, while Git tags use three version components.
The Perl version `0.001` compares equal to `v0.1.0`.

## Decision

Release Please proposes the module versions and dated `Changes` entries together.
Merging the proposal selects its source commit and draft release.
The release gate verifies the distribution on Linux and macOS.
Attach the tested Linux archive to the draft and reserve its checksum before submitting it to the Perl Authors Upload Server.
Keep the registry credential in the publication environment.

## Alternatives

Rebuilding during publication would test different bytes.
An upload from every push would skip the release decision.

## Consequences

The [upload server](https://www.cpan.org/modules/04pause.html) reserves distribution filenames.
After an uncertain submission, compare the public archive with the recorded checksum before completing the GitHub release.

## Confirmation

Test version comparisons, mismatched artifacts, duplicate submissions, and recovery after an interrupted upload.
Revisit reconciliation when the registry offers authenticated upload receipts.
