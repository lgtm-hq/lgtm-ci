# Reusable Workflows

Use reusable workflows from consumer repositories with a thin caller job.

**Tag/release and non-PR pipelines** should call lint/test/coverage reusables
directly (for example `reusable-quality-lint.yml`) with `contents: read` only.
Grant `pull-requests: write` only when invoking workflows that post PR summaries and reports.

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
```

Pull-request pipelines with PR summaries and reports call both reusables directly:

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read

  publish-quality-summary:
    needs: quality
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-quality-summary.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      exit-code: ${{ needs.quality.outputs.exit-code }}
```

Pass `tooling-ref` when testing an unreleased lgtm-ci branch on **script-backed**
reusables (quality, test-*, validate-*, release-*, etc.). Production callers
should pin the workflow ref to a commit SHA and pass the same ref as
`tooling-ref` on script-backed workflows.

**Action-only reusables** (labeler, dependency review, semantic PR title,
CodeQL, Scorecard) do not run the full `scripts/ci/` suite in their analysis
jobs; `tooling-ref` is optional and primarily pins egress composites.
**`reusable-codeql.yml`** is an exception when callers pass `languages` or
`language-build-modes`: its setup job sparse-checkouts
`scripts/ci/actions/generate-codeql-matrix.sh` to build per-language matrix
legs. Each leg still uses `github/codeql-action/*` with the resolved
`build-mode` — not caller repo scripts. Pass `tooling-ref` when testing
unreleased matrix-generator changes. See
[workflow-contract.md](workflow-contract.md#action-only-reusables).

Consumers do **not** need to vendor `.github/actions/harden-runner` or
`resolve-egress-allowlist` — reusables sparse-checkout lgtm-ci into
`.lgtm-ci-tooling/` and invoke `./.lgtm-ci-tooling/.github/actions/...` (same
`tooling-ref` / `github.workflow_sha` as other tooling steps).

See [workflow-contract.md](workflow-contract.md) for the standard input contract,
permissions by mode, egress allowlists, and Rust examples.

Caller examples live under [examples/](../examples/) (see [examples/README.md](../examples/README.md)).

For GitHub Pages (coverage, test reports, and static sites), see
[pages-publishing.md](pages-publishing.md).

## Quality And Validation

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      job-name: "Lintro Quality Checks"
      egress-preset: quality

  publish-quality-summary:
    needs: quality
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-quality-summary.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      exit-code: ${{ needs.quality.outputs.exit-code }}

  validate:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-validate.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      script: scripts/ci/validate.sh
```

### Org ruleset gate (`reusable-required-check.yml`)

Thin aggregate-status gate for branch-protection check names that differ from
the work reusable’s `job-name`. See [workflow-contract.md](workflow-contract.md)
(Org ruleset check names).

```yaml
test-suite-coverage:
  needs: test
  if: always()
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-required-check.yml@<sha>
  permissions:
    contents: read
  with:
    tooling-ref: <sha>
    job-name: "🧪 Test Suite & Coverage"
    upstream-result: ${{ needs.test.result }}
    passed-output: ${{ needs.test.outputs.passed }}
```

## Tests

```yaml
jobs:
  node:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      node-versions: "20,22"
      pre-test-command: bun run build
      upload-build-artifact: true

  python:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      coverage: true
      upload-coverage: true

  shell:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-shell.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      test-path: tests/bats

  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      browsers: chromium

  e2e-matrix:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-matrix.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      test-suites: smoke,visual
      browsers: chromium,firefox
```

`reusable-publish-test-summary.yml` is the shared internal workflow used by
language test reusables to publish test summaries (rich coverage table when
coverage was collected, otherwise test pass/fail totals). Artifact-based comments
use `reusable-publish-artifact-report.yml`.
Quality lint-only checks use `reusable-quality-lint.yml`; PR lint summaries use
`reusable-publish-quality-summary.yml` (called directly by the caller workflow).

### Pages coverage HTML inputs (`reusable-test-node`)

<!-- markdownlint-disable MD013 -- prettier table column alignment -->

| Input                           | Type    | Required | Default         | Purpose                               |
| ------------------------------- | ------- | -------- | --------------- | ------------------------------------- |
| `upload-pages-coverage-html`    | boolean | no       | `false`         | Upload flat HTML for Model B bundling |
| `pages-coverage-artifact-name`  | string  | no       | `coverage-html` | Flat HTML artifact name               |
| `pages-coverage-upload-on`      | string  | no       | `push-main`     | Upload gate selector (v1)             |
| `pages-coverage-source-subpath` | string  | no       | `coverage`      | HTML dir under `working-directory`    |

<!-- markdownlint-enable MD013 -->

Outputs: `pages-coverage-artifact-name`, `pages-coverage-uploaded` (`true`/`false`).

**`pages-coverage-upload-on` (v1):** The `(v1)` suffix marks the first supported
upload-gating behavior. Additional values may be added in later releases without
breaking existing callers. Use the literal string values below — they are not
Git ref aliases.

| Value       | Meaning                                                                          |
| ----------- | -------------------------------------------------------------------------------- |
| `push-main` | Upload only when `github.event_name == push` and `github.ref == refs/heads/main` |

When `node-versions` is a matrix, only the **first** listed version uploads the
flat artifact (avoids `upload-artifact` name collisions). Matrix debug artifacts
(`node-coverage-<version>/…`) are unchanged when `upload-coverage: true`.

**Job display names:** Vitest and custom Node tests are **split workflows**
(`reusable-test-node.yml` and `reusable-test-node-custom.yml`). Each test job uses
`${{ inputs.job-name }}` for the GitHub check label — there are no mutually
skipped Vitest/custom siblings. For Python, Docker per-platform, and E2E matrix
jobs, inner names are static; see [workflow-contract.md](workflow-contract.md)
(§ Job display names).

**test summaries:** Set `publish-test-summary: true` (default) to post or update one
comment per workflow run. When `coverage: true`, the test job builds a rich
coverage artifact and the `publish-test-summary-coverage` matrix job posts it.
When `coverage: false`, `publish-test-summary` delegates to
`reusable-publish-test-summary.yml` with test totals.

### Rust

Use `reusable-rust-build.yml` for compile checks and `reusable-rust-test.yml` for
tests. Set `coverage: false` for fast nextest-only runs or `coverage: true` for a
single instrumented `llvm-cov nextest` run (tests + LCOV). See
[rust-testing.md](rust-testing.md).

```yaml
jobs:
  rust-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-build.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Build"
      egress-policy: block

  rust-test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Tests"
      coverage: false
      egress-policy: block

  rust-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Coverage"
      coverage: true
      egress-policy: block
      upload-pages-coverage-html: true
      pages-coverage-artifact-name: rust-coverage-html
```

### Pages coverage HTML inputs (`reusable-rust-test` with `coverage: true`)

<!-- markdownlint-disable MD013 -- prettier table column alignment -->

| Input                          | Type    | Required | Default              | Purpose                            |
| ------------------------------ | ------- | -------- | -------------------- | ---------------------------------- |
| `upload-pages-coverage-html`   | boolean | no       | `false`              | Upload flat HTML for Model B sites |
| `pages-coverage-artifact-name` | string  | no       | `rust-coverage-html` | Rust HTML artifact name            |
| `pages-coverage-upload-on`     | string  | no       | `push-main`          | Upload gate selector (v1)          |

<!-- markdownlint-enable MD013 -->

Outputs: `pages-coverage-artifact-name`, `pages-coverage-uploaded` (`true`/`false`).

### Rust release (cross-compile from Linux)

Use `reusable-publish-rust-release.yml` on tag pushes for block-only binary
builds and GitHub release creation. The orchestrator verifies the tag against
`Cargo.toml`, calls `reusable-build-rust-binaries.yml` (strict tier,
`rust-release` egress preset), and uploads all matrix artifacts to a release.

```yaml
on:
  push:
    tags: ["v*"]

jobs:
  release:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-rust-release.yml@<sha>
    permissions:
      contents: write
      id-token: write
      attestations: write
    with:
      tooling-ref: "<sha>"
      packages: "my-cli,my-server"
```

See [workflow-contract.md](workflow-contract.md#rust-release-contract) for artifact
naming, default target matrix, and runner policy tiers.

**`pages-coverage-upload-on` (v1):** Same gating semantics as the Node reusable
(see table above). `push-main` is a literal selector meaning push events to
`refs/heads/main`; it is not a Git ref alias. The `(v1)` suffix denotes the
current upload-gating API; new non-breaking values may appear in later releases.

HTML is generated in the same job as the LCOV run via `cargo llvm-cov report --html`
(no second test run). The script flattens cargo-llvm-cov's `<output-dir>/html/`
layout so the artifact root is browsable HTML.

## Release

When release automation fails on the default branch, the follow-up
`report-release-failure` job runs two steps in order: it first writes release
trigger context to the job step summary, then creates or updates a deduplicated
GitHub issue with failed step details. Set `report-failures: false` to disable
both actions. See [workflow-contract.md](workflow-contract.md) for inputs.

`report-failures` defaults to `true`. GitHub rejects a reusable-workflow call at
startup when the caller job does not grant every permission the reusable
workflow declares. Grant at least `actions: read` and `issues: write` on the
caller job, or pass `report-failures: false` when upgrading from a release that
did not include failure reporting.

Recommended caller `run-name` (reusable workflows cannot set this for you):

```yaml
name: Release Version PR
run-name: >-
  Release version PR via ${{ github.event_name }} on ${{ github.ref_name }}
  @ ${{ github.sha }}
```

Including `${{ github.event_name }}`, `${{ github.ref_name }}`, and
`${{ github.sha }}` in the `run-name` makes it easier to triage failures: the
workflow run list shows the triggering event, branch, and commit so you can
quickly correlate a failed run with the code and event that started it.

```yaml
jobs:
  version-pr:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-version-pr.yml@<sha>
    permissions:
      contents: write
      pull-requests: write
      actions: read
      issues: write
    with:
      ecosystems: node,ruby,python
      skip-patterns: "^chore(release):"
      auto-merge-patch-only: false
    secrets: inherit

  auto-tag:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-auto-tag.yml@<sha>
    permissions:
      contents: write
      actions: read
      issues: write
    with:
      create-release: false
    secrets: inherit
```

**Cargo workspace auto-tag** (Rust monorepos that bump `Cargo.toml` on `main`):

```yaml
name: Release - Auto Tag

on:
  push:
    branches: [main]
    paths:
      - Cargo.toml

jobs:
  auto-tag:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-auto-tag.yml@<sha>
    permissions:
      contents: write
      actions: read
      issues: write
    with:
      version-source: cargo
      version-file: Cargo.toml
      skip-if-unchanged: true
      create-release: false
    secrets: inherit
```

`guard-release-commit` skips non-`chore(release):` commits — version bumps must
use a `chore(release):` subject or the job writes a skip summary without tagging.
`skip-if-unchanged` compares the Cargo version to the latest `tag-prefix` tag
before creating a new tag.

## Publishing And Deployment

```yaml
jobs:
  npm:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-npm.yml@<sha>
    permissions:
      contents: read
      id-token: write
      attestations: write

  pypi-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-build-python-dist.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: "<sha>" # vX.Y.Z
      artifact-name: python-dist

  pypi-upload:
    needs: pypi-build
    runs-on: ubuntu-latest
    environment: pypi
    permissions:
      contents: read
      id-token: write
      attestations: write
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@<pin> # v2.19.4
        with:
          egress-policy: block
          # workflow-contract.md § PyPI upload (OIDC)
          allowed-endpoints: >
            github.com:443
            api.github.com:443
            codeload.github.com:443
            objects.githubusercontent.com:443
            actions.githubusercontent.com:443
            *.blob.core.windows.net:443
            ghcr.io:443
            pkg-containers.githubusercontent.com:443
            pypi.org:443
            upload.pypi.org:443
            files.pythonhosted.org:443
            fulcio.sigstore.dev:443
            rekor.sigstore.dev:443
            tuf-repo-cdn.sigstore.dev:443
            oauth2.sigstore.dev:443
      - name: Prepare PyPI upload
        id: prepare
        uses: lgtm-hq/lgtm-ci/.github/actions/prepare-pypi-upload@<sha> # vX.Y.Z
        with:
          artifact-name: python-dist
          tooling-ref: "<sha>"
      - name: Upload to PyPI
        uses: pypa/gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b # v1.14.0
        with:
          repository-url: https://upload.pypi.org/legacy/
          packages-dir: ${{ steps.prepare.outputs.dist-path }}
      - name: Attest build provenance
        continue-on-error: true
        uses: actions/attest-build-provenance@a2bbfa25375fe432b6a289bc6b6cd05ecd0c4c32 # v4.1.0
        with:
          subject-path: ${{ steps.prepare.outputs.dist-path }}/*

  github-release:
    needs: pypi-upload
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-github-release.yml@<sha>
    permissions:
      contents: write
    with:
      artifact-name: python-dist
      tooling-ref: "<sha>" # vX.Y.Z

  gem:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-gem.yml@<sha>
    permissions:
      contents: read
      id-token: write

  homebrew:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-homebrew.yml@<sha>
    permissions:
      contents: write

  pages:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-pages.yml@<sha>
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      build-command: bun run build
      package-manager: bun
```

### Site + bundled CI reports (Model B)

```yaml
deploy-site:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-site-with-reports.yml@<sha>
  permissions:
    contents: read
    pages: write
    id-token: write
    actions: read
  with:
    site-root: apps/site/dist
    build-command: bun run build
    package-manager: bun
    bundle-manifest: examples/bundle-manifest-turbo-themes.json
    commit-sha: ${{ github.event.workflow_run.head_sha }}
    fallback-ref: main
    tooling-ref: "<sha>"
```

See [pages-publishing.md](pages-publishing.md) for manifest schema, egress
allowlist, and `workflow_run` caller patterns.

See [python-release-publish.md](python-release-publish.md) for a full production
tag-push layout (quality, SBOM, split publish, release assets).

## Build, Coverage, And Supply Chain

### Push (publish to registry)

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      security-events: write
    with:
      push: true
      scan: true
      scan-exit-code: "1"
      cosign-sign: true
      cache-registry-ref: ghcr.io/org/repo:cache
      no-cache: ${{ startsWith(github.ref, 'refs/tags/v') }}
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'
```

### PR validation (build-only, no push)

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      file: docker/Dockerfile
      push: false
      validate-on-pr: true
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'
      scan: true
      scan-exit-code: "1"
      smoke-test: --version
```

### Combined push and PR validation

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      security-events: write
    with:
      push: ${{ github.event_name != 'pull_request' }}
      validate-on-pr: ${{ github.event_name == 'pull_request' }}
      scan: true
      scan-exit-code: "1"
      cosign-sign: true
      cache-registry-ref: ghcr.io/org/repo:cache
      no-cache: ${{ startsWith(github.ref, 'refs/tags/v') }}
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'

  sbom:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
    permissions:
      contents: read
      security-events: write
      id-token: write
      attestations: write

  coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-coverage.yml@<sha>
    permissions:
      contents: read

  ghcr-cleanup:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-ghcr-cleanup.yml@<sha>
    permissions:
      contents: read
      packages: write
    with:
      package-name: my-image
    secrets: inherit
```

### Docker workflow inputs

| Input                | Default | Description                                                   |
| -------------------- | ------- | ------------------------------------------------------------- |
| `validate-on-pr`     | `false` | Use native split builds on PRs without pushing staging images |
| `scan-exit-code`     | `"0"`   | Trivy exit code; set `"1"` to block PRs on CRITICAL/HIGH CVEs |
| `cache-registry-ref` | `""`    | Registry cache fallback (e.g. `ghcr.io/org/repo:cache`)       |
| `cosign-sign`        | `false` | Keyless Cosign signature on pushed manifests                  |
| `no-cache`           | `false` | Disable GHA/registry cache for clean release builds           |
| `provenance`         | `true`  | Generate provenance attestation (only when `push: true`)      |
| `sbom`               | `true`  | Generate SBOM attestation (only when `push: true`)            |

`sbom` and `provenance` only apply when `push: true`. PR validation
(`validate-on-pr` with `scan`) loads images locally via `--load`; buildx cannot
export manifest lists from SBOM attestations, so attestations are intentionally
skipped on that path. The publish path (main/tags with `push: true`) still
receives full SBOM and provenance attestations.

All inputs are opt-in; existing callers keep current behavior without changes.

## PR Automation And Security

### Semantic PR title

`amannn/action-semantic-pull-request` expects **newline-delimited** `types` and
`scopes`. The reusable workflow normalizes legacy comma-separated overrides and
ships a correct default when `types` is omitted.

By default the workflow posts a marker-based PR comment on validation failure
and clears it when the title is fixed. Set `post-failure-comment: false` for
check-only adopters.

| Input                  | Default              | Notes                                      |
| ---------------------- | -------------------- | ------------------------------------------ |
| `post-failure-comment` | `true`               | Opt out for check-only workflows           |
| `comment-marker`       | `semantic-pr-title`  | Upsert marker for failure comments         |
| `max-length`           | `0` (no limit)       | Optional title length cap                  |
| `require-scope`        | `false`              | Passed through to amannn                   |
| `types` / `scopes`     | built-in defaults    | Override only when needed                  |

Callers must grant `pull-requests: write` when `post-failure-comment` is enabled
(the default). With `post-failure-comment: false`, `pull-requests: read` is
sufficient. Workflow root `permissions: {}` otherwise strips PR access from the
reusable job.

### Security audit (lintro + osv-scanner)

`reusable-security-audit.yml` runs osv-scanner via the pinned py-lintro Docker
image and uploads a comment artifact on pull requests. The audit step uses
`continue-on-error` with an explicit fail step so comment generation still runs
when vulnerabilities are found.

Post the marker-based PR comment from a separate caller job using
`reusable-publish-security-audit-comment.yml` (same split pattern as quality
lint + publish-quality-summary). The audit reusable requires only
`contents: read` and `packages: read`.

Add `merge_group:` to the caller workflow when using merge queue (audit runs;
artifact upload and PR comment publish remain `pull_request`-only).

| Input                    | Default                 | Notes                                      |
| ------------------------ | ----------------------- | ------------------------------------------ |
| `lintro-image`           | pinned py-lintro        | Override when adopting a newer lintro pin  |
| `audit-script`           | tooling default         | Rarely needed — override for custom scans  |
| `upload-comment-artifact`| `true`                  | Set `false` for push/schedule check-only   |
| `comment-marker`         | `security-audit-report` | Used by publish reusable                   |

```yaml
'on':
  pull_request:
  merge_group:
    types: [checks_requested]
  push:
    branches: [main]
  schedule:
    - cron: '30 5 * * 1'

jobs:
  security-audit:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-security-audit.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      tooling-ref: "<sha>"
      job-name: "🔐 Security Audit"
      lintro-image: ghcr.io/lgtm-hq/py-lintro@sha256:...
      upload-comment-artifact: ${{ github.event_name == 'pull_request' }}

  publish-security-audit-comment:
    needs: security-audit
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-security-audit-comment.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
```

For push/schedule workflows, omit the publish job and pass
`upload-comment-artifact: false`.

```yaml
jobs:
  semantic-title:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-semantic-pr-title.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      egress-preset: github-minimal
      # Optional: override types (newline-delimited; CSV is normalized)
      # types: |
      #   feat
      #   fix
      #   ci
      # Optional: enforce a title length cap
      # max-length: "72"
      # Optional: check-only (no PR comments)
      # post-failure-comment: false
```

```yaml
jobs:
  label:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-pr-labeler.yml@<sha>
    permissions:
      contents: read
      pull-requests: write

  assign:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-pr-auto-assign.yml@<sha>
    permissions:
      pull-requests: write

  action-pinning:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-validate-action-pinning.yml@<sha>
    permissions:
      contents: read

  links:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-link-check.yml@<sha>
    permissions:
      contents: read

  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write

  dependency-review:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-dependency-review.yml@<sha>
    permissions:
      contents: read
      pull-requests: read

  scorecards:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-scorecards.yml@<sha>
    permissions:
      contents: read
      security-events: write
      id-token: write
```

### CodeQL build-mode

`reusable-codeql.yml` defaults `build-mode` to `none`. Choose the mode from the
language class — do **not** pass `build-mode: autobuild` for interpreted
languages (legacy inline workflows often had a separate `codeql-action/autobuild`
step; that maps to `autobuild` only for compiled languages).

<!-- markdownlint-disable MD013 -->

| Language class                          | `build-mode`              | Notes                                      |
| --------------------------------------- | ------------------------- | ------------------------------------------ |
| Python, JavaScript/TypeScript, Ruby, Go | `none` (default)          | Database built directly from source        |
| C/C++, C#, Java, Kotlin, Swift, …       | `autobuild` or `manual`   | Requires build observation or custom steps |

<!-- markdownlint-enable MD013 -->

**Python-only caller** — omit `build-mode` or set `none` explicitly:

```yaml
jobs:
  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      languages: python
      # build-mode defaults to none — do not use autobuild for Python
```

**Compiled-language caller** — use `autobuild` (or `manual` with your own build
steps before `Analyze`):

```yaml
jobs:
  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      languages: java
      build-mode: autobuild
```

**Multi-language caller** — when languages need different build modes (for example
Rust plus GitHub Actions), pass `language-build-modes` as a JSON object. The
reusable runs one matrix leg per language so `init` receives the correct
`build-mode` for each extractor (do **not** rely on a single global
`build-mode` across mixed language classes):

```yaml
jobs:
  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      languages: rust,actions
      language-build-modes: '{"rust":"autobuild","actions":"none"}'
      egress-policy: block
      allowed-endpoints-mode: append
      allowed-endpoints: |
        static.rust-lang.org:443
        sh.rustup.rs:443
        crates.io:443
        static.crates.io:443
        index.crates.io:443
```

When `category` is omitted, each matrix leg uploads SARIF under
`/language:<language>`. Pass `category` explicitly to override all legs (for
example `/language:all` on a single-language scan).

Pin the workflow `uses:` ref to a commit SHA in production. `tooling-ref` is
optional for egress composites only on single-language scans; for multi-language
callers, pass a matching `tooling-ref` when testing unreleased
`generate-codeql-matrix.sh` changes so the setup job and analysis legs stay
aligned.

See [CodeQL workflow configuration — build modes](https://docs.github.com/en/code-security/reference/code-scanning/workflow-configuration-options)
and [workflow-contract.md](workflow-contract.md#action-only-reusables).
