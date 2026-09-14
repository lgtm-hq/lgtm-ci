# Release Recovery Runbook

Recovering a partially published release without rebuilding, using the
original tag and the original attested artifacts. Tiers come from the
[release security policy](release-security-policy.md).

## Which tier applies

- **Tier 1 — transient infrastructure:** automatic; the auto-rerun reusable
  already covers the known signatures. Nothing to do here.
- **Tier 2 — resume (this runbook):** the publish stopped mid-flight on a
  real but fixable defect (workflow bug fixed on the default branch, transient
  registry outage that exhausted retries). The recovery workflow publishes
  **only the missing channels** from the **original run's attested
  artifacts**, against the **original immutable tag**. Nothing is rebuilt —
  same version, same bytes.
- **Tier 3 — new patch version:** required when any published bytes differ
  from the attested artifacts, when a PyPI upload landed partially (a PyPI
  version is burned on first upload and can never be resumed), or when the
  tag moved. The recovery workflow refuses with this guidance; do not force
  it.
- **Prereleases are never recovered:** abandon the prerelease and cut a new
  one.

## Finding the inputs

```bash
# The original publish run (the one that failed):
gh run list --repo <owner>/<repo> --workflow publish-pypi-on-tag.yml --limit 5
# Its head SHA and artifacts:
gh run view <source-run-id> --repo <owner>/<repo> --json headSha,conclusion
gh api "repos/<owner>/<repo>/actions/runs/<source-run-id>/artifacts" --jq '.artifacts[].name'
# Confirm the tag still points at that SHA (it must):
gh api "repos/<owner>/<repo>/commits/<tag>" --jq '.sha'
```

## Running a recovery

Wrap `reusable-release-recover.yml` in a `workflow_dispatch` workflow (see
[examples/release-recover.yml](../examples/release-recover.yml)). Always run
`dry-run: true` first:

- The dry run verifies the tag and the downloaded artifacts (sha256 +
  attestation), probes every configured channel, and posts the missing set to
  the job summary. It changes nothing.
- If the dry run reports a mismatch between a published asset's digest and
  the attested artifact — stop. That is tier three: cut a new patch version.
- Otherwise re-run with `dry-run: false`. Only the missing channels run;
  complete channels are skipped, not re-run. npm and the GitHub Release
  resume through the same scripts the tag path uses (the #965 guard and
  `verify-artifacts` / `publish-set.sh` / `verify-published.sh` set, and
  `create-github-release.sh`), so the resume path cannot drift from the tag
  path. The npm resume is a live publish and applies the same fail-closed
  preconditions as the tag path: `npm-entry-workflows` must name the
  recovery entry workflow (registered as an npm trusted publisher),
  `signer-repo`/`signer-workflow` and the manifest must be set, and
  `npm-access` must be `public`. The Homebrew dispatch is re-sent only when
  the tap lacks the version.
- Dispatch the recovery from the **default branch**. It runs the
  default-branch workflow code (the reusable pins `github.workflow_sha`,
  never the tag), which is how a workflow fix merged after the release
  applies to it.

On completion the recovery run updates the release-failure issue the notifier
(#964) opened with the outcome table, and closes it when the recovery
succeeded.

## Retention window

Recovery needs the original artifacts. Release-artifact retention defaults to
**90 days** (`reusable-build-python-dist.yml` `artifact-retention-days`,
`reusable-build-rust-binaries.yml` `retention-days`); a recovery attempt past
the window fails at the download step — at that point the only copies are the
published ones and a tier-three release is the only option. Consumer-local
build workflows must set the same 90-day retention to keep tier 2 available.
