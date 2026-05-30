# Reusable Workflow Contract

All `lgtm-ci` reusable workflows share a common consumer contract.

## Standard inputs

Where applicable, workflows accept:

<!-- Wide table kept for quick input-to-purpose scanning across reusable workflows. -->
<!-- markdownlint-disable MD013 -->

| Input                              | Purpose                                                       |
| ---------------------------------- | ------------------------------------------------------------- |
| `tooling-ref`                      | Pin lgtm-ci scripts/actions (defaults to caller workflow SHA) |
| `egress-policy`                    | `audit` or `block` for StepSecurity harden-runner             |
| `allowed-endpoints`                | Allowlist when `egress-policy: block`                         |
| `job-name`                         | Check name on always-run jobs; PR comment suite name          |
| `runner-image`                     | Runner label for long-running jobs                            |
| `timeout-minutes`                  | Job timeout                                                   |
| `post-pr-comment`                  | Enable PR summary comments                                    |
| `comment-marker` / `comment-title` | PR comment identity                                           |
| `draft-pr-skip`                    | Skip PR jobs on draft pull requests                           |

<!-- markdownlint-enable MD013 -->

## Permissions by mode

GitHub validates **all** jobs in a called reusable workflow at parse time,
regardless of job `if:` conditions. Workflows that bundle lint/test/coverage with
optional PR comments therefore split comment posting into dedicated reusables
(for example `reusable-quality-lint.yml` + `reusable-quality-pr-comment.yml`).
Callers that disable comments or run on tag/release events should invoke the
lint/test/coverage reusable only and omit the comment reusable entirely.

### Direct caller pattern (no orchestrator)

Callers invoke `reusable-quality-lint.yml` and `reusable-quality-pr-comment.yml`
directly — there is no intermediate orchestrator workflow. This produces a single
nesting hop (`ci.yml` → `reusable-quality-lint.yml`) so check names read
`quality / Lintro Quality Checks` instead of `quality / quality / Lintro Quality
Checks`. The pattern matches `reusable-test-python.yml` +
`reusable-test-pr-comment.yml`.

A `strategy: matrix` job **can** call a reusable workflow via `uses:` — GitHub
Actions maps matrix values to reusable workflow inputs. `reusable-test-node.yml`
`coverage-pr-comment` uses inline steps to avoid an extra nesting level (which
would worsen check-name readability) and to access matrix-specific artifacts.

<!-- Wide table kept to compare permissions, modes, and workflow entry points. -->
<!-- markdownlint-disable MD013 -->

| Mode                  | Caller permissions                                   | Workflow                                |
| --------------------- | ---------------------------------------------------- | --------------------------------------- |
| Quality / lint only   | `contents: read`, `packages: read`                   | `reusable-quality-lint.yml`             |
| Quality comment       | `contents: read`, `pull-requests: write`             | `reusable-quality-pr-comment.yml`       |
| Test / coverage only  | `contents: read`                                     | Reusables with `post-pr-comment: false` |
| PR comments           | `contents: read`, `pull-requests: write`             | `reusable-*-pr-comment.yml`             |
| Publish to Pages      | `contents: read`, `pages: write`, `id-token: write`  | Separate publish job                    |
| Release version       | `contents: write`, `pull-requests: write`            | `reusable-release-version-pr.yml`       |
| PyPI upload (OIDC)    | `contents: read`; `id-token` + `attestations: write` | `upload-pypi-oidc`                      |
| PyPI build            | `contents: read`                                     | `reusable-build-python-dist.yml`        |
| GitHub Release assets | `contents: write`                                    | `reusable-github-release.yml`           |

<!-- markdownlint-enable MD013 -->

`reusable-test-node.yml` does not include a publish job. Use
`reusable-test-node-publish.yml` in a separate caller job for Pages publishing.

### Isolated publish jobs (Pages / coverage badge)

`reusable-test-python-publish.yml` and `reusable-test-node-publish.yml` run in a
**fresh workspace** (separate reusable-workflow job from the test matrix). The
caller repository checkout must initialize `.git` before tooling is added:

