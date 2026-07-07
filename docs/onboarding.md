# Consumer onboarding

Task-ordered guide from an empty `.github/workflows/` directory to a first
green build on lgtm-ci reusable workflows. Read top to bottom; each step
builds on the previous one.

Reference material lives in [workflow-contract.md](workflow-contract.md)
(inputs, permissions, egress presets) and
[reusable-workflows.md](reusable-workflows.md) (per-workflow details). This
guide covers only the setup path around the starter examples.

## 1. Pick a starter example

Choose by repository type and copy the example into your repository's
`.github/workflows/` directory. The full index with descriptions is in
[examples/README.md](../examples/README.md).

<!-- markdownlint-disable MD013 MD060 -- decision table; row text exceeds default line length -->

| Repository type                          | Starter example                                                                            | Copy as                        |
| ---------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------ |
| Python (uv/pytest)                       | [ci-python.yml](../examples/ci-python.yml)                                                 | `ci.yml`                       |
| Node.js with Vitest                      | [ci-node-vitest.yml](../examples/ci-node-vitest.yml)                                       | `ci.yml`                       |
| Node.js custom test command (Bun, monorepo) | [ci-node-custom.yml](../examples/ci-node-custom.yml)                                    | `ci.yml`                       |
| Rust workspace                           | [ci-rust.yml](../examples/ci-rust.yml)                                                     | `ci.yml`                       |
| Docker image (multi-arch, GHCR)          | [ci-docker.yml](../examples/ci-docker.yml)                                                 | `ci.yml`                       |
| Lint-only (tag/release, no PR comments)  | [ci-quality-only.yml](../examples/ci-quality-only.yml)                                     | `ci.yml`                       |
| Automated releases (version PRs)         | [release-version-pr.yml](../examples/release-version-pr.yml)                               | `release-version-pr.yml`       |
| Automated releases (tag + GitHub Release) | [release-auto-tag.yml](../examples/release-auto-tag.yml)                                  | `release-auto-tag.yml`         |
| Releases without package version files   | [release-version-pr-changelog-only.yml](../examples/release-version-pr-changelog-only.yml) | `release-version-pr.yml`       |
| PyPI publish on tag                      | [publish-python-release.yml](../examples/publish-python-release.yml)                       | `publish-python-release.yml`   |

<!-- markdownlint-enable MD013 MD060 -->

A typical repository takes one CI example plus, when it releases, the
version-PR and auto-tag pair.

