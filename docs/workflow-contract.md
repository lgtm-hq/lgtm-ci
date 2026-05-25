# Reusable Workflow Contract

All `lgtm-ci` reusable workflows share a common consumer contract.

## Standard inputs

Where applicable, workflows accept:

| Input | Purpose |
| --- | --- |
| `tooling-ref` | Pin lgtm-ci scripts/actions (defaults to caller workflow SHA) |
| `egress-policy` | `audit` or `block` for StepSecurity harden-runner |
| `allowed-endpoints` | Allowlist when `egress-policy: block` |
| `job-name` | Visible GitHub check name |
| `runner-image` | Runner label for long-running jobs |
| `timeout-minutes` | Job timeout |
| `post-pr-comment` | Enable PR summary comments |
| `comment-marker` / `comment-title` | PR comment identity |
| `draft-pr-skip` | Skip PR jobs on draft pull requests |

## Permissions by mode

| Mode | Caller permissions |
| --- | --- |
| Test / quality only | `contents: read` |
| PR comments | `contents: read`, `pull-requests: write` |
| Publish to Pages | `contents: write`, `pages: write`, `id-token: write` (separate workflow) |
| Release version PR | `contents: write`, `pull-requests: write` + app secrets |
| Package publish | `contents: read`, `id-token: write`, `attestations: write` (as required) |

`reusable-test-node.yml` no longer includes a publish job. Use
`reusable-test-node-publish.yml` in a separate caller job when publishing is
required.

### Isolated publish jobs (Pages / coverage badge)

`reusable-test-python-publish.yml` and `reusable-test-node-publish.yml` run in a
**fresh workspace** (separate reusable-workflow job from the test matrix). The
caller repository checkout must initialize `.git` before tooling is added:

1. Harden runner (`step-security/harden-runner` — no tooling checkout yet)
2. Checkout repository (caller repo at workspace root)
3. Checkout lgtm-ci tooling (`.lgtm-ci-tooling/` alongside the repo)
4. Download artifacts, badge generation, GitHub Pages publish (local tooling actions)

`clean: false` on the repository checkout does **not** help here: without an
existing `.git`, `actions/checkout` wipes the workspace and deletes
`.lgtm-ci-tooling/` if tooling was checked out first. Match
`reusable-publish-pypi.yml` and `reusable-pr-auto-assign.yml`.

## Low-noise Rust and Node checks

Prefer split workflows to avoid skipped checks in PR UI:

| Use case | Workflow |
| --- | --- |
| Rust build only | `reusable-rust-build.yml` or `reusable-test-rust-build.yml` |
| Rust coverage only | `reusable-rust-coverage.yml` or `reusable-test-rust-coverage.yml` |
| Node Vitest tests | `reusable-test-node.yml` with `test-command` empty |
| Node custom command | `reusable-test-node.yml` with `test-command` set |

`reusable-test-rust.yml` remains for backward compatibility but may show
skipped jobs when only build or only coverage is enabled.

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

## Action pinning policy

Org repos must pin GitHub Actions to **commit SHAs only** and add a trailing
Renovate version comment on the same line. Tag refs (for example `@v4`) fail
`reusable-validate-action-pinning.yml` unless the action is listed in the narrow
`allow-tag-exceptions` input.

| Pin | Result |
| --- | --- |
| `uses: org/action@sha` | Fail — missing `# vX.Y.Z` |
| `uses: org/action@v1.2.3` | Fail — tag pin |
| `uses: org/action@sha # v1.2.3` | Pass |
| `tooling-ref: 'sha'` | Fail — missing `# vX.Y.Z` |
| `tooling-ref: 'sha' # v0.18.4` | Pass |
| `ref: 'sha'` under `repository: lgtm-hq/lgtm-ci` checkout | Same rule as `tooling-ref` |

Use the **release commit SHA** for `tooling-ref` and lgtm-ci checkout `ref` pins, not the
annotated tag object SHA. For example, `v0.18.4` resolves to release commit
`d3736367191ddaf56c41804d2dd5174732ed2d2b`, not tag object `95e202ae…`.

Canonical examples:

```yaml
uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4
tooling-ref: 'd3736367191ddaf56c41804d2dd5174732ed2d2b' # v0.18.4
```

Template expressions (for example `${{ inputs.tooling-ref }}`) are ignored.
Bare SHA pins without version comments are invisible to Renovate and are blocked
by design.

## Dependency review

`reusable-dependency-review.yml` runs on `pull_request` and `merge_group`
events. Do not invoke it from plain `push` workflows unless you accept the job
being skipped.

## Merge queue (`merge_group`)

Callers using GitHub merge queue can add `merge_group:` triggers to thin
caller workflows alongside `pull_request:`.

| Workflow | `merge_group` behavior |
| --- | --- |
| `reusable-codeql.yml` | Safe to run — no PR context required |
| `reusable-validate-action-pinning.yml` | Safe to run — no PR context required |
| `reusable-dependency-review.yml` | Runs on `merge_group` (same as PR) |
| `reusable-semantic-pr-title.yml` | Skips on `merge_group` — title validated on PR |

Semantic title validation is intentionally skipped in the merge queue because
`amannn/action-semantic-pull-request` requires pull request context.

## Fork PR comments

PR comments are skipped automatically on fork PRs (`head.repo.fork == true`).
This is enforced in `scripts/ci/actions/post-pr-comment.sh` and workflow `if`
conditions.

## Rustume migration example

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality.yml@<sha>
    permissions:
      contents: read
      packages: read
      pull-requests: write
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
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-coverage.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "🦀 Rust Coverage"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        static.rust-lang.org:443
        crates.io:443

  web-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@<sha>
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
