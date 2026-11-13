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

### reusable-publish-npm-set.yml

Publish an ordered **set** of Node.js packages to npm using **OIDC trusted
publishing** — platform packages first, meta package last, idempotent on
re-runs, with pre-publish artifact verification and post-publish registry
verification (#965). A single package is a set of one (`order: "."`). The
single-package `reusable-publish-npm.yml` was removed in v0.97.0 (#1526; see
[migration/v0.97.md](../migration/v0.97.md)) and the old `publish-npm`
composite action is removed.

```yaml
jobs:
  publish:
    needs: [stage] # uploads the npm-dist artifact (packages + SHA256SUMS)
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-npm-set.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      id-token: write
      attestations: write
    with:
      packages-dir: npm-dist
      artifact-name: npm-dist # staged in another job: jobs do not share disks
      order: '["darwin-arm64", "linux-x64", "meta"]' # meta last
      dist-tag: "latest"
      dry-run: false
      entry-workflows: .github/workflows/publish-npm-set.yml
      # Live publishes fail closed without entry-workflows, checksums-file,
      # signer-repo and signer-workflow. The manifest path is workspace-
      # relative; the entries inside it are relative to packages-dir.
      checksums-file: npm-dist/SHA256SUMS
      files-to-verify: "[]" # empty: every file the manifest lists
      signer-repo: <owner>/<repo>
      signer-workflow: .github/workflows/build-binaries.yml
      # Optional: bind the publish job to a deployment environment (approval
      # gate). A `uses:` job cannot carry `environment:` itself; empty runs
      # without one.
      environment: npm
      tooling-ref: "<sha>"
```

Pin `@<sha>` and `tooling-ref` to the same lgtm-ci release commit with a
`# vX.Y.Z` comment (see [README.md](README.md)). Full caller layout:
[examples/publish-npm-set.yml](../../examples/publish-npm-set.yml).

#### Trusted publishing recipe

1. On [npmjs.com](https://www.npmjs.com/), add a trusted publisher for the
   package: GitHub org/user, repository, the **caller** workflow filename
   (not `reusable-publish-npm-set.yml`), the environment name when the call
   passes `environment` (leave it blank otherwise — the reusable's job
   carries exactly the environment the input names), and allow the
   `npm publish` action (required for publishers created after 2026-05-20).
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

There is no npm-token path: publishing runs under trusted publishing only.

**Inputs:** `packages-dir` and `order` (required); `dist-tag` (default
'latest'), `dry-run` (default true), `provenance` (default true), `access`
(default 'public'), `max-attempts` (default 3), `artifact-name`; the live
publish gate `entry-workflows`, `checksums-file`, `files-to-verify` (default
'[]'), `signer-repo`, `signer-workflow`; `post-publish-verify` (default
true), `propagation-attempts` (default 30), `propagation-delay` (default 30),
`smoke-command`; `node-version` (default '24'), `environment`, `job-name`
(default 'Publish npm package set'), `timeout-minutes` (default 30),
`runner-image`; and the shared `tooling-ref`, `tooling-ref-allow-divergence`
and egress inputs (`egress-policy`, `egress-preset` default 'npm-publish',
`allowed-endpoints`, `allowed-endpoints-mode`).

**Secrets:** `LGTM_CI_TOOLING_TOKEN` (optional; tooling checkouts from a
private mirror).

**Outputs:** `published` (a JSON array, one `{name, version, status,
integrity}` entry per package; read it with `fromJSON(... || '[]')`) and
`dist-tag-drift`. Requires `contents: read`, `id-token: write`,
`attestations: write`; must run on GitHub-hosted runners for npm provenance /
trusted publishing.

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
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-github-release.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
    with:
      artifact-name: python-dist
      generate-release-notes: true
      # checksums: true          # default; attaches SHA256SUMS (shipped or generated)
      # immutable-assets: true   # default; a rerun never overwrites different bytes
```

`checksums` (default `true`) attaches a `SHA256SUMS` manifest: one shipped inside
the artifact (`reusable-build-python-dist.yml` writes it) is attached as is,
otherwise one is written from the assets. `immutable-assets` (default `true`)
makes a rerun converge without ever overwriting a published asset: an asset
already published with the same digest is skipped, one that never landed is
uploaded, and one whose published bytes differ (or whose digest the API cannot
report) fails the job with the recovery rule of the
[release-security policy](../release-security-policy.md) (section 4).

**Outputs:** `release-url`, `release-id`. Requires `contents: write`.

## PR automation and comments

<!-- markdownlint-disable MD013 -- workflow notes table -->

| Workflow                                                  | Notes                                                                                                                             |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `reusable-semantic-pr-title.yml`                          | Normalizes CSV `types`/`scopes`; posts/clears a failure comment                                                                   |
| `reusable-publish-file-breakdown.yml`                     | Grouped changed-files breakdown via `gh api --paginate`                                                                           |
| `reusable-publish-artifact-preview.yml`                   | Sticky comment: shared heading (`title`, `upstream-result`), download link (zip, sign-in required), footer                        |
| `reusable-publish-artifact-report.yml`                    | Posts the **contents** of a markdown file from a downloaded artifact, wrapped in the shared heading and footer unless `raw: true` |
| `reusable-pr-auto-assign.yml` / `reusable-pr-labeler.yml` | Auto-assign / auto-label PRs                                                                                                      |

<!-- markdownlint-enable MD013 -->

### Which comment is which

Three different things can leave a coverage-related comment on a PR. Give each
its own `marker` so they never overwrite each other:

| Comment                             | Owner                                                                                      | How to disable                                                               |
| ----------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| Coverage **percentage** table       | `reusable-coverage.yml` (and the language test facades that publish a table)               | Set `publish-test-summary: false`, or call the read-only `*-run.yml` variant |
| HTML coverage report **download**   | `reusable-build-artifact.yml` uploads it, `reusable-publish-artifact-preview.yml` links it | Do not call the preview publisher (or pass an empty `artifact-url`)          |
| zip / generated-report **contents** | `reusable-build-artifact.yml` uploads it, `reusable-publish-artifact-report.yml` posts it  | Do not call the report publisher                                             |

- `reusable-coverage.yml` is the only workflow that owns the percentage
  comment. The two artifact publishers never compute or restate coverage; they
  only link to, or relay, files that `reusable-build-artifact.yml` produced.
- Both artifact publishers share one frame: `## <title>`, an optional
  `### 📊 Status:` line from `upstream-result` (`success`, `failure`,
  `cancelled`, `skipped`), the content, and a
  `<sub>Generated by <workflow> workflow</sub>` footer.
  `title` defaults to `artifact-name`.
- `reusable-publish-artifact-report.yml` takes `raw` (default `false`). With
  `raw: true` the file is posted exactly as it is, which is what
  `reusable-link-check.yml` and `reusable-validate.yml` set because their reports
  carry their own heading and footer. Migration: before `raw` existed every
  file was posted as-is, so an external caller that formats its own report must
  set `raw: true` when it moves to this release, or the file gains a second
  heading and footer.
- A missing artifact never posts a broken comment: the preview publisher
  deletes a stale comment when `artifact-url` is empty, and the report
  publisher warns and skips when the download fails.

## Security audit and AI review

`reusable-security-audit.yml` runs osv-scanner via the pinned py-lintro
image and uploads a comment artifact; pair with
`reusable-publish-security-audit-comment.yml` (same split pattern as
quality lint + publish-quality-summary). `reusable-ai-review.yml` installs
a pinned `lintro[ai]` from PyPI and posts one sticky PR comment as
`lintro-review[bot]` via `lintro review --post`. Callers use
`secrets: inherit` (or the explicit org-secret list); only the credential
for the resolved `(provider, transport)` pair is injected. Fork PRs skip.
See the "AI code review" section of
[reusable-workflows.md](../reusable-workflows.md#ai-code-review-reusable-ai-reviewyml)
for the caller snippet, permissions block, and credential matrix.