Most examples pin `uses:` refs and `tooling-ref` to a specific lgtm-ci
release commit SHA with a `# vX.Y.Z` comment; examples that contain `<sha>`
placeholders must be filled in before use. The shipped pin ages; resolve the
current release SHA (see
[Resolve the release commit SHA](#4-resolve-the-release-commit-sha)) and
update both pins together before committing.

## 2. Prerequisites per capability

What each capability needs before its first run. Caller job `permissions:`
blocks are already correct in the starter examples; the authoritative matrix
is workflow-contract.md
["Permissions by mode"](workflow-contract.md#permissions-by-mode).

<!-- markdownlint-disable MD013 -- prerequisites table -->

| Capability                        | Caller permissions                                              | Extra setup                            |
| --------------------------------- | --------------------------------------------------------------- | -------------------------------------- |
| Quality / lint                    | `contents: read`, `packages: read` (pulls `ghcr.io/lgtm-hq/py-lintro`) | None                             |
| Quality / test PR summaries       | `contents: read`, `pull-requests: write` on the publish job     | None                                   |
| Tests / coverage                  | `contents: read`                                                | None                                   |
| Release version PR                | `contents: write`, `pull-requests: write`, `actions: read`, `issues: write` | GitHub App + two secrets (below) |
| Release auto-tag                  | `contents: write`, `actions: read`, `issues: write`             | GitHub App + two secrets (below)       |
| PyPI publish (OIDC)               | `contents: read`; `id-token: write` + `attestations: write` on the upload job | PyPI trusted publisher (below) |

<!-- markdownlint-enable MD013 -->

### Release workflows: GitHub App and secrets

`reusable-release-version-pr.yml` and `reusable-release-auto-tag.yml` create
commits, tags, and PRs with a GitHub App installation token
(`actions/create-github-app-token`), not the default `GITHUB_TOKEN` — so that
release pushes can trigger downstream workflows. Both reusables declare two
**required** secrets:

- `RELEASE_APP_ID`
- `RELEASE_APP_PRIVATE_KEY`

Copying a release example without these secrets fails at the
`Create GitHub App installation token` step. One-time setup:

1. **Create the App** (org owner): *Organization Settings → Developer
   settings → GitHub Apps → New GitHub App*. Disable webhooks; no callback
   URL needed.
2. **Repository permissions**: `Contents: Read and write`,
   `Pull requests: Read and write`, `Issues: Read and write` (issues cover
   the `report-release-failure` follow-up job).
3. **Install the App** on the organization (the reusables request the token
   with `owner: ${{ github.repository_owner }}`), scoped to the repositories
   that run release workflows.
4. **Generate a private key** on the App's settings page (downloads a `.pem`
   file) and note the numeric **App ID**.
5. **Set two secrets** on the consumer repository (or as org secrets shared
   across release repos):

   ```bash
   gh secret set RELEASE_APP_ID --repo <org>/<repo> --body "<app-id>"
   gh secret set RELEASE_APP_PRIVATE_KEY --repo <org>/<repo> < release-app.private-key.pem
   ```

The starter examples already forward both secrets to the reusable:

```yaml
secrets:
  RELEASE_APP_ID: ${{ secrets.RELEASE_APP_ID }}
  RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

### PyPI publish: trusted publisher

`publish-python-release.yml` uploads via OIDC (no API token secret).
Register your **consumer repository and workflow filename** as a PyPI
trusted publisher — not `lgtm-hq/lgtm-ci`. See
[python-release-publish.md](python-release-publish.md), "PyPI trusted
publishing".

## 3. Egress: audit first, then block

Reusable workflows default to `egress-policy: block` with a per-workflow
`egress-preset` baseline (canonical definitions:
`scripts/ci/lib/egress/presets.sh`; full preset table in
workflow-contract.md ["Egress presets"](workflow-contract.md#egress-presets)).
Repositories with standard toolchains usually pass on the preset alone. If
your build pulls from hosts outside the preset, the first run fails with
blocked connections. Recommended flow:

1. **Onboard in audit mode.** Set `egress-policy: audit` on the reusable
   `with:` block. Nothing is blocked; all outbound calls are recorded.
2. **Read the report.** Open the failing-or-passing job in the Actions UI —
   the StepSecurity harden-runner step summary links to the egress report
   listing every endpoint the job contacted.
3. **Build the allowlist.** Keep the preset and append only your extra hosts:

   ```yaml
   with:
     egress-policy: block
     egress-preset: quality
     allowed-endpoints-mode: append
     allowed-endpoints: >
       example-registry.internal:443
   ```

   `allowed-endpoints-mode: append` merges preset + extras (deduped). The
   default `replace` mode discards the preset when `allowed-endpoints` is
   non-empty — use it only when you want full manual control.

4. **Flip to block.** Set `egress-policy: block` (or remove the input — block
   is the default) and re-run. Repeat 2–3 if a host was missed.

Audit mode is a bring-up tool; production callers should run `block`.
Release publishing workflows enforce this: `reusable-publish-rust-release.yml`
hardcodes block and does not accept an `egress-policy` input.

## 4. Resolve the release commit SHA

The [action pinning policy](workflow-contract.md#action-pinning-policy)
requires pinning `uses:` refs and `tooling-ref` to the **release commit
SHA** with a `# vX.Y.Z` comment — not the tag name and not the annotated tag
object SHA. Resolve a release tag to its commit:

```bash
git ls-remote https://github.com/lgtm-hq/lgtm-ci 'refs/tags/v0.46.0^{}'
```

Or via the API (fetch the tag ref, then peel the annotated tag object to its
commit):

```bash
gh api repos/lgtm-hq/lgtm-ci/git/ref/tags/v0.46.0 --jq '.object.sha' |
  xargs -I{} gh api repos/lgtm-hq/lgtm-ci/git/tags/{} --jq '.object.sha'
```

Both print the release commit SHA (for v0.46.0:
`4aaefe64763b7841b6d92d94dc47185083d34c9a`). lgtm-ci release tags are
annotated; if a tag ever does not peel (lightweight tag), the `^{}` query
prints nothing and the `git/tags/{}` API call fails — in that case the tag
ref itself already points at the commit, so use
`git ls-remote https://github.com/lgtm-hq/lgtm-ci refs/tags/vX.Y.Z` or
`gh api repos/lgtm-hq/lgtm-ci/git/ref/tags/vX.Y.Z --jq '.object.sha'`
directly. Use the commit SHA in both places, always together:

<!-- markdownlint-disable MD013 -- pinned uses: line exceeds line length by design -->

```yaml
uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@4aaefe64763b7841b6d92d94dc47185083d34c9a # v0.46.0
with:
  tooling-ref: "4aaefe64763b7841b6d92d94dc47185083d34c9a" # v0.46.0
```

<!-- markdownlint-enable MD013 -->

**Repinning** to a newer release is the same procedure: resolve the new tag,
replace every `uses:` SHA and `tooling-ref` value plus their `# vX.Y.Z`
comments in one commit. A mismatched pair (workflow at one release, scripts
at another) is the most common source of drift bugs.

## 5. Align org ruleset check names

Reusable workflows report checks as `caller_job_id / inner_job_name`. If your
organization rulesets require named status checks, either update the ruleset
to the new check path or bridge with `reusable-required-check.yml` — see
workflow-contract.md
["Org ruleset check names"](workflow-contract.md#org-ruleset-check-names).
Ruleset documentation and sync tooling are tracked in
[lgtm-ci#301](https://github.com/lgtm-hq/lgtm-ci/issues/301).

## First green build checklist

- [ ] Starter example copied and `on:` triggers match your branch layout
- [ ] `uses:` SHA and `tooling-ref` repinned to the current release (step 4)
- [ ] Release repos: GitHub App installed, `RELEASE_APP_ID` and
      `RELEASE_APP_PRIVATE_KEY` secrets set (step 2)
- [ ] Publish repos: PyPI trusted publisher registered (step 2)
- [ ] Egress audited and allowlist appended where needed; policy on `block`
      (step 3)
- [ ] Org ruleset required checks match the new check paths (step 5)
