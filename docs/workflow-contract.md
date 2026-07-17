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
| `runner-image`                     | GitHub-hosted runner OS label (default `ubuntu-24.04`)                 |
| `runner-map`                       | JSON platform→runner map for multi-arch Docker (default `{}`)          |
| `timeout-minutes`                  | Job timeout                                                            |
| `publish-test-summary`             | Publish test/coverage summary comment on the pull request              |
| `comment-marker` / `comment-title` | Upsert identity for summary comments (marker + heading)                |
| `draft-pr-skip`                    | Skip PR jobs on draft pull requests (default `true` on test reusables) |

<!-- markdownlint-enable MD013 -->

`tooling-ref` is listed above for workflows that accept it. See
[Action-only reusables](#action-only-reusables) for workflows where the input
pins egress composites only (not `scripts/ci/`).

## Action-only reusables

Some reusables wrap a third-party GitHub Action for a single check. They do
**not** run the full lgtm-ci script suite — only optional egress hardening
composites from a sparse lgtm-ci checkout (`harden-runner`,
`resolve-egress-allowlist`).

<!-- markdownlint-disable MD013 -->

| Reusable                             | Third-party action                         |
| ------------------------------------ | ------------------------------------------ |
| `reusable-pr-labeler.yml`            | `actions/labeler`                          |
| `reusable-dependency-review.yml`     | `actions/dependency-review`                |
| `reusable-semantic-pr-title.yml`     | `amannn/action-semantic-pull-request`      |
| `reusable-codeql.yml`                | `github/codeql-action/*`                   |
| `reusable-scorecards.yml`            | OpenSSF Scorecard action                   |

<!-- markdownlint-enable MD013 -->

For these workflows:

- Pin the reusable `uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-*.yml@<sha>`
  ref in production.
- `tooling-ref` is **optional** on the action-only wrappers that still expose it
  (labeler, dependency-review, semantic-pr-title, codeql) and pins egress
  composites only — not CI scripts. When omitted, those reusables default to
  `github.workflow_sha` (the pinned workflow SHA). Pass a matching `tooling-ref`
  only when testing unreleased egress composite changes on a branch.
- `reusable-scorecards.yml` does **not** accept `tooling-ref` (or
  `egress-preset` / `allowed-endpoints-mode`): the scorecard publish allowlist
  forbids lgtm-ci composites, so egress uses a static `allowed-endpoints`
  default (#540).
- Do **not** assume `tooling-ref` pins the third-party action inside the
  reusable; those actions are pinned by SHA inside the workflow YAML.

`reusable-semantic-pr-title.yml` also sparse-checkouts `scripts/ci/` for small
helper scripts (`prepare-semantic-pr-lists.sh`, `validate-pr-title-length.sh`).
Pass `tooling-ref` when testing unreleased fixes to those helpers.

Contrast with **script-backed reusables** (quality, test-*, validate-*,
pr-auto-assign, release-*, publish-*, etc.) where callers **should** pass
`tooling-ref` matching the workflow pin so `scripts/ci/` and composites stay
aligned.

### Runner pinning

Script-backed reusables expose `runner-image` on **every** job so callers can
pin OS reproducibility (for example `ubuntu-24.04`). Defaults are
`ubuntu-24.04`; production callers **should** pass an explicit pin.

Multi-arch Docker builds use `runner-map` instead of `runner-image`. Pass a JSON
object mapping platform to runner label (for example
`{"linux/arm64":"ubuntu-24.04-arm"}`). Platforms not in the map default to
`ubuntu-24.04` with QEMU. Coordinator jobs inside the Docker workflow family
(`classify`, `merge`, summaries, scan) stay on fixed `ubuntu-24.04`
coordinators and are not caller-pinnable.

#### Docker workflow family and migration path

Since #381 `reusable-docker.yml` is a thin orchestrator: its `classify` job
resolves the build strategy from `platforms`/`push`/`validate-on-pr` and
`runner-map`, then delegates to the focused reusables. Existing callers keep
working unchanged.

<!-- markdownlint-disable MD013 -->

| Workflow                            | Responsibility                                                         | `runner-map`?                      |
| ----------------------------------- | ---------------------------------------------------------------------- | ---------------------------------- |
| `reusable-docker.yml`               | Orchestrator: classify + delegate (supported entry point)              | Yes (resolved by `classify`)       |
| `reusable-docker-build.yml`         | Single-platform or QEMU multi-platform build + scan (non-split path)   | No (fixed `ubuntu-24.04` + QEMU)   |
| `reusable-docker-multiplatform.yml` | Per-platform matrix build + smoke/health gates + manifest merge + sign | No (takes classify `matrix` input) |
| `reusable-docker-smoke-test.yml`    | Standalone validation of a published image by immutable digest         | No (`runner-image` input)          |

<!-- markdownlint-enable MD013 -->

Migration: callers that only ever hit one path can pin the focused reusable
directly and skip the classify hop — single-platform (or QEMU) consumers call
`reusable-docker-build.yml`; multi-arch consumers that already know their
platform split call `reusable-docker-multiplatform.yml` and pass the matrix
JSON themselves (an array of
`{"platform": ..., "slug": ..., "runner": ..., "qemu": ...}` entries, the
same shape `classify` emits). Post-publish image validation is available
standalone via `reusable-docker-smoke-test.yml`. The staging-tag scheme
(`build-<run_id>-<slug>` children of the release index) is part of the
contract and must not change; the GHCR staging pruner depends on it.

Nested job names: when called through the orchestrator, GitHub prefixes check
names with the delegating job (for example
`<caller-job> / Docker build / Build and Push` or
`<caller-job> / Docker multi-platform / Merge Manifests`). Update branch
protection / merge-queue required checks accordingly when upgrading across
the #381 split.

#### Runner pinning exceptions

These reusables intentionally omit `runner-image`:

<!-- markdownlint-disable MD013 -->

| Reusable                             | Rationale                                              |
| ------------------------------------ | ------------------------------------------------------ |
| `reusable-codeql.yml`                | Action-only wrapper (`github/codeql-action/*`)         |
| `reusable-dependency-review.yml`     | Action-only wrapper                                    |
| `reusable-scorecards.yml`            | Action-only wrapper                                    |
| `reusable-semantic-pr-title.yml`     | Action-only wrapper                                    |
| `reusable-pr-labeler.yml`            | Action-only wrapper                                    |
| `reusable-publish-npm.yml`           | OIDC trusted publishing + npm provenance; Node 24      |
| `reusable-publish-gem.yml`           | OIDC publish; runner pin under attestation review      |

<!-- markdownlint-enable MD013 -->

Contract enforcement: `scripts/ci/quality/validate-runner-contract.sh` (covered
by BATS). See [reusable-workflows.md](reusable-workflows.md#runner-pinning) for
caller examples including `runner-map`.

### Job timeouts

Every reusable exposes a `timeout-minutes` input (type: number) wired to
`timeout-minutes:` on its primary job so callers can bound runtime. Defaults
are sized per workflow (small API wrappers 5–10, builds/tests 15–60;
scan-style workflows such as CodeQL and Scorecard get larger defaults). Jobs
that compose another reusable via `uses:` rely on the called workflow's own
`timeout-minutes` default instead.

Beyond the caller-facing input, **every job with `runs-on` must declare a
`timeout-minutes`** — either wired to `${{ inputs.timeout-minutes }}` (the
main workload) or a literal cap. Lightweight coordinator legs (matrix
`prepare`/`setup`, result `aggregate`/`merge`/`publish`, and pages-status
jobs) and the failure-reporter legs keep an **independent literal cap**
(`timeout-minutes: 10`): the caller's `timeout-minutes` bounds the main test
job, and lowering it must not silently uncap — or, for reporters, cancel —
these short-running legs. Only jobs that hand off to another reusable via
`uses:` are exempt, because they carry no `runs-on` of their own.

`scripts/ci/quality/validate-runner-contract.sh` enforces both the input's
presence and the per-job cap. It maintains two exception mechanisms mirroring
the runner-image exceptions: `TIMEOUT_MINUTES_EXCEPTIONS` (file-level, exempt
from exposing the input) and `TIMEOUT_PER_JOB_EXCEPTIONS` (job-level, keyed by
`<file>.yml:<job-id>`, exempt from the per-job cap). Both are currently empty;
add an entry here with justification before adding one to the script.

#### Egress policy exceptions

`reusable-publish-rust-release.yml` intentionally omits the `egress-policy`
input. Every job hardcodes `egress-policy: block` and validates the runner
policy at tier `strict`, so callers cannot downgrade release publishing to
`audit`. Callers can still extend the allowlist for the binary build job
through `allowed-endpoints` and `allowed-endpoints-mode`; the tag
verification and GitHub release jobs keep their fixed presets
(`github-minimal` and `github-tooling`) and do not accept caller endpoints.
Contract checks should not flag the missing input.

See [reusable-workflows.md](reusable-workflows.md) (CodeQL build-mode) for
interpreted-language scanning guidance.

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

- Coverage not requested (`coverage: false` / `coverage-enabled: false`):
  `generate-test-summary.sh` posts pass/fail totals only — **no** Coverage /
  Code Coverage / Coverage Details sections and **no** “Unable to retrieve
  coverage…” warning (disabled coverage must not look like a broken run)
- Coverage collected with a downloadable artifact (Rust LCOV, Python JSON when
  `upload-coverage: true`): `generate-coverage-comment` (rich table)
- Coverage collected without an artifact (e.g. Python with `upload-coverage: false`):
  `generate-test-summary.sh` (pass/fail totals with coverage percent; requires
  `coverage-enabled: true`)
- Coverage requested but the report/percent is missing: totals summary keeps the
  warning-flavored “Unable to retrieve coverage…” UX
- Shell/kcov: totals only (rich table not yet supported); with `coverage: false`
  the coverage block is omitted like other languages

Callers thread `inputs.coverage` (or `true` for `reusable-coverage`) into
`reusable-publish-test-summary.yml` as `coverage-enabled`, which sets
`COVERAGE_ENABLED` for `generate-test-summary.sh`.

Rich coverage comments use `generate-coverage-comment` with an optional
`test-suite-name` input. When set, the visible heading becomes
`## 📊 Code Coverage Report — {test-suite-name}`; `comment-marker` remains the
upsert identity.

Node test reusables (`reusable-test-node`, `reusable-test-node-custom`) upload the
`node-coverage` artifact from `{working-directory}/{coverage-summary-file}`.
`publish-test-summary` must pass the same path (including the `working-directory`
prefix when it is not `.`) as `coverage-file` to
`reusable-publish-test-summary.yml` so `download-artifact` resolves the summary
inside `coverage-test-summary/`.

### Compat vs coverage contract (#340)

Rust, Node, and Python test reusables share a **two-mode contract**:

<!-- markdownlint-disable MD013 -- compat/coverage table; column text exceeds default line length -->

| Mode         | Multi-runtime input                   | `coverage` | `publish-test-summary` | PR comment |
| ------------ | ------------------------------------- | ---------- | ---------------------- | ---------- |
| **Compat**   | `*-versions` / `rust-toolchains`      | `false`    | `false`                | none       |
| **Coverage** | single `*-version` / `rust-toolchain` | `true`     | `true` (optional)      | one        |

<!-- markdownlint-enable MD013 -->

Multi-runtime matrix inputs:

- Python: `python-versions` (comma-separated)
- Node: `node-versions` (comma-separated)
- Rust: `rust-toolchains` (comma-separated)

Single-runtime inputs (`python-version`, `node-version`, `rust-toolchain`, or
deprecated Rust `toolchain`) allow `coverage: true` and `publish-test-summary:
true`.

**Enforcement:** `validate-test-compat-coverage-contract.sh` runs in each
reusable `prepare` job and fails when a non-empty multi-version matrix is
combined with `coverage: true` or `publish-test-summary: true`.

**Permissions split:** test/matrix jobs use `contents: read` only; PR comments
run in a separate `publish-test-summary` job (`pull-requests: write`) that
delegates to `reusable-publish-test-summary.yml`.

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

All language test reusables route PR summaries through a single
`publish-test-summary` job → `reusable-publish-test-summary.yml` (no skipped
sibling when `coverage: true`). Node no longer uses inline matrix publish jobs
(#292).

<!-- markdownlint-disable MD013 -- permissions matrix; workflow column lists exceed default line length -->

| Mode                  | Caller permissions                                   | Workflow                                     |
| --------------------- | ---------------------------------------------------- | -------------------------------------------- |
| Quality / lint only   | `contents: read`, `packages: read`                   | `reusable-quality-lint.yml`                  |
| Quality summary       | `contents: read`, `pull-requests: write`             | `reusable-publish-quality-summary.yml`       |
| Test / coverage only  | `contents: read`                                     | Reusables with `publish-test-summary: false` |
| Test / report publish | `contents: read`, `pull-requests: write`             | `reusable-publish-test-summary.yml`,         |
|                       |                                                      | `reusable-publish-artifact-report.yml`       |
| Publish to Pages      | `contents: read`, `pages: write`, `id-token: write`  | Separate publish job                         |
| Release version       | `contents: write`, `pull-requests: write`,           | `reusable-release-version-pr.yml`            |
|                       | `actions: read`, `issues: write`                     |                                              |
| Release auto-tag      | `contents: write`, `actions: read`, `issues: write`  | `reusable-release-auto-tag.yml`              |
| Release failure issue | `actions: read`, `contents: read`, `issues: write`   | `report-release-failure` follow-up job       |
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

1. Harden runner (`uses: step-security/harden-runner@<pinned SHA>` — first step;
   allowlist from inputs/literals)
2. Checkout repository (caller repo at workspace root)
3. Checkout lgtm-ci tooling (`.lgtm-ci-tooling/` — sparse-checkout must include egress
   composites and any scripts/actions the job needs)
4. Resolve egress allowlist / checkout-and-harden (scripts-dir; do not feed outputs
   into harden-runner)
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
rulesets **must require that exact prefixed path** for every `uses:` gate —
the inner `job-name` alone is never sufficient. Inline `runs-on` jobs are the
only unprefixed contexts: the ruleset matches their `name:` directly (for
example `🔐 Security Audit`). A ruleset that requires an unprefixed name for a
`uses:` gate leaves the PR stuck on **Expected** while Actions shows the green
prefixed check.

The registry of org rulesets, their GitHub ids, and the exact required
contexts lives in [org-rulesets.md](org-rulesets.md), together with the
export/sync tooling under `scripts/ci/org/`. When a check name must change,
update the org ruleset to the new `{caller_job_id} / {job-name}` path in the
same change.

**Aggregate gate:** When a single ruleset context should summarize one or more
work jobs, add a thin caller job that calls `reusable-required-check.yml`
instead of hand-rolled `runs-on` shims. The gate itself is a `uses:` job, so
the ruleset must require its prefixed path too (below:
`test-suite-coverage / 🧪 Test Suite & Coverage`). Pass `upstream-result` and
optional `passed-output` / `status-output` from the work job. Use `always()`
on the caller job so the gate still runs when the upstream job fails.

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

Egress **enforcement** requires a **direct** remote
`step-security/harden-runner@<pinned SHA>` workflow step. GitHub skips `pre`/`post`
hooks for workspace-local actions and for actions nested inside composites, and
step-security installs its monitoring agent only in `pre` (v2.20.0).

`allowed-endpoints` must come from workflow **inputs** or literals available at
job start — not `steps.*.outputs` (empty when `pre` runs).

Allowlist **resolution** helpers (`resolve-egress-allowlist`, plus support files
under `.github/actions/harden-runner/`) still ship via sparse checkout into
`.lgtm-ci-tooling/` when needed; cross-repo callers must not vendor those
composites. Hardening itself is always the remote step-security action.

Do **not** use `lgtm-hq/lgtm-ci/.github/actions/...@\${{ }}` in `steps[*].uses` —
GitHub does not allow expressions in action `@ref` segments
([runner#895](https://github.com/actions/runner/issues/895)).

Most reusable workflows use the shared `checkout-and-harden` composite (#379) to
check out tooling and resolve the allowlist, then call step-security directly:

```yaml
- name: Checkout repository
  uses: actions/checkout@<pin> # v7.0.0
  with:
    persist-credentials: false

- name: Checkout lgtm-ci tooling
  uses: actions/checkout@<pin> # v7.0.0
  with:
    repository: lgtm-hq/lgtm-ci
    path: .lgtm-ci-tooling
    ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || github.workflow_sha }}
    sparse-checkout: |
      .github/actions/checkout-and-harden
    sparse-checkout-cone-mode: true
    persist-credentials: false

- name: Harden runner
  uses: step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920 # v2.20.0
  with:
    egress-policy: ${{ inputs.egress-policy }}
    # inputs.allowed-endpoints (not step outputs): harden-runner pre runs at job start
    allowed-endpoints: ${{ inputs.allowed-endpoints }}

- name: Checkout and harden
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
  with:
    tooling-ref: ${{ inputs.tooling-ref }}
    egress-policy: ${{ inputs.egress-policy }}
    egress-preset: ${{ inputs.egress-preset }}
    allowed-endpoints: ${{ inputs.allowed-endpoints }}
    allowed-endpoints-mode: ${{ inputs.allowed-endpoints-mode }}
    sparse-checkout-extra: |
      scripts/ci/
```

Workflows that cannot use the composite keep the explicit tooling checkout →
`resolve-egress-allowlist` → `step-security/harden-runner` sequence for tooling
layout, but still pass allowlists via **inputs or literals** (the action `pre`
hook cannot see step outputs): the release workflows' two-phase checkouts
(`reusable-release-auto-tag`, `reusable-release-version-pr`), the tiered Rust
workflows where `validate-runner-policy` must run between checkout and resolve
(`reusable-build-rust-binaries`, `reusable-publish-rust-release`), and the
bootstrap/fallback flow in `reusable-validate-lintro-version`.

```yaml
- name: Harden runner
  uses: step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920 # v2.20.0
  with:
    egress-policy: ${{ inputs.egress-policy }}
    allowed-endpoints: ${{ inputs.allowed-endpoints }}

- name: Resolve egress allowlist
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist
  with:
    egress-policy: ${{ inputs.egress-policy }}
    egress-preset: ${{ inputs.egress-preset }}
    allowed-endpoints: ${{ inputs.allowed-endpoints }}
    allowed-endpoints-mode: ${{ inputs.allowed-endpoints-mode }}
```

Pin the reusable workflow `uses:` line to a commit SHA in production and pass the
same ref as `tooling-ref` when testing branches. When `tooling-ref` is empty,
reusables fall back to `github.workflow_sha`. First-party `renovate.yml` resolves
allowlists via in-repo `./.github/actions/resolve-egress-allowlist` and hardens
with the same pinned `step-security/harden-runner` SHA.

Callers may still pin **other** lgtm-ci composites with
`lgtm-hq/lgtm-ci/.github/actions/foo@<static-sha>` from their own workflow files;
that pattern does not apply inside reusable workflow steps that need dynamic refs.

### Release workflows (`reusable-release-auto-tag`, `reusable-release-version-pr`)

These jobs use **two** lgtm-ci checkouts:

1. **Egress tooling** (before the GitHub App token) — sparse-checkout
   `harden-runner` (resolve script bundle) and `resolve-egress-allowlist`, then
   resolve → direct `step-security/harden-runner`.
2. **Scripts tooling** (after `create-github-app-token` and the full repository
   checkout) — sparse-checkout `scripts/ci/` with the app installation token.

Keep `Create GitHub App installation token` before any step that uses
`steps.app-token.outputs` (actionlint enforces step order).

<!-- markdownlint-enable MD013 -->

The resolve script bundle under `.github/actions/harden-runner/` is
**self-contained** (`lib/egress/`). Canonical preset definitions live in
`scripts/ci/lib/egress/presets.sh`; release maintainers run
`scripts/ci/actions/sync-harden-runner-bundle.sh` before tagging.
Reusable workflows bake the default preset into the `allowed-endpoints` input
so harden-runner `pre` receives a non-empty allowlist at job start.

Do **not** use `.lgtm-ci-egress` sparse checkouts for the composite.

### Runner policy tiers {#runner-policy-tiers}

Reusable workflows that support multi-platform or release builds declare a **tier**
via `validate-runner-policy` before `resolve-egress-allowlist` and `harden-runner`.
Consumers cannot override the tier — it is baked into the reusable contract.

<!-- markdownlint-disable MD013 MD060 -->

| Tier         | `block` on GH Linux | `block` on GH Win/macOS | `block` on self-hosted | `audit` (any) |
| ------------ | ------------------- | ----------------------- | ---------------------- | ------------- |
| `strict`     | Enforce             | Hard fail               | Enforce                | Hard fail     |
| `hardened`   | Enforce             | Skip + warn             | Enforce                | Hard fail     |
| `permissive` | Enforce (advisory)  | Skip + log              | Skip + log             | Skip          |

**Egress capabilities** ([StepSecurity harden-runner](https://github.com/step-security/harden-runner)):

| Runner type                  | `egress-policy: block` |
| ---------------------------- | ---------------------- |
| GitHub-hosted Linux          | Supported              |
| GitHub-hosted Windows/macOS  | Audit only today       |
| Self-hosted (agent in image) | Supported on any OS    |

<!-- markdownlint-enable MD013 MD060 -->

New reusables call `validate-runner-policy` first, then conditionally run
`resolve-egress-allowlist` and a direct `step-security/harden-runner@<pinned SHA>`
step when `enforce-egress` is `true`.

**Usage guidance:**

- `strict` — Rust CLI releases, Node/Python CI, Docker builds (Linux-only matrices)
- `hardened` — Native desktop verification (Tauri, Electron), weekly native test legs
- `permissive` — Exotic builds (iOS/Xcode, Android signing); document justification
  in the workflow YAML

```yaml
- name: Validate runner policy
  id: policy
  uses: ./.lgtm-ci-tooling/.github/actions/validate-runner-policy
  with:
    tier: hardened
    egress-policy: block
    runner-environment: ${{ runner.environment }}
    runner-os: ${{ runner.os }}

- name: Harden runner
  if: steps.policy.outputs['enforce-egress'] == 'true'
  uses: step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920 # v2.20.0
  with:
    egress-policy: block
    allowed-endpoints: ${{ inputs.allowed-endpoints }}
```

### Rust release contract

`reusable-build-rust-binaries.yml` (tier `strict`) cross-compiles from Linux
runners under block mode. `reusable-publish-rust-release.yml` orchestrates
tag verification → binary build → GitHub release.

**Default target matrix (v1):** `x86_64-unknown-linux-musl`,
`aarch64-unknown-linux-gnu` (via `cross`), `x86_64-pc-windows-msvc` (via `cross`).
Darwin targets are excluded from the default matrix; pass a JSON `targets` override
for unsigned macOS binaries.

**Artifact naming:** `{artifact-prefix}-{target}` per matrix leg. Each artifact
contains `{package}-{version}-{target}.tar.gz` or `.zip` with the binary at the
archive root (`cargo-binstall` compatible) plus a `SHA256SUMS` manifest.

```yaml
release:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-rust-release.yml@<sha>
  with:
    tooling-ref: "<sha>"
    packages: "my-cli,my-server"
```

### Release failure reporting

Both release reusables include an optional `report-release-failure` follow-up job
that runs when the primary job fails (`needs.<job>.result == 'failure'`). The
job uses `egress-preset: github-minimal` (GitHub API only) and declares its own
`actions: read`, `contents: read`, and `issues: write` permissions. Callers
must grant at least `actions: read` and `issues: write` on the reusable-workflow
call job (in addition to the primary release permissions above) or GitHub rejects
the workflow at startup.

<!-- markdownlint-disable MD013 -->

| Input                   | Default                                    | Purpose                                       |
| ----------------------- | ------------------------------------------ | --------------------------------------------- |
| `report-failures`       | `true`                                     | Opt out when the repo handles alerting itself |
| `failure-issue-labels`  | `bug,ci,release,automation,infrastructure` | Labels on auto-opened failure issues          |
| `failure-target-branch` | *(empty → repository default branch)*      | Branch filter for issue notifications         |

<!-- markdownlint-enable MD013 -->

Failure issues deduplicate by deterministic issue title
(`fix(release): release automation failed on <branch> (<workflow-key>)`), then
fall back to a visible tracking key footer
(`release-automation-failure:<workflow-key>:<branch>`). A hidden HTML comment
marker is retained for backward compatibility. Recurring failures add comments
to the same open issue.

### Cargo auto-tag contract

`reusable-release-auto-tag.yml` supports Rust monorepos that tag from
`Cargo.toml` workspace versions instead of parsing `chore(release): version`
from the commit subject.

<!-- markdownlint-disable MD013 MD060 -->

| Input               | Default      | Purpose                                              |
| ------------------- | ------------ | ---------------------------------------------------- |
| `version-source`    | `commit`     | `commit` (default) or `cargo`                        |
| `version-file`      | `Cargo.toml` | Manifest path for workspace/package version          |
| `skip-if-unchanged` | `false`      | Skip when version matches the latest `tag-prefix` tag |

<!-- markdownlint-enable MD013 MD060 -->

Flow when `version-source: cargo`:

1. `guard-release-commit` — common; proceed only on `chore(release):` commits
2. `read-cargo-version.sh` — cargo-specific; read semver from `version-file`
3. `detect-previous-tag-version.sh` — conditional (`skip-if-unchanged: true`);
   read latest `tag-prefix` version
4. `check-version-unchanged.sh` — conditional (`skip-if-unchanged: true`);
   skip tagging when versions match
5. `create-tag.sh` — common; create and push the annotated tag

Callers should filter `on.push.paths` to the manifest (for example `Cargo.toml`)
and set `create-release: false` when release assets are published separately.

## Egress presets

Reusable workflows default to `egress-policy: block` and
`allowed-endpoints-mode: replace`. `resolve-egress-allowlist` expands presets via
bundled `lib/egress/presets.sh` (synced from `scripts/ci/lib/egress/presets.sh`).

### Pre-enforcement allowlist (harden-runner, since v0.50.0)

Since [#467](https://github.com/lgtm-hq/lgtm-ci/issues/467) (v0.50.0), reusables feed
the caller's `allowed-endpoints` **verbatim** to the job-start
`step-security/harden-runner` step, before `resolve-egress-allowlist` runs. That
pre-enforcement value **replaces** the reusable's default GitHub/Ubuntu baseline
whenever it is non-empty — even when `allowed-endpoints-mode: append` (append only
affects the later, non-enforcing resolution step for tooling/checkout helpers).

`step-security/harden-runner` splits `allowed-endpoints` on **spaces**. A
newline-separated `|` literal block (the common multiline YAML style) is treated as
a single unrecognised host:port token (the whole multiline string), which blocks
**all** egress — including `github.com:443` checkout. Prefer a folded scalar (`>-`)
with space-separated `host:port` tokens, or use `egress-preset` /
`allowed-endpoints-mode: append` with empty caller endpoints so the baked-in preset
reaches pre-enforcement.

Upgrade incidents during org-wide v0.52.3 adoption
([#510](https://github.com/lgtm-hq/lgtm-ci/issues/510)):
[homebrew-tap#126](https://github.com/lgtm-hq/homebrew-tap/pull/126),
[podex#152](https://github.com/lgtm-hq/podex/pull/152),
[Rustume#385](https://github.com/lgtm-hq/Rustume/pull/385),
[turbo-themes#526](https://github.com/lgtm-hq/turbo-themes/pull/526),
[py-lintro#1281](https://github.com/lgtm-hq/py-lintro/pull/1281).

A future release may restore pre-enforcement normalization (tracked in the same
[#467](https://github.com/lgtm-hq/lgtm-ci/issues/467) thread) so presets merge again
before the harden-runner `pre` hook runs; until then, treat non-empty
`allowed-endpoints` as the complete enforced allowlist.

The table below describes `resolve-egress-allowlist` / `allowed-endpoints-mode` only
(not the pre-enforcement harden-runner step):

| Mode      | Behavior                                                                        |
| --------- | ------------------------------------------------------------------------------- |
| `replace` | Non-empty `allowed-endpoints` overrides `egress-preset`; empty uses preset only |
| `append`  | Merges preset + `allowed-endpoints` (deduped, first-seen wins)                  |

Use `append` to keep lgtm-ci defaults and add project-specific hosts. Empty
`allowed-endpoints` under `append` still means preset-only (same as omitting extras)
and is the safe way to inherit the reusable preset at pre-enforcement.
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
| `npm-publish`    | npm OIDC trusted publish + Sigstore (`oauth2.sigstore.dev`)          |
| `quality`        | Docker `lintro chk` (default on quality lint)                        |
| `rust-release`   | Rust cross-compile releases (`reusable-build-rust-binaries.yml`)     |
| `sbom`           | SBOM, Grype scan, Sigstore attestation                               |
| `scorecard`      | OpenSSF Scorecard (`reusable-scorecards.yml`)                        |
| `osv-scanner`    | GitHub tooling + release assets + OSV APIs                           |

```yaml
egress-policy: block
egress-preset: quality
```

`reusable-quality-lint.yml` defaults `egress-preset: quality` and
`timeout-minutes: 45`.

## Egress block examples

### Allowlist formatting

**Wrong** — `|` block becomes one token; harden-runner blocks all egress:

```yaml
allowed-endpoints: |
  github.com:443
  api.github.com:443
```

**Right** — folded scalar (`>-`) yields space-separated hosts:

```yaml
allowed-endpoints: >-
  github.com:443
  api.github.com:443
```

**Right** — rely on preset (recommended when the reusable ships one):

```yaml
egress-preset: quality
allowed-endpoints-mode: append
allowed-endpoints: ''
```

Or add project-specific hosts without replacing the preset baseline:

```yaml
egress-preset: quality
allowed-endpoints-mode: append
allowed-endpoints: >-
  ghcr.io:443
```

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

For release builds, prefer the preset:

```yaml
egress-policy: block
egress-preset: rust-release
```

For workspace build/test only:

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

### npm publish (OIDC trusted publishing)

Prefer the preset (canonical list in `scripts/ci/lib/egress/presets.sh`):

```yaml
egress-policy: block
egress-preset: npm-publish
```

Includes `registry.npmjs.org:443`, Sigstore hosts, and
`oauth2.sigstore.dev:443` for OIDC trusted publishing. Use Node 24 via
`setup-node`; never `npm install -g npm`. See
[workflows/publishing.md](workflows/publishing.md#reusable-publish-npmyml).

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

`reusable-sbom.yml` defaults `fail-on-severity` to `critical` (breaking as of
issue #480). The Grype gate fails the job when findings meet or exceed that
threshold. Callers that need the previous advisory-only posture must pass
`fail-on-severity: ""` (or `none`):

```yaml
sbom:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
  with:
    fail-on-severity: "" # advisory-only; default is critical
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

### Tag verification (`verify-tags`)

`verify-tags` defaults to **true**: each `sha # vX.Y.Z` pin is checked by
resolving the commented tag through the GitHub API and comparing it to the
pinned SHA. A comment that resolves to a different SHA (a lying pin) fails
validation; a tag that cannot be resolved is reported as a warning, not a hard
failure. This requires a `GH_TOKEN` for API access — the action falls back
through the explicit `gh-token` input, a caller-set `GH_TOKEN` env var, then the
workflow token.

Offline/air-gapped runners, or environments where the GitHub API is
unreachable, opt out with `verify-tags: false`.

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

### Licensing: "Unknown License" on lgtm-ci composite actions

Consumers pinning `lgtm-hq/lgtm-ci/.github/actions/*@<sha>` may see
**License: Null / Unknown** for those rows in GitHub Dependency Review and
OpenSSF Scorecard's license check, even though this repository is **MIT**
(`LICENSE` at the repo root). This is a known GitHub platform limitation, not
a missing license:

- The `action.yml` metadata schema (`name`, `author`, `description`, `inputs`,
  `outputs`, `runs`, `branding`) has **no license/SPDX field**. There is
  nothing for a composite action to declare that GitHub's dependency graph
  will read.
- GitHub's `actions` ecosystem in the dependency graph does not currently
  inherit the referencing repository's `LICENSE` for cross-repo composite
  action paths (`owner/repo/path@ref`), so `dependency-review-action` and
  Scorecard report the license as unknown regardless of the upstream repo's
  actual license.

Every `action.yml` under `.github/actions/` carries an
`SPDX-License-Identifier: MIT` header comment for humans and license-scanning
tools that read files directly; it does not change what GitHub's dependency
graph reports, since the field isn't part of the schema GitHub parses.

**Consumer workaround:** pass `allow-dependencies-licenses` through
`reusable-dependency-review.yml` with the PURLs of the lgtm-ci composites you
consume, pinned to the tag/SHA you use. The dependency-review-action matches
`allow-dependencies-licenses` entries on namespace/name only (version is
ignored), so a single PURL per action covers every ref you pin to it. Slashes
in the composite subpath are percent-encoded (`%2F`):

<!-- markdownlint-disable MD013 -- long PURL examples -->

```yaml
jobs:
  dependency-review:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-dependency-review.yml@<sha> # vX.Y.Z
    with:
      allow-dependencies-licenses: >-
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fharden-runner,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcheckout-and-harden,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsecure-checkout,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-rust,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcreate-github-release
```

<!-- markdownlint-enable MD013 -->

Canonical PURLs for common composites (swap the trailing action name for any
other directory under `.github/actions/`):

<!-- markdownlint-disable MD013 -- wide PURL reference table -->

| Composite               | PURL (namespace/name)                                            |
| ------------------------ | ----------------------------------------------------------------- |
| `harden-runner`          | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fharden-runner` |
| `checkout-and-harden`    | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcheckout-and-harden` |
| `secure-checkout`        | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsecure-checkout` |
| `setup-rust`             | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-rust` |
| `setup-python`           | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-python` |
| `setup-node`             | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-node` |
| `create-github-release`  | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcreate-github-release` |

<!-- markdownlint-enable MD013 -->

For OpenSSF Scorecard, there is no equivalent per-dependency allowlist for the
license check today; document the expected "Unknown" result for lgtm-ci
composite rows rather than treating it as a regression. Re-check this section
if GitHub ships license enrichment for the `actions` ecosystem or adds a
`license` field to the action metadata schema — at that point the
`allow-dependencies-licenses` workaround and this note can be retired.

## Security audit (osv-scanner)

`reusable-security-audit.yml` centralizes the lintro Docker + osv-scanner audit
pattern used by Rust monorepos. The audit job runs
`scripts/ci/security/run-lintro-audit.sh` (override with `audit-script`), uploads
a PR comment artifact on `pull_request`, and uses `continue-on-error` plus an
explicit fail step so comment generation still runs when vulnerabilities are
found.

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                 | Default                                              | Notes                                           |
| --------------------- | ---------------------------------------------------- | ----------------------------------------------- |
| `lintro-image`        | pinned `ghcr.io/lgtm-hq/py-lintro` digest            | Same contract as `reusable-quality-lint`        |
| `audit-script`        | `.lgtm-ci-tooling/scripts/ci/security/run-lintro-audit.sh` | Repo-local override supported             |
| `upload-comment-artifact` | `true`                                           | Set `false` for push/schedule check-only          |
| `comment-marker`      | `security-audit-report`                              | Input on publish reusable                         |
| `egress-preset`       | `quality`                                            | Includes `api.osv.dev` and `api.deps.dev`       |

<!-- markdownlint-enable MD013 MD060 -->

Caller `on:` triggers are consumer-owned. Add `merge_group:` alongside
`pull_request:` when using merge queue — the audit job runs on both; PR comments
upload/post only on `pull_request`. Scheduled or push callers should set
`upload-comment-artifact: false` and omit the publish reusable caller job.

Grant `packages: read` on the audit job (Docker pull from ghcr.io). Call
`reusable-publish-security-audit-comment.yml` from the caller when PR comments
are required; that publish reusable declares `pull-requests: write`. The audit
reusable itself requires only `contents: read` and `packages: read`.

Outputs: `exit-code`, `has-vulns`, `audit-failed`, `status`.

## Vulnerability suppression check (osv-scanner)

`reusable-vuln-suppression-check.yml` centralizes the weekly stale/expired OSV
suppression cleanup pattern used by Rustume, py-lintro, and turbo-themes. The job
installs `osv-scanner` directly (no Docker), runs
`scripts/ci/security/check-vuln-suppressions.sh`, and may open a cleanup PR
removing stale entries (vulnerability resolved). Expired entries (past
`ignoreUntil`) are left untouched and flagged for manual review with a
non-zero exit.

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                    | Default                                              | Notes                                           |
| ------------------------ | ---------------------------------------------------- | ----------------------------------------------- |
| `osv-version`            | `2.3.5`                                              | osv-scanner release to install                  |
| `config-path`            | `.osv-scanner.toml`                                  | Suppression TOML relative to repo root          |
| `check-script`           | `.lgtm-ci-tooling/scripts/ci/security/check-vuln-suppressions.sh` | Repo-local override supported |
| `cleanup-pr-labels`      | `security,dependencies,automation`                   | Labels on auto-created cleanup PR               |
| `egress-preset`          | `osv-scanner`                                        | `github-tooling` + release assets + OSV APIs    |
| `allowed-endpoints-mode` | `append`                                             | Merge preset with caller-specific endpoints     |
| `workflow-file`          | empty                                                | Caller workflow filename for auto-PR footer     |
| `runner-image`           | `ubuntu-24.04`                                       | Linux runners only (`install-osv-scanner.sh`)   |

<!-- markdownlint-enable MD013 MD060 -->

Caller `on:` triggers are consumer-owned (`schedule`, `workflow_dispatch`).
Grant `contents: write` and `pull-requests: write` on the caller job. Forward
`secrets.GH_TOKEN` (typically `secrets.GITHUB_TOKEN`). Use a Linux
`runner-image`; the install script downloads `linux_*` release binaries only.

Required secrets: `GH_TOKEN`.

## GHCR cleanup

`reusable-ghcr-cleanup.yml` prunes aged untagged container versions and ephemeral
build-cache tags. Referenced-digest protection walks tagged manifest indexes and
OCI Referrers before untagged deletion; the job skips pruning when registry auth
or manifest collection is incomplete.

| Input | Default | Notes |
| --- | --- | --- |
| `package-name` | required | GHCR package name |
| `min-age-days` | `7` | Min age before deletion |
| `keep-latest` | `0` | Keep N most recent |
| `build-cache-pr-age-days` | `14` | Min cache age |
| `protect-referenced` | `true` | Skip when incomplete |
| `prune-buildcache` | `true` | Delete ephemeral tags |
| `dry-run` | `false` | Log only |
| `egress-policy` | `block` | `audit` or `block` |
| `egress-preset` | `github-tooling` | Preset host list |
| `allowed-endpoints` | `""` | Custom endpoints |
| `allowed-endpoints-mode` | `replace` | `replace` / `append` |
| `tooling-ref` | `""` | lgtm-ci git ref |
| `runner-image` | `ubuntu-24.04` | Runner image label |

Grant `contents: read` and `packages: write` on the caller job. Forward `secrets.token` with
`packages:write` scope (or `secrets: inherit`).

## Documentation site quality

`reusable-site-quality.yml` centralizes the docs-site pattern used by Rust
monorepos: Astro (or similar) build, lychee link check on built HTML, and
caller-provided check/test commands. Repo scripts such as `scripts/ci/site/build.sh`
remain consumer-owned and are passed as `build-command`, `check-command`, and
`test-command` inputs.

The reusable runs two parallel jobs (`site-build-link`, `site-test`). Lychee uses
`build-lychee-args.sh` plus `prepare-lychee-action-args.sh` to strip duplicate
`--format`/`--output` flags and add `--root-dir` for built dist output. Set
`lychee-root-dir` when the default (first `lychee-paths` value) is insufficient.

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                    | Default                         | Notes                                           |
| ------------------------ | ------------------------------- | ----------------------------------------------- |
| `build-command`          | required                        | e.g. `./scripts/ci/site/build.sh`               |
| `test-command`           | required                        | e.g. `./scripts/ci/site/test-all.sh`            |
| `check-command`          | empty                           | Optional type-check before tests                |
| `build-env`              | empty                           | Multiline `KEY=VALUE` (`apply-build-env.sh`)    |
| `site-working-directory` | `.`                             | Node/Bun install path (e.g. `apps/site`)        |
| `lychee-paths`           | `.`                             | Built dist path for link check                  |
| `lychee-root-dir`        | first `lychee-paths` entry      | `--root-dir` for built HTML link resolution     |
| `upload-site-artifact`   | `false`                         | Set `true` with explicit artifact path          |
| `python-version`         | empty                           | When set, enables optional Python setup         |
| `python-test-command`    | empty                           | Hook before `test-command` when Python enabled  |
| `vitest-json-path`       | empty                           | Optional non-default Vitest JSON for summaries  |
| `test-egress-preset`     | falls back to `egress-preset`   | Override egress for Python+Node test job        |

<!-- markdownlint-enable MD013 MD060 -->

Work jobs require only `contents: read`. Optional `publish-test-summary` delegates
to `reusable-publish-test-summary.yml` (requires `pull-requests: write` on the
caller publish job path). Outputs: `passed`, `build-passed`, `test-passed`.

## Merge queue (`merge_group`)

Callers using GitHub merge queue must add `merge_group:` triggers to every
caller workflow that produces a required check, alongside `pull_request:` —
otherwise queued PRs time out waiting for checks that never report. The
starter examples (`examples/ci-*.yml`) include `merge_group:` by default.

### App-level code-scanning checks

Never require the github-advanced-security app's code-scanning **summary** context
(`CodeQL` alone, without a caller-job prefix) in a ruleset when the repo uses a
merge queue. The app produces that check only on `pull_request` commits, never on
`merge_group` commits, so every queue entry times out and is silently ejected
([holy-grail#143](https://github.com/lgtm-hq/holy-grail/pull/143), twice during
v0.52.3 adoption). Require the workflow-job contexts instead — for example
`codeql / 🔬 CodeQL Analysis` (the `{caller_job_id} / {job-name}` path your caller
passes to `reusable-codeql.yml`). See [org-rulesets.md](org-rulesets.md)
(Check-name contract).

| Workflow                               | `merge_group` behavior                         |
| -------------------------------------- | ---------------------------------------------- |
| `reusable-quality-lint.yml`            | Safe to run — no PR context required           |
| `reusable-codeql.yml`                  | Safe to run — no PR context required           |
| `reusable-validate-action-pinning.yml` | Safe to run — no PR context required           |
| `reusable-dependency-review.yml`       | Runs on `merge_group` (same as PR)             |
| `reusable-security-audit.yml`          | Audit on `merge_group`; PR comment on PR only  |
| `reusable-site-quality.yml`            | Safe to run — no PR context required           |
| `reusable-docker.yml`                  | Safe to run — no PR context required           |
| `reusable-test-shell.yml`              | Tests run; PR summary comment on PR only       |
| `reusable-test-python.yml`             | Tests run; PR summary comment on PR only       |
| `reusable-test-node.yml`               | Tests run; PR summary comment on PR only       |
| `reusable-test-node-custom.yml`        | Tests run; PR summary comment on PR only       |
| `reusable-test-rust-build.yml`         | Safe to run — no PR context required           |
| `reusable-coverage.yml`                | Coverage runs; PR comment on PR only           |
| `reusable-semantic-pr-title.yml`       | No-op on `merge_group` — title validated on PR |

Test reusables gate their draft-PR skip on `github.event_name ==
'pull_request'`, so work jobs always run in the merge queue; PR summary
comments are gated on `pull_request` events in workflow conditions and in
`post-pr-comment.sh`, so they skip cleanly. Caller-side summary jobs (e.g.
the split `publish-quality-summary` pattern) already carry a
`github.event_name == 'pull_request'` guard and skip in the queue.

Semantic title validation is intentionally a no-op in the merge queue because
`amannn/action-semantic-pull-request` requires pull request context. The job
itself still runs (finishing in seconds with every step skipped): a job with a
dynamic `name:` that is skipped at job level reports its check under the raw
expression text (`semantic-title / inputs.job-name`), so the required context
would never arrive and queue entries would time out. Required checks produced
by reusables with configurable job names must therefore never carry job-level
event skips — skip at step level instead.

## Required-check-safe conditional workflows

`on.<event>.paths` filters must not be used on workflows that produce
**required checks**: when the paths don't match, the workflow never runs,
the check never reports, and the PR deadlocks (docs-only PRs block forever;
merge-queue entries time out). Paired no-op shim workflows are also
discouraged — duplicated job names and path filters drift apart silently.

Instead, drop the `paths:` filter, always run the workflow (including on
`merge_group`), and early-exit green via the `detect-changes` action:

1. A `changes` job runs `lgtm-hq/lgtm-ci/.github/actions/detect-changes`
   (checkout with `fetch-depth: 0` first) and exposes its `changes` output.
2. Downstream jobs keep their **static job name** (the required check's
   identity) and gate their steps on
   `fromJSON(needs.changes.outputs.changes).<filter>`, running a cheap
   "skipped" step (~seconds) when the filter didn't match.

`detect-changes` is a thin SHA-pinned wrapper around `dorny/paths-filter`
(v4.0.2+), which supports `merge_group` natively. The wrapper resolves the
diff base from `pull_request` (`event.pull_request.base.sha`), `merge_group`
(`event.merge_group.base_sha`), and `push` (`event.before`); when no base is
resolvable it **fails open** and reports every filter as changed, so a
required check runs its full job rather than silently early-exiting. Filters
are dorny YAML (see [detect-changes](actions/testing.md#detect-changes)).
Prior art for the caller pattern: homebrew-tap's
`validate-homebrew-formula.yml`.

Callers need `pull-requests: write` when `post-failure-comment` is enabled
(default). With `post-failure-comment: false`, `pull-requests: read` suffices.
Tooling is loaded from `lgtm-ci` via `prepare-semantic-pr-lists.sh` (supports
`tooling-ref` for unreleased fixes). The workflow passes newline-delimited
`types`/`scopes` to amannn (empty `types` uses the built-in default;
comma-separated overrides are normalized). On failure, `error_message` from
amannn (or the optional `max-length` check) is posted via `post-pr-comment`;
stale failure comments are cleared on success.

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
