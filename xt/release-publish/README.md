# Verify a public distribution archive

The Perl Authors Upload Server (PAUSE) accepts distribution archives for the Comprehensive Perl Archive Network (CPAN).
Compile the adapter from the protected release controller before fetching credentials.
The adapter uses the runner's OpenSSL, jq, and curl 8.3 or later.

```sh
rustc --edition=2021 -D warnings xt/release-publish/pause.rs -o "$RUNNER_TEMP/pause"
```

`pause preflight` checks the format of `PAUSE_TOKEN` locally.
It reads the public account record for `YASUNOBU` and the indexing permissions for `Test::Mutation` from MetaCPAN.
An unclaimed main package can receive first-come permission on its first indexed release.
PAUSE assigns permissions according to its [operating model](https://pause.perl.org/pause/query?ACTION=pause_operating_model).

PAUSE exposes one token-authenticated operation, `POST https://pause.perl.org/api/upload`.
The endpoint has no version component.
It accepts the `upload:distributions` scope, a Bearer token, and a multipart field named `file`.
PAUSE checks the token's expiry, revocation, and permitted IP addresses through [token validation](https://github.com/andk/pause/blob/74add4411a0a1fc635c55b4234e480720c5175ae/lib/pause_2026/PAUSE/API/Controller/Root.pm#L47-L77).
The read-only preflight leaves authentication unverified because the [token routes](https://github.com/andk/pause/blob/74add4411a0a1fc635c55b4234e480720c5175ae/lib/pause_2026/PAUSE/API.pm#L32-L37) expose only submission.

`pause publish ARCHIVE SHA256` verifies the local archive and checks the public directory for `YASUNOBU`.
If the published bytes match, the command succeeds before accessing the credential.
For a missing archive, the release workflow records its intent to submit the original digest before authorizing one upload.
The adapter recognizes HTTP 200 with `{"result":"Upload succeeded"}` as the [acknowledgement of submission](https://github.com/andk/pause/blob/74add4411a0a1fc635c55b4234e480720c5175ae/lib/pause_2026/PAUSE/API/Controller/Upload.pm#L120-L138).

`pause reconcile ARCHIVE SHA256` checks the exact archive under `authors/id/Y/YA/YASUNOBU/`.
It returns 0 for a matching SHA-256 digest, 3 for HTTP 404, and 1 for an error or conflicting bytes.
After a duplicate response, an interrupted request, or a lost acknowledgement, repeat the read-only reconciliation with the original archive and digest.
If the archive stays absent, inspect the PAUSE upload acknowledgement and pending uploads before authorizing any further submission.