1. Harden runner (`step-security/harden-runner` — no tooling checkout yet)
2. Checkout repository (caller repo at workspace root)
3. Checkout lgtm-ci tooling (`.lgtm-ci-tooling/` alongside the repo)
4. Download artifacts, badge generation, GitHub Pages publish (local tooling actions)

Deploy uses official `actions/deploy-pages` (not gh-pages branch push). See
[pages-publishing.md](pages-publishing.md) for permissions, egress, and
multi-publisher limits.

`clean: false` on the repository checkout does **not** help here: without an
existing `.git`, `actions/checkout` wipes the workspace and deletes
`.lgtm-ci-tooling/` if tooling was checked out first. Match
`reusable-build-python-dist.yml` and `reusable-pr-auto-assign.yml`.

## Low-noise Rust and Node checks

Prefer split workflows to avoid skipped checks in PR UI:

| Use case            | Workflow                                                    |
| ------------------- | ----------------------------------------------------------- |
| Rust build only     | `reusable-rust-build.yml` or `reusable-test-rust-build.yml` |
| Rust test (fast)    | `reusable-rust-test.yml` with `coverage: false`             |
| Rust test + cov     | `reusable-rust-test.yml` with `coverage: true`              |
| Node Vitest tests   | `reusable-test-node.yml` (Vitest)                           |
| Node custom command | `reusable-test-node-custom.yml` (required `test-command`)   |

Use separate caller jobs (different `name:` and/or `job-name`) when rulesets
require distinct required checks; the reusable never runs nextest and llvm-cov in
one job.

## Job display names

