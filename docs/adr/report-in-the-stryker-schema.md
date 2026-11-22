---
status: proposed
date: 2026-11-22
---
# Report in the Stryker schema

## Context

A mutation report needs a source view with every mutant in place.
The Stryker projects publish a report schema and a viewer that tools for several languages share.

## Decision

The JSON report follows version 2 of `mutation-testing-report-schema`.
The HTML report is one file that embeds the data and version 3.9.0 of the `mutation-testing-elements` viewer.
A test pins the digest of the bundled viewer file.
Each test file appears as one test, because the runner treats a test file as a unit.
Reports go to `permutl-report/`, because the artifact upload of GitHub Actions leaves hidden directories out by default.

## Alternatives

A custom page gives full control over the presentation and adds a viewer to maintain.

## Consequences

The distribution ships a third-party script under the Apache License 2.0, and `THIRD_PARTY_NOTICES.md` records it.
A newer viewer needs a manual update of the file and its digest.

## Confirmation

`t/unit/report-json.t` fixes the mapping, and `t/unit/report-html.t` checks the digest and the escaping of the embedded data.
Validation with the published schema file and a rendering check in a browser are still missing, so the decision stays proposed.
