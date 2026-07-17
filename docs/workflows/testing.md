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
`publish-results` (default false), `timeout-minutes` (default 30).

**Outputs:** `total-passed`, `total-failed`, `report-url`.

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
`generate-badge` (default true), `publish-pages` (default false).

**Outputs:** `coverage-percent`, `badge-url`, `pages-url`, `passed`. The
publish job requires `contents: read`, `pages: write`, `id-token: write`.

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