GitHub can render unevaluated `job.name` expressions in the checks UI when a job
is skipped by `if:`. lgtm-ci uses a **hybrid** policy (issue #168 §12):

<!-- markdownlint-disable MD013 -->

| Pattern | When | Check name behavior |
| ------- | ---- | ------------------- |
| **Split reusables** | Consumer-facing modes (Vitest vs custom Node) | Matching workflow only; `job-name` drives test check name. |
| **`job-name` input** | Always-run jobs (quality, publish, Rust test, split Node) | Caller passes the visible check label. |
| **Static inner names** | Internal matrix legs (Python, Docker, E2E) | Fixed labels; GitHub appends matrix suffix. Brand via caller `name:`. |

<!-- markdownlint-enable MD013 -->

Contract enforcement: `scripts/ci/quality/validate-static-job-names.sh` (also
covered by BATS). Do not use `matrix.`, `format(`, or ternary `&& … ||`
expressions in `job.name` on jobs that have `if:`.

**Node testing:** Vitest callers use `reusable-test-node.yml` with `job-name`.
Custom package scripts use `reusable-test-node-custom.yml` with required
`test-command` and `job-name`.

## Org ruleset check names

Reusable workflows report checks as **`caller_job_id / inner_job_name`**. Org
rulesets may require a **legacy display name** that does not match the inner
`job-name` on the work job (for example ruleset `🧪 Test Suite & Coverage` vs
`test / Python Compatibility`).

**Preferred (no shim):** Update the org ruleset to require the actual check path
after repinning, and set `job-name` (and caller job `id` when helpful) to match.

**Legacy gate:** When the ruleset cannot change yet, add a thin caller job that
calls `reusable-required-check.yml` instead of hand-rolled `runs-on` shims. Pass
`upstream-result` and optional `passed-output` / `status-output` from the work
job. Use `always()` on the caller job so the gate still runs when the upstream
job fails.

```yaml
test:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
  with:
    job-name: Python Compatibility
    tooling-ref: <sha>

test-suite-coverage:
  needs: test
  if: always()
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-required-check.yml@<sha>
  with:
    tooling-ref: <sha>
    job-name: "🧪 Test Suite & Coverage"
    upstream-result: ${{ needs.test.result }}
    passed-output: ${{ needs.test.outputs.passed }}
```

Do not add per-consumer `job-name` aliases inside work reusables.

## Egress block examples

### Node / Bun (web)

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  objects.githubusercontent.com:443
  registry.npmjs.org:443
```

### Rust

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  static.rust-lang.org:443
  sh.rustup.rs:443
  crates.io:443
  static.crates.io:443
  index.crates.io:443
```

### Quality / Lintro

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  ghcr.io:443
  index.crates.io:443
  registry.npmjs.org:443
  api.osv.dev:443
  semgrep.dev:443
  metrics.semgrep.dev:443
```

### GitHub Pages publish (OIDC)

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  actions.githubusercontent.com:443
  codeload.github.com:443
  objects.githubusercontent.com:443
  release-assets.githubusercontent.com:443
```

### PyPI build

Used by `reusable-build-python-dist.yml` (`allowed-endpoints` on the reusable
`with:` block). Does not upload to PyPI.

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  release-assets.githubusercontent.com:443
  objects.githubusercontent.com:443
  github-releases.githubusercontent.com:443
  raw.githubusercontent.com:443
  astral.sh:443
  releases.astral.sh:443
```

### PyPI upload (OIDC + attestation)

Used on the **caller** upload job (`upload-pypi-oidc` composite). Set
`environment: pypi` on that job. The composite downloads workflow artifacts and
checks out lgtm-ci tooling — include artifact and GitHub hosts below.
`pypa/gh-action-pypi-publish` pulls `ghcr.io/pypa/gh-action-pypi-publish` —
include `ghcr.io:443` and `pkg-containers.githubusercontent.com:443`.

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  objects.githubusercontent.com:443
  actions.githubusercontent.com:443
  blob.core.windows.net:443
  ghcr.io:443
  pkg-containers.githubusercontent.com:443
  pypi.org:443
  upload.pypi.org:443
  files.pythonhosted.org:443
  test.pypi.org:443
  upload.test.pypi.org:443
  fulcio.sigstore.dev:443
  rekor.sigstore.dev:443
  tuf-repo-cdn.sigstore.dev:443
  oauth2.sigstore.dev:443
```

See [python-release-publish.md](python-release-publish.md) for trusted
publishing requirements.

### GitHub Release (artifact upload)

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  uploads.github.com:443
  codeload.github.com:443
  release-assets.githubusercontent.com:443
  objects.githubusercontent.com:443
```

## Action pinning policy

Org repos must pin GitHub Actions to **commit SHAs only** and add a trailing
Renovate version comment on the same line. Tag refs (for example `@v4`) fail
`reusable-validate-action-pinning.yml` unless the action is listed in the narrow
`allow-tag-exceptions` input.

| Pin                                                       | Result                     |
| --------------------------------------------------------- | -------------------------- |
| `uses: org/action@sha`                                    | Fail — missing `# vX.Y.Z`  |
| `uses: org/action@v1.2.3`                                 | Fail — tag pin             |
| `uses: org/action@sha # v1.2.3`                           | Pass                       |
| `tooling-ref: 'sha'`                                      | Fail — missing `# vX.Y.Z`  |
| `tooling-ref: 'sha' # v0.18.4`                            | Pass                       |
| `ref: 'sha'` under `repository: lgtm-hq/lgtm-ci` checkout | Same rule as `tooling-ref` |

Use the **release commit SHA** for `tooling-ref` and lgtm-ci checkout `ref` pins, not the
annotated tag object SHA. For example, `v0.18.4` resolves to release commit
`d3736367191ddaf56c41804d2dd5174732ed2d2b`, not tag object `95e202ae…`.

Canonical examples:

```yaml
uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4
tooling-ref: "d3736367191ddaf56c41804d2dd5174732ed2d2b" # v0.18.4
```

Template expressions (for example `${{ inputs.tooling-ref }}`) are ignored.
Bare SHA pins without version comments are invisible to Renovate and are blocked
by design.

### Composite actions calling sibling lgtm-ci actions

Composite `action.yml` files must not call sibling lgtm-ci actions with a remote
template ref:

```yaml
uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@${{ inputs.tooling-ref }}
```

GitHub validates nested composite `uses:` values before composite inputs are
available, so this pattern fails during workflow template validation. Workflows
and reusable workflows may still pass `${{ inputs.tooling-ref }}` to checkout
`ref:` values or reusable workflow inputs; this restriction is only for
composite action `uses:` fields.

Composite actions that need sibling lgtm-ci actions should checkout lgtm-ci
tooling into `.lgtm-ci-tooling` and call those actions by local path:

```yaml
- name: Checkout lgtm-ci tooling
  uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  with:
    repository: lgtm-hq/lgtm-ci
    path: .lgtm-ci-tooling
    ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || github.action_ref }}
    sparse-checkout: |
      .github/actions/
      scripts/ci/
    sparse-checkout-cone-mode: true
    persist-credentials: false

- name: Resolve scripts directory
  shell: bash
  run: echo "SCRIPTS_DIR=${GITHUB_WORKSPACE}/.lgtm-ci-tooling/scripts" >> "$GITHUB_ENV"

- name: Setup Python
  uses: ./.lgtm-ci-tooling/.github/actions/setup-python
```

`tests/bats/integration/test_composite_action_refs.bats` guards this contract
and fails if any `.github/actions/**/action.yml` uses
`lgtm-hq/lgtm-ci/...@${{ ... }}`. Hardened caller jobs that run composites with
tooling checkout need egress for `codeload.github.com`, `astral.sh`, and
`releases.astral.sh`; see the PyPI egress examples above.

## Dependency review

`reusable-dependency-review.yml` runs on `pull_request` and `merge_group`
events. Do not invoke it from plain `push` workflows unless you accept the job
being skipped.

## Merge queue (`merge_group`)

Callers using GitHub merge queue can add `merge_group:` triggers to thin
caller workflows alongside `pull_request:`.

| Workflow                               | `merge_group` behavior                         |
| -------------------------------------- | ---------------------------------------------- |
| `reusable-codeql.yml`                  | Safe to run — no PR context required           |
| `reusable-validate-action-pinning.yml` | Safe to run — no PR context required           |
| `reusable-dependency-review.yml`       | Runs on `merge_group` (same as PR)             |
| `reusable-semantic-pr-title.yml`       | Skips on `merge_group` — title validated on PR |

Semantic title validation is intentionally skipped in the merge queue because
`amannn/action-semantic-pull-request` requires pull request context.

Callers need `pull-requests: read`. Tooling is loaded from `lgtm-ci` via
`prepare-semantic-pr-lists.sh` (supports `tooling-ref` for unreleased fixes).
The workflow passes newline-delimited `types`/`scopes` to the action (empty
`types` uses the built-in default; comma-separated overrides are normalized).

## Fork PR comments

PR comments are skipped automatically on fork PRs (`head.repo.fork == true`).
This is enforced in `scripts/ci/actions/post-pr-comment.sh` and workflow `if`
conditions.

## Rustume example

Tag/release pipelines should call lint-only reusables (no `pull-requests: write`):

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      tooling-ref: "<sha>"
      job-name: "🛠️ Lintro Code Quality & Analysis"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        ghcr.io:443
        api.osv.dev:443
        semgrep.dev:443
        metrics.semgrep.dev:443
```

Pull-request pipelines with comments call both reusables directly:

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      tooling-ref: "<sha>"
      job-name: "🛠️ Lintro Code Quality & Analysis"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        ghcr.io:443
        api.osv.dev:443
        semgrep.dev:443
        metrics.semgrep.dev:443

  quality-pr-comment:
    needs: quality
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-pr-comment.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      exit-code: ${{ needs.quality.outputs.exit-code }}
      tooling-ref: "<sha>"

  rust-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-build.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: "<sha>"
      job-name: "🔨 Build Check"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        static.rust-lang.org:443
        crates.io:443

  rust-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "🦀 Rust Coverage"
      coverage: true
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        static.rust-lang.org:443
        crates.io:443

  web-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node-custom.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "🌐 Web Coverage"
      working-directory: apps/web
      package-manager: bun
      test-command: bun run test:coverage
      coverage: true
      coverage-pr-comment: true
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        registry.npmjs.org:443
```
