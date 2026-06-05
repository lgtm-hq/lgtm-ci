# Reusable Workflow Contract

All `lgtm-ci` reusable workflows share a common consumer contract.

## Standard inputs

Where applicable, workflows accept:

<!-- markdownlint-disable MD013 -- wide input reference table; row text exceeds default line length -->

| Input                              | Purpose                                                                |
| ---------------------------------- | ---------------------------------------------------------------------- |
| `tooling-ref`                      | Pin lgtm-ci scripts/actions (defaults to caller workflow SHA)          |
| `egress-policy`                    | `block` (default) or `audit` for StepSecurity harden-runner            |
| `egress-preset`                    | Named baseline allowlist under block                                   |
| `allowed-endpoints`                | Multiline `host:port` list (see `allowed-endpoints-mode`)              |
| `allowed-endpoints-mode`           | `replace` (default) or `append` (merge with preset, deduped)           |
| `job-name`                         | Check name on always-run jobs; test summary suite title                |
| `runner-image`                     | Runner label for long-running jobs                                     |
| `timeout-minutes`                  | Job timeout                                                            |
| `publish-test-summary`             | Publish test/coverage summary comment on the pull request              |
| `comment-marker` / `comment-title` | Upsert identity for summary comments (marker + heading)                |
| `draft-pr-skip`                    | Skip PR jobs on draft pull requests (default `true` on test reusables) |

<!-- markdownlint-enable MD013 -->

## Migration: test summary publishing (#281)

Breaking renames unify test/coverage PR comments behind **`publish-test-summary`**
and dedicated publish reusables. Transport (marker upsert) stays on
`post-pr-comment` action/script.

### Caller inputs and jobs

- `post-pr-comment: true` → `publish-test-summary: true`
- `post-pr-comment: false` → `publish-test-summary: false`
- `coverage-pr-comment: true` (with or without `post-pr-comment`) →
  `publish-test-summary: true` only
- `coverage-pr-comment: false` and `post-pr-comment: true` →
  `publish-test-summary: true`
- Caller job `quality-pr-comment` → `publish-quality-summary`
- `comment-on-failure` on `reusable-validate` → `publish-validation-report`
- `comment-on-pr` on `reusable-link-check` → `publish-link-check-report`

### Reusable workflows and scripts

- `reusable-test-pr-comment.yml` → `reusable-publish-test-summary.yml`
- `reusable-coverage-pr-comment.yml` → `reusable-publish-test-summary.yml`
- `reusable-quality-pr-comment.yml` → `reusable-publish-quality-summary.yml`
- `reusable-artifact-pr-comment.yml` → `reusable-publish-artifact-report.yml`
- `generate-coverage-pr-comment.sh` and `generate-test-comment.sh` →
  `generate-test-summary.sh` with `generate-coverage-comment` for rich tables
- Input `prebuilt-comment-file` → `prebuilt-test-summary-file`
- Input `comment-file` on artifact report reusable → `report-file`
- Validation artifact `validation-comment` → `validation-report`

### Comment body selection

When `publish-test-summary: true` on a language test reusable or
`reusable-coverage`:

- Coverage not collected: `generate-test-summary.sh` (pass/fail totals)
- Coverage collected with a downloadable artifact (Rust LCOV, Python JSON when
  `upload-coverage: true`): `generate-coverage-comment` (rich table)
- Coverage collected without an artifact (e.g. Python with `upload-coverage: false`):
  `generate-test-summary.sh` (pass/fail totals with coverage percent)
- Shell/kcov: totals only (rich table not yet supported)

Node matrix coverage uses job `publish-test-summary-coverage` (inline post from
`node-coverage-test-summary` artifacts).

### `draft-pr-skip`

All language test reusables (`reusable-rust-test`, `reusable-test-python`,
`reusable-test-node`, `reusable-test-node-custom`, `reusable-test-shell`) default
`draft-pr-skip: true` so draft PRs skip test and summary jobs unless callers set
`draft-pr-skip: false`.

## Permissions by mode

