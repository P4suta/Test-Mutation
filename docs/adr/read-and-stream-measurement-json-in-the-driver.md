---
status: proposed
date: 2026-11-27
---

# Read and stream measurement JSON in the driver

## Context

Decoding 8,064 candidate rows with JSON::PP took 0.52 seconds on the development Mac.
The same rows took 0.007 seconds with Cpanel::JSON::XS.
The two encoders produced identical canonical bytes for the fixture.

## Decision

Use Cpanel::JSON::XS in the driver to read reports, stream results and encode or decode SQLite rows.
Reject repeated object names so each status and input digest has one interpretation.
Readers disagree on duplicates as described in [RFC 8259 section 4](https://www.rfc-editor.org/rfc/rfc8259#section-4).

## Alternatives

JSON::PP ships with Perl and preserves the public pretty printer's layout.
An optional native backend would change decoding behavior between installations.

## Consequences

Driver installation requires a native JSON module alongside the SQLite driver.
The target interpreter runs the existing shim.
The public document API keeps the Boolean objects supported by [Cpanel::JSON::XS](https://metacpan.org/pod/Cpanel::JSON::XS).

## Confirmation

Compare streamed and parsed results with the public document, including Unicode, Booleans and empty selections.
Measure the cold and warm 8,064-mutant runs and install the distribution in an empty environment.
Revisit the dependency if it prevents installation on a supported driver or the measured workload no longer benefits.
