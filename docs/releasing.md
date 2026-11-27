# Release the distribution

Merging the release-please pull request into protected `main` authorizes publication.
Review its dated `Changes` entry and the proposed version before merging.
For example, Git tag `v0.1.0` corresponds to Perl version `0.001` and the archive `Test-Mutation-0.001.tar.gz`.
After the merge, the workflow checks the release commit and submits the verified archive to the Perl Authors Upload Server (PAUSE).
It compares the bytes on the Comprehensive Perl Archive Network (CPAN) with the verified archive before publishing the GitHub draft.

## Check the candidate before merging

With GitHub Actions access, run the credential check from `main`.
Run the release gate with the full 40-character candidate commit and its expected Perl version.
Review both runs before deciding whether to merge.

```sh
gh workflow run release-credentials.yml --ref main
gh workflow run release-gate.yml --ref main -f source_sha="$candidate_sha" -f version=0.001
```

The credential check confirms that the release-please GitHub App can read the repository.
For PAUSE it checks token delivery, local token format, the public `YASUNOBU` account, and indexing permissions for `Test::Mutation`.
PAUSE authenticates the token only during submission.

## Renew credentials

The Doppler project `test-mutation` stores `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_PRIVATE_KEY` in the `release_please` config and `PAUSE_TOKEN` in the `cpan` config.
The GitHub environments `release-please` and `cpan` each use a read-only `DOPPLER_TOKEN` for the corresponding config.
Before the upload token expires, sign in to PAUSE as `YASUNOBU`, select **Generate a New Token**, and replace `PAUSE_TOKEN` in the publishing config.
Run the credential check after rotation.

## Recover an interrupted submission

Use the original merge workflow run and the archive attached to its GitHub draft.
The attached `.sha256` file records a reserved submission that may still be pending at PAUSE.
Rerunning the failed job compares the digest of the public bytes with the original digest.
The [publication adapter](../xt/release-publish/README.md) describes the reconciliation exit codes.

While the public archive is missing, sign in as `YASUNOBU`, check the acknowledgement email, and inspect **Repair a Pending Upload**.
Wait for an accepted upload to reach the mirror and rerun the failed job.
If the status is unclear, ask the PAUSE administrators whether PAUSE accepted the exact filename.
If they confirm PAUSE received no submission, download the archive and its checksum from the draft.
Verify the checksum in the download directory with `shasum -a 256 -c Test-Mutation-0.001.tar.gz.sha256` for the example version.
An authorized maintainer can then submit the verified archive once through **Upload a file to CPAN**.
Run `gh run rerun "$merge_run_id" --failed` to confirm the public digest and finish the GitHub release.
Keep the tag, draft archive, and checksum intact throughout recovery.