GitHub validates **all** jobs in a called reusable workflow at parse time,
regardless of job `if:` conditions. Workflows that bundle lint/test/coverage with
optional PR summaries and reports therefore split comment posting into dedicated reusables
(for example `reusable-quality-lint.yml` + `reusable-publish-quality-summary.yml`).
Callers that disable comments or run on tag/release events should invoke the
lint/test/coverage reusable only and omit the publish reusable entirely.

### Direct caller pattern (no orchestrator)

Callers invoke `reusable-quality-lint.yml` and `reusable-publish-quality-summary.yml`
directly — there is no intermediate orchestrator workflow. This produces a single
nesting hop (`ci.yml` → `reusable-quality-lint.yml`) so check names read
`quality / Lintro Quality Checks` instead of `quality / quality / Lintro Quality
Checks`. The pattern matches `reusable-test-python.yml` +
`reusable-publish-test-summary.yml`.

A `strategy: matrix` job **can** call a reusable workflow via `uses:` — GitHub
Actions maps matrix values to reusable workflow inputs. `reusable-test-node.yml`
`publish-test-summary-coverage` uses inline steps to avoid an extra nesting level (which
would worsen check-name readability) and to access matrix-specific artifacts.

<!-- markdownlint-disable MD013 -- permissions matrix; workflow column lists exceed default line length -->

| Mode                  | Caller permissions                                   | Workflow                                     |
| --------------------- | ---------------------------------------------------- | -------------------------------------------- |
| Quality / lint only   | `contents: read`, `packages: read`                   | `reusable-quality-lint.yml`                  |
| Quality summary       | `contents: read`, `pull-requests: write`             | `reusable-publish-quality-summary.yml`       |
| Test / coverage only  | `contents: read`                                     | Reusables with `publish-test-summary: false` |
| Test / report publish | `contents: read`, `pull-requests: write`             | `reusable-publish-test-summary.yml`,         |
|                       |                                                      | `reusable-publish-artifact-report.yml`       |
| Publish to Pages      | `contents: read`, `pages: write`, `id-token: write`  | Separate publish job                         |
| Release version       | `contents: write`, `pull-requests: write`            | `reusable-release-version-pr.yml`            |
| PyPI upload (OIDC)    | `contents: read`; `id-token` + `attestations: write` | `prepare-pypi-upload` + pypa step            |
| PyPI build            | `contents: read`                                     | `reusable-build-python-dist.yml`             |
| GitHub Release assets | `contents: write`                                    | `reusable-github-release.yml`                |

<!-- markdownlint-enable MD013 -->

`reusable-test-node.yml` does not include a publish job. Use
`reusable-test-node-publish.yml` in a separate caller job for Pages publishing.

### Isolated publish jobs (Pages / coverage badge)

`reusable-test-python-publish.yml` and `reusable-test-node-publish.yml` run in a
**fresh workspace** (separate reusable-workflow job from the test matrix). The
caller repository checkout must initialize `.git` before tooling is added:

1. Checkout repository (caller repo at workspace root)
2. Checkout lgtm-ci tooling (`.lgtm-ci-tooling/` — sparse-checkout must include egress
   composites and any scripts/actions the job needs)
3. Resolve egress allowlist (`uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist`)
4. Harden runner (`uses: ./.lgtm-ci-tooling/.github/actions/harden-runner`)
5. Download artifacts, badge generation, GitHub Pages publish (local tooling actions)

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

| Pattern                | When                                                      | Check name behavior                                                   |
| ---------------------- | --------------------------------------------------------- | --------------------------------------------------------------------- |
| **Split reusables**    | Consumer-facing modes (Vitest vs custom Node)             | Matching workflow only; `job-name` drives test check name.            |
| **`job-name` input**   | Always-run jobs (quality, publish, Rust test, split Node) | Caller passes the visible check label.                                |
| **Static inner names** | Internal matrix legs (Python, Docker, E2E)                | Fixed labels; GitHub appends matrix suffix. Brand via caller `name:`. |

<!-- markdownlint-enable MD013 -->

Contract enforcement: `scripts/ci/quality/validate-static-job-names.sh` (also
covered by BATS). Do not use `matrix.`, `format(`, or ternary `&& … ||`
expressions in `job.name` on jobs that have `if:`.

