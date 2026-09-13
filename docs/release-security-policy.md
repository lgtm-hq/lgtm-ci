# Release security policy

This is the organisation-wide policy for every artifact an lgtm-hq repository
publishes through lgtm-ci reusables or alongside them. It states which evidence
each artifact class MUST carry, the order in which a release may write to the
outside world, which failures stop a release, which partial states are
tolerated, how a failed release is recovered, and how prereleases, backfills and
re-publishes are treated.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be read as in
RFC 2119. The policy prescribes ordering and evidence, not job names. Mechanical
enforcement in the reusables (defaults, wiring tests) is tracked in
[#963](https://github.com/lgtm-hq/lgtm-ci/issues/963); failure visibility in
[#964](https://github.com/lgtm-hq/lgtm-ci/issues/964); resume tooling in
[#966](https://github.com/lgtm-hq/lgtm-ci/issues/966). The first adopter is
py-lintro ([lgtm-hq/py-lintro#2634](https://github.com/lgtm-hq/py-lintro/issues/2634)).

## Why this document exists

Until now the release contract lived in three documents that describe mechanics,
not policy, and they contradicted the posture consumers advertised:

- [python-release-publish.md](python-release-publish.md) prescribed a caller-level
  `actions/attest-build-provenance` step **after** the PyPI upload with
  `continue-on-error: true`, which made provenance best-effort by design and put
  the attestation behind an irreversible write it could not repair.
- [workflow-contract.md](workflow-contract.md) ("Release failure reporting")
  defined failure-report deduplication for main-branch workflows but said nothing
  about what must be true before a tag publish's first irreversible write.
- Consumers claimed attestation for every release while their binaries carried
  none and their container images opted out of provenance and SBOM.
- Two states that already occur in practice had no rule: a channel publishing
  after an earlier channel failed (a red run that shipped everything), and a
  backfill republishing a historical version with different evidence than the
  tag build.

Without a written policy every consumer decides these questions per incident,
and the reusables cannot encode a rule that does not exist.

## 1. Mandatory evidence per artifact class

Every artifact in the table MUST carry every listed item, produced **before** any
irreversible publish of that release (see section 2). The producing tool is the
reference implementation; a consumer MAY use another tool that produces the same
verifiable evidence.

<!-- markdownlint-disable MD013 -->

| Artifact class | Mandatory evidence | Producing tool | Verification |
| -------------- | ------------------ | -------------- | ------------ |
| Python sdist and wheel | GitHub build-provenance attestation (SLSA v1 predicate) whose subject digests match the uploaded files; PyPI PEP 740 attestation via trusted publishing | `actions/attest-build-provenance` on the built dist; `pypa/gh-action-pypi-publish` with trusted publishing | `gh attestation verify <file> --repo <owner>/<repo>`; PyPI integrity page `https://pypi.org/integrity/<project>/<version>/<file>/provenance` |
| Platform binaries and archives | One GitHub build-provenance attestation per file; a `SHA256SUMS` manifest attached to the GitHub Release | `actions/attest-build-provenance` with the file as subject; `sha256sum` in the build job | `gh attestation verify <file> --repo <owner>/<repo>`; `sha256sum --check SHA256SUMS` |
| Container images | BuildKit provenance and SBOM pushed to the registry with the image index; GitHub attestation by image digest, pushed to the registry; keyless Cosign signature on the digest | `docker/build-push-action` with `provenance` and `sbom` enabled; `actions/attest-build-provenance` with `push-to-registry: true`; `cosign sign` keyless | `gh attestation verify oci://<image>@<digest> --repo <owner>/<repo>`; `cosign verify <image>@<digest> --certificate-identity-regexp '^https://github\\.com/<owner>/<repo>/\\.github/workflows/[^@]+@' --certificate-oidc-issuer https://token.actions.githubusercontent.com`; `docker buildx imagetools inspect <image>@<digest> --format '{{ json .Provenance }}'` and `'{{ json .SBOM }}'` |
| npm packages | GitHub build-provenance attestation on the packed tarball; npm-native provenance via `npm publish --provenance` under trusted publishing; every binary packed inside MUST have been verified against its GitHub attestation before packing | `actions/attest-build-provenance` on the `npm pack` output; `npm publish --provenance`; `gh attestation verify` in the pack step | `npm audit signatures`; `npm view <pkg>@<version> dist.attestations` |
| RubyGems | GitHub build-provenance attestation on the built `.gem` file; publish via RubyGems trusted publishing (OIDC), never an API key | `actions/attest-build-provenance` on the `gem build` output; `rubygems/release-gem` or `gem push` under trusted publishing | `gh attestation verify <file>.gem --repo <owner>/<repo>` |
| Homebrew tap formula | The formula MUST reference an artifact that carries its own class's evidence (a GitHub Release asset or PyPI sdist above) and pin its `sha256`; the tap dispatch is an irreversible write and follows section 2 | The consumer's release workflow dispatches the tap after the referenced artifact is published; the tap's handler computes and pins the digest | `brew fetch --formula <formula>`, then `sha256sum --check` of the cached download against the formula's pinned `sha256` (section 9); verify the referenced artifact with its own class's command |
| Release SBOM | An SBOM for the release artifacts, vulnerability-scanned at the consumer's declared severity gate, and attested | `reusable-sbom-release-upload.yml` (CycloneDX) with its scan gate; `actions/attest-build-provenance` or `actions/attest-sbom` | `gh attestation verify <sbom-file> --repo <owner>/<repo>` |

<!-- markdownlint-enable MD013 -->

A publish path that cannot produce an item in this table for its artifact class
is not a permitted publish path (section 7).

Evidence in the table is of two kinds, and section 2 treats them differently:

- **Build-time evidence** is produced from the built artifact before anything is
  published: every GitHub build-provenance attestation on a file or an image
  digest, BuildKit provenance and SBOM attached at image build, the release SBOM
  and its scan, and `SHA256SUMS`.
- **Publish-native evidence** is produced by, or can only exist after, the
  irreversible write itself: the PyPI PEP 740 attestation (created during the
  trusted-publishing upload), npm provenance (created by `npm publish
  --provenance`), the registry-side copy of a container attestation and the
  Cosign signature on a pushed digest, and the Homebrew formula's pinned digest.

## 2. Ordering rule

An **irreversible external write** is any of: a PyPI upload, an `npm publish`, a
registry tag push or manifest push, a GitHub Release creation or asset upload, a
Homebrew or mirror cross-repo dispatch, or any other write to a system outside
the workflow run that cannot be undone by the run itself.

1. Every irreversible external write MUST happen only after **all** builds and
   **all build-time evidence** (section 1) for the **whole** release have
   succeeded. Build-then-publish is the required shape: the build phase produces
   every artifact and every piece of build-time evidence, the publish phase
   writes them out. In particular the GitHub build-provenance attestation of a
   file or image MUST exist, and MUST have been verified against the artifact
   about to be written, before that artifact's irreversible write.
2. **Publish-native evidence** is produced by the publish step itself or in a
   job that `needs` it, and its failure is a blocking failure of that channel
   (section 3, rule 2): a PyPI upload whose PEP 740 attestation is rejected, an
   `npm publish --provenance` that fails, a registry attestation push or Cosign
   signature that fails after the image push, are channel failures, not
   acceptable degradations. For a container image the irreversible write is the
   registry push; the digest-bound GitHub attestation and Cosign signature
   follow it in a later job and MUST NOT carry `continue-on-error`.
3. An irreversible write MUST be the last step of its job. Nothing that can fail
   MAY run after it in the same job. A step that must follow a publish (a
   registry-side attestation push, a Cosign signature, a release-notes edit)
   belongs in a later job that `needs` the publishing job, so a failure there is
   a distinct failed job with the publish already complete and visible.
4. A build-time attestation MUST NOT be placed after the upload it attests. The
   "attest after upload with `continue-on-error`" layout is withdrawn (section
   10).
5. Channels (PyPI, GitHub Release, npm, container registry, Homebrew, RubyGems,
   mirrors) SHOULD be as atomic as practical: one job per channel, each consuming the
   already-built and already-attested artifacts, none rebuilding anything.

## 3. Blocking failures

1. Before the first irreversible write, **any** failure of a build, a
   verification gate (smoke test, install-from-index check, SBOM severity gate)
   or a mandatory attestation MUST stop the release with nothing published.
   No channel MAY start.
2. After the first irreversible write, a channel failure MUST stop every channel
   that has not started. Channels already complete are left as they are; they
   are not rolled back and MUST NOT be re-published.
3. A run that is red MUST NOT continue to publish remaining channels. Every
   channel job MUST depend (`needs`) on every job whose failure is a blocking
   failure for it, and MUST NOT use `if: always()` or `continue-on-error` to run
   past one.
4. Optional evidence does not exist in this policy: every item in section 1 is
   blocking. A consumer that wants a report-only check (a vulnerability scan
   with exit code 0) MAY add it as an extra, but it does not replace the
   blocking gate for its class.

## 4. Acceptable partial states

1. A release MAY be partially published only as the consequence of a failure
   **after** the first irreversible write (section 3, rule 2). No other partial
   state is acceptable; in particular a release MUST NOT be deliberately
   published channel by channel across separate runs under the same version.
2. A partial release is an **incident**. It MUST be visible as an open issue in
   the consumer repository, filed automatically by the failure reporting in
   [#964](https://github.com/lgtm-hq/lgtm-ci/issues/964), naming the version,
   the channels that completed and the channels that did not.
3. A partial release MUST be resolved by resuming the missing channels with the
   original artifacts (section 5, tier 2) or by a new patch version (tier 3).
   It MUST NEVER be resolved by rebuilding artifacts under the same version:
   the evidence already published binds that version to the original build.
4. Until resolved, the consumer SHOULD treat the version as not released
   (release notes not announced, no `latest` promotion beyond the channels that
   completed).

## 5. Recovery rule

Recovery has three tiers and one exemption. The tier is chosen by what has been
published and whether the original artifacts are still available and verifiable.

<!-- markdownlint-disable MD013 -->

| Tier | State | Action |
| ---- | ----- | ------ |
| 1 | Nothing published | Fix the workflow on the default branch, then re-run the release for the **original tag** through the corrected code. A tag-triggered run is pinned to the tagged commit, so a plain re-run replays the broken workflow; the recovery is the consumer's dispatchable release path on the default branch, taking the tag (`backfill_version` / `source-ref`) as input and building from the tagged commit. The tag is never moved. Artifacts are rebuilt because none were ever published; the version is unchanged. |
| 2 | Partially published | Resume the missing channels with the **exact original artifacts** from the run that published the first channel, each verified against its attestation before it is written. No rebuild. |
| 3 | Artifacts must change, cannot be recovered, or cannot be verified | Cut a **new patch version**. The partial version stays as published, its incident issue records the outcome, and no channel of it is completed or retried. |

<!-- markdownlint-enable MD013 -->

- Tier 2 resume MUST use the retained build artifacts of the original run
  (section 6) and MUST re-verify every artifact's attestation before publishing
  it; an artifact that fails verification moves the release to tier 3.
- Tier 2 resume SHOULD be a dispatchable workflow (tracked in
  [#966](https://github.com/lgtm-hq/lgtm-ci/issues/966)) rather than a manual
  procedure, so the resume itself is recorded and reviewable.
- Tier 1 re-run MUST go through the same gates as a fresh tag push; the
  dispatch path MUST NOT bypass any of them, and it MUST build from the tagged
  commit, not from the default branch's tree. A consumer whose release workflow
  has no such dispatch path cannot recover at tier 1 and MUST add one before
  relying on this policy (py-lintro's `backfill_version`/`backfill_ref` inputs
  are the reference shape).

**Prerelease exemption.** Prerelease tags (`aN`, `bN`, `rcN` and any other
PEP 440 or SemVer prerelease suffix) are exempt from recovery. A failed or
partial prerelease is abandoned and a new prerelease is cut. Prereleases still
MUST carry the evidence of section 1 and follow the ordering of section 2; the
exemption is only that nothing is resumed.

## 6. Artifact retention

1. Every build artifact a tier-2 resume depends on (dists, binaries, archives,
   SBOMs, image digests recorded in the run) MUST be retained for the
   **recovery window of 90 days** from the run that built it.
   For a container image the run artifact holds only the digest; the content
   lives in the registry. The pushed image MUST therefore remain available in
   the registry by digest for the window: it MUST be protected from
   registry cleanup (a retention tag, or an exemption in the consumer's prune
   configuration for digests younger than the window), or the image MUST be
   archived by digest as a run artifact (an OCI layout via `oras` or
   `docker save`) with the same 90-day retention. A digest the registry no
   longer serves moves the release to tier 3.
2. Consumers MUST set `retention-days: 90` on those artifacts' upload steps,
   or the repository-level artifact retention to at least 90 days. The
   reusables SHOULD apply this default for release builds
   ([#963](https://github.com/lgtm-hq/lgtm-ci/issues/963)).
3. Beyond the window a partial release falls to tier 3: with the original
   artifacts gone, only a new patch version is permitted.
4. Attestations and signatures are retained by their stores (GitHub
   attestations API, the registry, Sigstore's transparency log) independently
   of run artifacts and are not subject to this window.

## 7. Backfills and re-publishes

1. A manual backfill, a promotion (for example `ci-<run_id>` digests promoted
   to `main` or `sha-*` tags) or any other re-publish of an artifact MUST carry
   the same evidence as a tag build for that artifact class (section 1).
2. A publish path that cannot produce that evidence is not a permitted publish
   path and MUST be removed or repaired rather than used.
3. A backfill of a **historical** version MUST publish only to channels that
   version has never been published to; it MUST NOT overwrite an existing
   published artifact of that version (section 4, rule 3 applies).
4. A backfill SHOULD be auditable as such: its run and the artifacts it
   produced SHOULD be distinguishable from the original tag build (a dispatch
   input recorded in the run, a `backfill` label on any release note).

## 8. Scope of enforcement

1. This policy applies to every workflow that performs an irreversible external
   write on behalf of an lgtm-hq repository, whether the workflow is an lgtm-ci
   reusable, a consumer-local workflow calling a reusable, or a consumer-local
   workflow with no reusable at all.
2. Consumers that publish outside lgtm-ci reusables (for example py-lintro's npm
   and platform-binary lanes) are bound by the same rules and are responsible
   for their own compliance.
3. The reusables encode the policy as defaults and refuse configurations that
   violate it where they can (mechanical enforcement is
   [#963](https://github.com/lgtm-hq/lgtm-ci/issues/963)); a consumer that
   overrides a default to weaker evidence is out of policy regardless of whether
   the reusable rejects it.
4. Consumers SHOULD pin this policy's requirements in their own wiring tests
   (for example: every pushed image call passes `provenance` and `sbom`; no
   attestation step carries `continue-on-error`).

## 9. Verification

A third party verifies each artifact class with the fixed set of commands below,
one per item of mandatory evidence; together they cover every row of section 1.
`<owner>/<repo>` is the publishing repository; every command fails closed.

```bash
# Python dist (wheel or sdist)
gh attestation verify ./dist/<file>.whl --repo <owner>/<repo>

# Platform binary or archive
gh attestation verify ./<binary> --repo <owner>/<repo>
sha256sum --check SHA256SUMS

# Container image, by digest: GitHub attestation, Cosign signature, then the
# BuildKit provenance and SBOM attached to the index (both must be non-empty)
gh attestation verify oci://ghcr.io/<owner>/<image>@sha256:<digest> --repo <owner>/<repo>
cosign verify ghcr.io/<owner>/<image>@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/<owner>/<repo>/\.github/workflows/[^@]+@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
docker buildx imagetools inspect ghcr.io/<owner>/<image>@sha256:<digest> \
  --format '{{ json .Provenance }}'
docker buildx imagetools inspect ghcr.io/<owner>/<image>@sha256:<digest> \
  --format '{{ json .SBOM }}'

# npm package: the packed tarball's GitHub attestation, then npm provenance
gh attestation verify ./<pkg>-<version>.tgz --repo <owner>/<repo>
npm audit signatures

# RubyGems
gh attestation verify ./<gem>-<version>.gem --repo <owner>/<repo>

# Homebrew tap formula: the downloaded artifact must match the formula's pinned
# digest, and the artifact itself is verified with its own class's command above
brew fetch --formula <tap>/<formula>
expected=$(brew info --json=v2 <tap>/<formula> | jq -r '.formulae[0].urls.stable.checksum')
echo "${expected}  $(brew --cache <tap>/<formula>)" | sha256sum --check

# PyPI-side provenance (PEP 740)
curl -fsSL https://pypi.org/integrity/<project>/<version>/<file>/provenance | jq .

# Release SBOM
gh attestation verify ./<sbom>.cdx.json --repo <owner>/<repo>
```

A consumer's `docs/` SHOULD carry these commands with the placeholders filled in
for its own artifacts.

## 10. Superseded mechanics

- The recommendation in [python-release-publish.md](python-release-publish.md)
  ("Provenance attestation") to run `attest-build-provenance` after the PyPI
  upload with `continue-on-error: true` is **withdrawn** by section 2. The
  example workflow there is corrected mechanically in
  [#963](https://github.com/lgtm-hq/lgtm-ci/issues/963); until then it carries
  a superseded note.
- The "Release failure reporting" section of
  [workflow-contract.md](workflow-contract.md) continues to define how failures
  are reported; section 4 of this policy adds that a partial release is an
  incident that MUST be reported that way, and
  [#964](https://github.com/lgtm-hq/lgtm-ci/issues/964) extends the reporting
  to name the channel state.

## Related docs

- [python-release-publish.md](python-release-publish.md) — Python tag-push layout
- [workflow-contract.md](workflow-contract.md) — permissions, egress, failure reporting
- [actions/security.md](actions/security.md) — SBOM and signing actions
- [../SECURITY.md](../SECURITY.md) — vulnerability reporting and threat model
