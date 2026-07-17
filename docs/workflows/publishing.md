# Publishing and release workflows

Package publishing, release automation, and PR automation/security-comment
workflows. Full inputs/outputs/examples:
[reusable-workflows.md](../reusable-workflows.md#release) and
[reusable-workflows.md](../reusable-workflows.md#publishing-and-deployment).

## Release automation (two-stage model)

`reusable-release-version-pr.yml` runs on pushes to `main`; when releasable
commits land it opens/updates a release PR that bumps version files and
`CHANGELOG.md` (Keep a Changelog headings as of v0.43.1 — see
[release-changelog.md](../release-changelog.md)). `reusable-release-auto-tag.yml`
runs after that PR merges: it tags, publishes the GitHub release, and moves
the floating major version tag. Both accept `report-failures` (default
`true`) to open a dedup'd issue on failure via the shared
`reusable-main-failure-notifier.yml` mechanism — generalized to **any**
main-branch workflow (Docker publish, Pages deploy, …), one open issue per
`workflow-key` + branch.

Repos that bump several ecosystem manifests in one PR (for example
`package.json`, `VERSION`, a gemspec, and `pyproject.toml`) use
`reusable-release-multi-ecosystem.yml` with a `manifests` JSON map — same
App-token / changelog / failure-reporting family as version-pr. See
[workflow-contract.md](../workflow-contract.md#multi-ecosystem-release-contract).

Cargo workspaces that bump `Cargo.toml` on `main` use
`reusable-release-auto-tag.yml` with `version-source: cargo`.

## Package publish

`reusable-build-python-dist.yml` builds and uploads a dist artifact
(**outputs:** `version`, `package-name`); pair with a caller job using
`prepare-pypi-upload` + `pypa/gh-action-pypi-publish` (see
[python-release-publish.md](../python-release-publish.md)).
`reusable-publish-rust-release.yml` cross-compiles binaries via
`reusable-build-rust-binaries.yml` (strict tier, `rust-release` egress
preset) and uploads them to the release — see
[deployment.md](deployment.md#rust-release-binaries).

### reusable-publish-npm.yml

Publish Node.js packages to npm using **OIDC trusted publishing** (preferred)
or an optional legacy `npm-token` / `NODE_AUTH_TOKEN`.

```yaml
jobs:
  publish:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-npm.yml@main
    permissions:
      contents: read
      id-token: write
      attestations: write
    with:
      node-version: "24"
      dist-tag: "latest"
      provenance: true
      access: "public"
      dry-run: false
```

#### Trusted publishing recipe

1. On [npmjs.com](https://www.npmjs.com/), add a trusted publisher for the
   package: GitHub org/user, repository, the **caller** workflow filename
   (not `reusable-publish-npm.yml`), and allow the `npm publish` action
   (required for publishers created after 2026-05-20).
2. Grant `id-token: write` (and `attestations: write` when attesting the
   tarball). No long-lived npm token is required.
3. Use **Node 24** (default). Trusted publishing needs npm ≥ 11.5.1; Node 24
   ships a compatible npm. **Never** run `npm install -g npm` / in-place
   self-upgrade — it corrupts the Actions toolcache and breaks
   `npm publish --provenance` (missing sigstore).
4. Provenance is **automatic** under trusted publishing. The workflow still
   passes `--provenance` when `provenance: true` as explicit intent.
5. Egress preset `npm-publish` includes Sigstore OIDC
   (`oauth2.sigstore.dev:443`). See
   [workflow-contract.md](../workflow-contract.md#egress-presets).

Legacy token path: pass `secrets.npm-token` (maps to `NODE_AUTH_TOKEN`)
only for callers that have not migrated to trusted publishing.

**Inputs:** `node-version` (default '24'), `dist-tag` (default 'latest'),
`provenance` (default true), `access` (default 'public'), `dry-run`
(default false), `working-directory` (default '.').

**Secrets:** `npm-token` (optional, legacy).

**Outputs:** `published`, `version`, `package-name`, `tarball`. Requires
`contents: read`, `id-token: write`, `attestations: write`; must run on
GitHub-hosted runners for npm provenance / trusted publishing.

### reusable-publish-gem.yml

Publish Ruby gems to RubyGems using OIDC trusted publishing.

**Inputs:** `ruby-version` (default '3.3'), `gemspec` (auto-detected),
`dry-run` (default false), `working-directory` (default '.').

**Outputs:** `published`, `version`, `gem-name`, `gem-file`. Requires
`contents: read` and `id-token: write`.

### reusable-github-release.yml

Download a workflow artifact and create a GitHub Release with attached
assets via `gh release create`
(`scripts/ci/release/create-github-release.sh`).

```yaml
jobs:
  github-release:
    needs: publish
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-github-release.yml@main
    permissions:
      contents: write
    with:
      artifact-name: python-dist
      generate-release-notes: true
```

**Outputs:** `release-url`, `release-id`. Requires `contents: write`.

## PR automation and comments

<!-- markdownlint-disable MD013 -- workflow notes table -->

| Workflow | Notes |
| -------- | ----- |
| `reusable-semantic-pr-title.yml` | Normalizes CSV `types`/`scopes`; posts/clears a failure comment |
| `reusable-publish-file-breakdown.yml` | Grouped changed-files breakdown via `gh api --paginate` |
| `reusable-publish-artifact-preview.yml` | Sticky comment with a direct artifact download link (zip, sign-in required) |
| `reusable-publish-artifact-report.yml` | Posts the **contents** of a markdown file from a downloaded artifact |
| `reusable-pr-auto-assign.yml` / `reusable-pr-labeler.yml` | Auto-assign / auto-label PRs |

<!-- markdownlint-enable MD013 -->

## Security audit and AI review

`reusable-security-audit.yml` runs osv-scanner via the pinned py-lintro
image and uploads a comment artifact; pair with
`reusable-publish-security-audit-comment.yml` (same split pattern as
quality lint + publish-quality-summary). `reusable-ai-review.yml` installs
a pinned `lintro[ai]` from PyPI and posts one sticky, telemetry-rich PR
comment updated in place each run — `ANTHROPIC_API_KEY` is an lgtm-hq
org-wide secret, so callers just forward it. Both are non-blocking on
missing secrets/fork PRs; see the "PR Automation And Security" section of
[reusable-workflows.md](../reusable-workflows.md#pr-automation-and-security)
for hardening guarantees and the sticky-comment state format.