### Tooling sparse-checkout

When a reusable workflow job invokes a script-backed composite from
`.lgtm-ci-tooling/.github/actions/`, the job's `Checkout lgtm-ci tooling` step
must sparse-checkout `scripts/ci/` alongside `.github/actions/` (cone mode).
Egress-only jobs that load only `harden-runner` and `resolve-egress-allowlist`
are exempt.

Contract enforcement: `scripts/ci/quality/validate-tooling-sparse-checkout.sh`
(covered by BATS).

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

## Harden-runner distribution

<!-- markdownlint-disable MD013 -->

Reusable workflows load egress composites from a **sparse checkout of lgtm-ci** into
`.lgtm-ci-tooling/`, then reference them by workspace path. Cross-repo callers must
not vendor `.github/actions/harden-runner` or `resolve-egress-allowlist`.

Caller-local `./.github/actions/harden-runner` resolves in the **consumer** workspace
and fails when those directories are absent. Do **not** use
`lgtm-hq/lgtm-ci/.github/actions/...@\${{ }}` in `steps[*].uses` — GitHub does not
allow expressions in action `@ref` segments ([runner#895](https://github.com/actions/runner/issues/895));
actionlint reports errors and workflows may fail validation.

```yaml
- name: Checkout repository
  uses: actions/checkout@<pin> # v6.0.2
  with:
    persist-credentials: false

- name: Checkout lgtm-ci tooling
  uses: actions/checkout@<pin> # v6.0.2
  with:
    repository: lgtm-hq/lgtm-ci
    path: .lgtm-ci-tooling
    ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || github.workflow_sha }}
    sparse-checkout: |
      .github/actions/harden-runner
      .github/actions/resolve-egress-allowlist
      scripts/ci/
    sparse-checkout-cone-mode: true
    persist-credentials: false

- name: Resolve egress allowlist
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist
  with:
    egress-policy: ${{ inputs.egress-policy }}
    egress-preset: ${{ inputs.egress-preset }}
    allowed-endpoints: ${{ inputs.allowed-endpoints }}
    allowed-endpoints-mode: ${{ inputs.allowed-endpoints-mode }}

- name: Harden runner
  uses: ./.lgtm-ci-tooling/.github/actions/harden-runner
  with:
    egress-policy: ${{ inputs.egress-policy }}
    allowed-endpoints: ${{ steps.egress.outputs['allowed-endpoints'] }}
```

Pin the reusable workflow `uses:` line to a commit SHA in production and pass the
same ref as `tooling-ref` when testing branches. When `tooling-ref` is empty,
reusables fall back to `github.workflow_sha`. First-party `renovate.yml` may keep
in-repo `./.github/actions/...` because the job runs in lgtm-ci.

Callers may still pin **other** lgtm-ci composites with
`lgtm-hq/lgtm-ci/.github/actions/foo@<static-sha>` from their own workflow files;
that pattern does not apply inside reusable workflow steps that need dynamic refs.

### Release workflows (`reusable-release-auto-tag`, `reusable-release-version-pr`)

These jobs use **two** lgtm-ci checkouts:

1. **Egress tooling** (before the GitHub App token) — sparse-checkout only
   `harden-runner` and `resolve-egress-allowlist`, then resolve → harden.
2. **Scripts tooling** (after `create-github-app-token` and the full repository
   checkout) — sparse-checkout `scripts/ci/` with the app installation token.

Keep `Create GitHub App installation token` before any step that uses
`steps.app-token.outputs` (actionlint enforces step order).

<!-- markdownlint-enable MD013 -->

The `harden-runner` bundle is **self-contained** (`lib/egress/`). Canonical preset
definitions live in `scripts/ci/lib/egress/presets.sh`; release maintainers run
`scripts/ci/actions/sync-harden-runner-bundle.sh` before tagging.
`resolve-egress-allowlist` invokes the bundled resolver script in a **prior workflow
step** because step-security's pre-hook runs before composite steps and cannot read
`steps.resolve.outputs` from inside `harden-runner`.

Do **not** use `.lgtm-ci-egress` sparse checkouts for the composite.

## Egress presets

Reusable workflows default to `egress-policy: block` and
`allowed-endpoints-mode: replace`. `resolve-egress-allowlist` expands presets via
bundled `lib/egress/presets.sh` (synced from `scripts/ci/lib/egress/presets.sh`).

| Mode      | Behavior                                                                        |
| --------- | ------------------------------------------------------------------------------- |
| `replace` | Non-empty `allowed-endpoints` overrides `egress-preset`; empty uses preset only |
| `append`  | Merges preset + `allowed-endpoints` (deduped, first-seen wins)                  |

Use `append` to keep lgtm-ci defaults and add project-specific hosts. Empty
`allowed-endpoints` under `append` still means preset-only (same as omitting extras).
`audit` mode is unchanged (no enforced allowlist).

| Preset           | Use case                                                             |
| ---------------- | -------------------------------------------------------------------- |
| `github-minimal` | PR summaries and reports (API, tooling checkout, workflow artifacts) |
| `github-pages`   | GitHub Pages deploy/publish (OIDC)                                   |
| `github-tooling` | Validate action pinning + GitHub raw/codeload                        |
| `docker`         | Docker build/pull/push (`reusable-docker.yml`)                       |
| `playwright`     | Playwright E2E + browser CDN downloads                               |
| `pypi`           | PyPI/TestPyPI publish and availability checks                        |
| `rubygems`       | RubyGems publish                                                     |
| `npm-publish`    | npm publish + Sigstore attestation                                   |
| `quality`        | Docker `lintro chk` (default on quality lint)                        |
| `sbom`           | SBOM, Grype scan, Sigstore attestation                               |
| `scorecard`      | OpenSSF Scorecard (`reusable-scorecards.yml`)                        |

```yaml
egress-policy: block
egress-preset: quality
```

`reusable-quality-lint.yml` defaults `egress-preset: quality` and
`timeout-minutes: 45`.

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

### Quality / Lintro (Docker `lintro chk`)

Prefer the preset (canonical list in `scripts/ci/lib/egress/presets.sh`):

```yaml
egress-policy: block
egress-preset: quality
```

Expanded allowlist includes GitHub, GHCR, Docker Hub, PyPI, npm/crates, semgrep,
OSV, bun/rust/uv hosts, and `api.deps.dev` (py-lintro dogfooding lint).

### GitHub Pages publish (OIDC)

Prefer the preset (used by `reusable-deploy-pages.yml`,
`reusable-deploy-site-with-reports.yml` (`egress-deploy-preset`), and the
`publish` job in `reusable-test-e2e-matrix.yml` via `publish-egress-preset`):

```yaml
egress-policy: block
egress-preset: github-pages
```

`reusable-deploy-site-with-reports.yml` uses `egress-build-preset` (default
`playwright`) on the build job and `egress-deploy-preset` (default `github-pages`)
on deploy. Use `allowed-endpoints-build` or `allowed-endpoints-deploy` for
per-job overrides; shared `allowed-endpoints` / `allowed-endpoints-mode` apply to both jobs
when the per-job inputs are empty.

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

Used on the **caller** upload job. Run `prepare-pypi-upload`, then
`pypa/gh-action-pypi-publish` and optional `attest-build-provenance` as
**top-level workflow steps** — do not nest pypa inside lgtm-ci composites.
Set `environment: pypi` on that job. `prepare-pypi-upload` downloads workflow
artifacts and checks out lgtm-ci tooling — include artifact and GitHub hosts
below. `pypa/gh-action-pypi-publish` pulls `ghcr.io/pypa/gh-action-pypi-publish`
— include `ghcr.io:443` and `pkg-containers.githubusercontent.com:443`.

```yaml
egress-policy: block
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

### SBOM + attestation

```yaml
egress-policy: block
egress-preset: sbom
```

Covers GitHub, Anchore (Syft/Grype), Sigstore attestation hosts. Canonical list:
`scripts/ci/lib/egress/presets.sh` (preset name `sbom`).

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

## Fork PR summaries and reports

PR summaries and reports are skipped automatically on fork PRs (`head.repo.fork == true`).
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
      publish-test-summary: true
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        registry.npmjs.org:443
```
