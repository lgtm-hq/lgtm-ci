# Testing workflows

Per-language test reusables plus coverage collection and summary
publishing. Full inputs/outputs/examples: [reusable-workflows.md](../reusable-workflows.md#tests).
Contract details (compat vs coverage mode, job display names, Pages
coverage HTML inputs): [workflow-contract.md](../workflow-contract.md).

## Python, Node, shell, E2E

`reusable-test-python.yml`, `reusable-test-node.yml` (Vitest),
`reusable-test-node-custom.yml` (caller-provided command),
`reusable-test-shell.yml` (BATS), `reusable-test-e2e.yml`,
`reusable-test-e2e-playwright.yml`, and `reusable-test-e2e-matrix.yml` share a
standard shape: they check out lgtm-ci tooling, run the language runner,
optionally collect coverage, and post/update a PR summary comment via
`reusable-publish-test-summary.yml` when `pull-requests: write` is granted.

With `coverage: false` (the default), the PR summary is totals-only — no
Coverage / Code Coverage sections and no “Unable to retrieve coverage…”
warning. With `coverage: true`, rich or totals-with-percent comments stay as
today; a missing report still warns. See workflow-contract.md
[Comment body selection](../workflow-contract.md#comment-body-selection).

### reusable-test-python.yml

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@main
    with:
      python-version: "3.12"
      test-path: "tests"
      coverage: true
      coverage-threshold: 80
      upload-coverage: true
```

**Inputs:** `python-version` (default '3.12'), `test-path` (default
'tests'), `coverage` (default false), `coverage-format` (xml/json/lcov,
default 'json'), `coverage-threshold` (default 0), `upload-coverage`
(default false).

**Outputs:** `tests-passed`, `tests-failed`, `tests-total`,
`coverage-percent`, `passed`.

### reusable-test-node.yml

Vitest testing with optional coverage and PR summaries. Custom package
scripts (for example `bun run test:coverage`) use
`reusable-test-node-custom.yml` instead.

**Inputs:** `job-name` (check name, default `Node.js Tests`),
`node-version` (default '20'), `test-path` (default '.'), `coverage`
(default false), `coverage-format` (json/lcov/html, default 'json'),
`coverage-threshold` (default 0), `upload-coverage` (default false), plus
the Pages coverage HTML inputs (see
[reusable-workflows.md](../reusable-workflows.md#pages-coverage-html-inputs-reusable-test-node)).

**Outputs:** `tests-passed`, `tests-failed`, `tests-total`,
`coverage-percent`, `passed`.

### reusable-test-node-custom.yml

Node testing via a caller-provided shell command (after dependency
install). Use when Vitest is not the runner or a package script owns
coverage.

**Inputs:** `test-command` (**required**, runs in `working-directory`),
`job-name` (default `Node.js Tests`), `node-version`, `node-versions`,
`package-manager`, `pre-test-command`, and the same Pages coverage HTML
inputs as the Vitest workflow.

**Outputs:** `passed`, `pages-coverage-artifact-name`,
`pages-coverage-uploaded`.

### reusable-test-e2e.yml

```yaml
jobs:
  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e.yml@main
    with:
      browsers: "chromium"
      shard: "1/3" # optional, for parallel execution
      reporter: "html"
      upload-report: true
```

**Inputs:** `node-version` (default '20'), `project` (Playwright project),
`browsers` (chromium/firefox/webkit/all, default 'chromium'), `shard` (for
example "1/3"), `reporter` (json/html/junit, default 'html'),
`upload-report` (default true).

**Outputs:** `tests-passed`, `tests-failed`, `passed`.

### reusable-test-e2e-playwright.yml

Preferred Playwright E2E reusable for thin smoke / a11y / full callers with
distinct required `job-name` values. Caches `~/.cache/ms-playwright` by
resolved Playwright version; uploads HTML/blob reports on failure only.

```yaml
jobs:
  e2e-smoke:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-playwright.yml@main
    with:
      job-name: "🔥 Smoke E2E"
      grep: "@smoke"
      browsers: "chromium"
```

**Inputs:** `job-name` (**required**), `test-command` (default
`npx playwright test`), `project`, `grep`, `node-version`, `browsers`
(default `chromium`), `upload-report` (default true, failure-only),
`base-url`, `web-server`, plus standard egress / tooling inputs.

**Outputs:** `tests-passed`, `tests-failed`, `tests-total`, `passed`.

### reusable-test-e2e-matrix.yml

Matrix E2E with parallel legs per suite/browser/shard, tag-based filtering
(`@smoke`, `@visual`, `@a11y`), browser caching, and automatic report
merging.

**Inputs:** `node-version` (default '20'), `test-suites` (comma-separated,
default 'smoke'), `browsers` (comma-separated, default 'chromium'),
`tag-prefix` (default '@'), `shards` (per suite, default 1), `reporter`
(json/html/blob, default 'html'), `upload-report` (default true),
`timeout-minutes` (default 30), `artifact-prefix` (default 'playwright').

`publish-results`, `pages-target-dir`, `publish-egress-preset` and
`publish-allowed-endpoints` are **deprecated and inert** since #770 — see
below.

Shards upload as `<artifact-prefix>-<suite>-<browser>-<shard>` and the merge
job collects them with `<artifact-prefix>-*`, so a caller running this workflow
twice in one run must give the second call its own `artifact-prefix` — otherwise
each merge picks up the other call's shards. The prefix must match
`[A-Za-z0-9_.]+`: `-` is reserved as the separator, and allowing it inside the
prefix would let `e2e-*` match an `e2e-nightly` call's shards.

#### Publishing moved out (#770)

This workflow no longer deploys to Pages. Its `publish` job declared
`pages: write`, `id-token: write` and `actions: write`, and because a reusable
workflow's permission request is validated **statically**, every caller had to
grant all three — including callers running with `publish-results: false`. The
job moved to `reusable-publish-test-results-pages.yml`, which the caller invokes
in its own job:

```yaml
publish-e2e:
  needs: e2e-matrix
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-test-results-pages.yml@<sha>
  permissions:
    contents: read
    pages: write
    id-token: write
    actions: write
  with:
    artifact-name: playwright-merged-report # '<artifact-prefix>-merged-report'
    pages-target-dir: playwright # the value this call used to pass
    results-path: "."
```

`publish-results`, `pages-target-dir`, `publish-egress-preset` and
`publish-allowed-endpoints` are still accepted so pinned callers keep parsing —
an unknown input to a reusable workflow is a hard `startup_failure` — but they
do nothing and warn when set to a non-default value. `report-url` is always
empty; read `pages-url` off the publisher job instead.

`pages-target-dir` kept its name and its validator: it is the separate,
Pages-side half of the artifact isolation (#754). The publisher deploys to
`<pages-site>/<pages-target-dir>/`, so two publishing calls in one run overwrite
each other unless each is given its own value. It is **not** derived from
`artifact-prefix`: this value is URL-visible, has no glob-disjointness
requirement (so `-` is allowed), and deriving it would silently move the
published URL of any caller that sets `artifact-prefix` for artifact reasons
alone.

Neither workflow can detect the collision for you — a reusable workflow cannot
see its sibling calls, so the publisher only validates the value in isolation:
it must be a relative path matching `[A-Za-z0-9._/-]+` with no leading `/` and
no `..` segment, because it is interpolated into a deploy destination. Keeping
two publishing calls apart is the caller's contract.

Distinct `pages-target-dir` values are necessary but not sufficient for two
publishing calls on one site: every deploy uploads a **full site artifact** that
replaces the whole published site, and both jobs share the
`pages-<repo>-<ref>` concurrency group. Callers publishing more than one report
tree should use Model B (`reusable-deploy-site-with-reports`) or
`merge-existing-site` — see [pages-publishing.md](../pages-publishing.md).

**Outputs:** `total-passed`, `total-failed`, `report-url` (deprecated, always
empty).

### Isolated Pages publish variants

`reusable-test-node.yml` does not include a Pages publish job — use
`reusable-test-node-publish.yml` in a separate caller job when you need
coverage-badge / Pages publishing (same for Python:
`reusable-test-python-publish.yml`). Both publish variants run in a
**fresh workspace**; checkout order must be repo → lgtm-ci tooling → egress
→ harden, or `actions/checkout` wipes `.lgtm-ci-tooling/`. See
[pages-publishing.md](../pages-publishing.md) (Isolated publish jobs).

Multi-runtime matrices (`node-versions`, `python-versions`,
`rust-toolchains`) are **compat mode only**: `coverage: false` and
`publish-test-summary: false`. See workflow-contract.md
[Compat vs coverage contract](../workflow-contract.md#compat-vs-coverage-contract-340).

## Rust

`reusable-rust-build.yml` for compile checks, `reusable-rust-test.yml` for
tests (`coverage: false` for fast nextest-only, `coverage: true` for a
single instrumented `llvm-cov nextest` run). `reusable-test-rust-build.yml`
is a low-noise build-only alternative safe to run without PR context. See
[rust-testing.md](../rust-testing.md) and
[reusable-workflows.md](../reusable-workflows.md#rust).

## Coverage

`reusable-coverage.yml` unifies coverage collection (auto-detects format),
threshold checking, badge generation, and optional Pages publish in one
workflow — the workflow-level equivalent of chaining `collect-coverage` +
`check-coverage-threshold` + `generate-coverage-badge`
(see [actions/coverage.md](../actions/coverage.md)).

**Inputs:** `coverage-files` (glob or list, default auto-detect), `format`
(auto/istanbul/coverage-py/lcov, default 'auto'), `threshold` (default 0),
`generate-badge` (default true).

`publish-pages` is **deprecated and inert** since #770: the Pages publish job
moved to `reusable-publish-test-results-pages.yml` so that callers which never
publish stop granting `pages`, `id-token` and `actions: write`. Call that
workflow with `artifact-name` set to this call's `coverage-artifact-name`,
`pages-target-dir: coverage`, `coverage-path` set to the `working-directory`
(`.` for the repo root) and `badge-path` set to `<working-directory>/coverage`.

**Outputs:** `coverage-percent`, `badge-url`, `passed`, plus `pages-url`
(deprecated, always empty). The workflow itself requires only
`contents: read` and `pull-requests: write`.

## Quality and gating

`reusable-quality-lint.yml` runs lintro in the pinned py-lintro Docker
image; pair with `reusable-publish-quality-summary.yml` for a PR comment.
`reusable-validate.yml` runs a caller-provided validation script.
`reusable-validate-lintro-version.yml` resolves or validates the pinned
py-lintro digest used by the quality/testing reusables.

### reusable-required-check.yml

Org ruleset gate: asserts an upstream reusable job succeeded (and optional
outputs) under a caller-controlled `job-name`, replacing consumer-local
shim `runs-on` jobs. The gate reports its check as
`{caller_job_id} / {job-name}` and org rulesets must require that exact
prefixed context — see [org-rulesets.md](../org-rulesets.md) for the
registry and [workflow-contract.md](../workflow-contract.md#org-ruleset-check-names).

```yaml
lintro-code-quality:
  needs: dogfooding-lint
  if: always()
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-required-check.yml@main
  permissions:
    contents: read
  with:
    job-name: "🛠️ Lintro Code Quality"
    upstream-result: ${{ needs.dogfooding-lint.result }}
    status-output: ${{ needs.dogfooding-lint.outputs.status }}
```

**Inputs:** `job-name` (**required**), `upstream-result` (**required**,
`needs.*.result`), `passed-output` (when set, must be the string `true`),
`status-output` / `status-expected` (optional status gate, default
expected `passed`), `draft-pr-skip` (default false), plus `tooling-ref`,
`egress-policy`, `allowed-endpoints`, `runner-image`, `timeout-minutes`.

**Outputs:** `exit-code` (`0`/`1`), `status` (`passed`/`failed`).
