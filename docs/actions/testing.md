# Testing and quality actions

Test runners, quality checks, and change detection. For reusable
per-language test workflows, see [workflows/testing.md](../workflows/testing.md).

The runner action `run-pytest` sets up Python and uv with the same steps as
its `setup-python` sibling, inlined rather than nested, so it works from a
plain `uses: lgtm-hq/lgtm-ci/.github/actions/<name>@<sha>` with only your own
repository checked out — no lgtm-ci checkout or `tooling-ref` is needed
(#1075) — including on GitHub Enterprise Server and on self-hosted runners
older than 2.336.0 (#1469). See
[the workflow contract](../workflow-contract.md#composite-actions-calling-sibling-lgtm-ci-actions).
The Node runners `run-vitest`, `run-playwright`, and `run-lighthouse` pin
their toolchain actions directly and take a required `package-manager`
(`bun` / `npm` / `pnpm`) that is never inferred from lockfiles — see
[the Node package-manager contract](../workflow-contract.md#node-package-manager-contract-1077).

## detect-changes

Maps changed paths to named filters so conditional jobs **always run and
early-exit green** when their paths didn't change — the required-check-safe
replacement for `on.<event>.paths` filters, which deadlock required checks.

Thin SHA-pinned wrapper around
[`dorny/paths-filter`](https://github.com/dorny/paths-filter) (v4.0.2+), which
resolves `pull_request`, `merge_group`, and `push` diffs (including merge-queue
`base`/`ref` defaults). The wrapper keeps the org contract: public outputs stay
`changes` (JSON name→bool) + `any-changed`, and an empty or unresolvable base
**fails open** (all filters true, logged) so required checks run full jobs
instead of silently early-exiting. Checkout with `fetch-depth: 0` so dorny's git
mode has history.

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      # dorny/paths-filter reads the PR files API on pull_request events (#669)
      pull-requests: read
    outputs:
      changes: ${{ steps.detect.outputs.changes }}
    steps:
      - uses: actions/checkout@<sha> # vX.Y.Z
        with:
          fetch-depth: 0
      - uses: lgtm-hq/lgtm-ci/.github/actions/detect-changes@<sha> # vX.Y.Z
        id: detect
        with:
          filters: |
            examples:
              - 'examples/**'
              - 'packages/**'
            docs:
              - 'docs/**'
              - '*.md'
```

**Filters:** dorny-native YAML (inline or path to a filters file). Picomatch
globs — use `**` to cross directories. Legacy `name=glob …` line format from the
pre-dorny action is rejected; migrate to the YAML shape above (e.g.
`examples=examples/* packages/*` → `examples:` with `- 'examples/**'` /
`- 'packages/**'`).

**Outputs:** `changes` (JSON object of filter name → boolean), `any-changed`.
Keep the downstream job name static — it is the required check's identity.

## run-quality

Runs **lintro inside the full [`py-lintro`](https://github.com/lgtm-hq/py-lintro)
Docker image** (`docker pull` + `docker run` with the repo mounted at
`/code`), so every bundled CLI matches upstream docs — not `uv run lintro` on
the runner. Callers need `permissions: packages: read`.

```yaml
permissions:
  contents: read
  packages: read

jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@…
      - uses: lgtm-hq/lgtm-ci/.github/actions/run-quality@<sha> # vX.Y.Z
        with:
          lintro-image: ghcr.io/lgtm-hq/py-lintro@sha256:...
          tools: "" # optional, comma-separated (empty = all)
          mode: "check" # 'check' or 'format'
          fail-on-error: "true" # optional
```

**Outputs:** `exit-code`, `status` ("passed" or "failed").

## run-tests

Generic test runner that auto-detects and delegates to language-specific
runners.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-tests@<sha> # vX.Y.Z
  with:
    runner: "auto" # 'pytest', 'vitest', 'playwright', or 'auto'
    package-manager: npm # 'bun', 'npm', 'pnpm'; required when vitest/playwright run
    coverage: "true" # optional
    coverage-format: "json" # 'xml', 'json', 'lcov'
```

**Outputs:** `exit-code`, `runner`, `tests-passed`, `tests-failed`,
`tests-skipped`, `coverage-file`. Node callers must set `package-manager`
whenever the vitest or playwright runner is selected (or auto-detected) — the
runner fails with `package-manager is required for execution actions`
otherwise; pytest ignores it. This action installs no toolchain or
dependencies itself.

## run-pytest

Run Python tests with pytest and optional coverage.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@<sha> # vX.Y.Z
  with:
    python-version: "3.12" # optional
    test-path: "tests" # optional
    coverage: "true" # optional
    coverage-format: "json" # 'xml', 'json', 'lcov'
    markers: "not slow" # optional
```

**Outputs:** `exit-code`, `tests-passed`, `tests-failed`, `tests-skipped`,
`tests-total`, `coverage-file`, `coverage-percent`.

## run-vitest

Run JavaScript/TypeScript tests with vitest and optional coverage.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-vitest@<sha> # vX.Y.Z
  with:
    package-manager: npm # required: 'bun', 'npm', 'pnpm'
    node-version: "22" # optional
    coverage: "true" # optional
    coverage-format: "json" # 'json', 'lcov', 'html'
```

**Outputs:** `exit-code`, `tests-passed`, `tests-failed`, `tests-skipped`,
`tests-total`, `coverage-file`, `coverage-percent`. Runs a frozen-lockfile
install with the selected manager (`install-dependencies: "false"` to skip)
and executes `vitest` through it; `vitest` and, with coverage,
`@vitest/coverage-v8` (or `-istanbul`) must already be devDependencies —
nothing is installed into the project (#1077). `bun-version` is an exact,
Renovate-managed pin used only when `package-manager: bun`.

## run-playwright

Run E2E tests using Playwright with browser automation.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-playwright@<sha> # vX.Y.Z
  with:
    package-manager: pnpm # required: 'bun', 'npm', 'pnpm'
    node-version: "22" # optional
    browser: "chromium" # 'chromium', 'firefox', 'webkit', 'all'
    reporter: "html" # 'json', 'html', 'junit'
    shard: "1/3" # optional, for parallel execution
```

**Outputs:** `exit-code`, `tests-passed`, `tests-failed`, `tests-skipped`,
`tests-total`, `report-path`. `@playwright/test` must be a devDependency;
browsers are installed through the selected manager, the package never is
(#1077). On Linux the system packages that `playwright install-deps --dry-run`
reports are installed through the shared apt helper
(`scripts/ci/lib/apt_helper.py`, #1432; each `apt-get` attempt is stopped after
`LGTM_CI_APT_CALL_TIMEOUT_SECONDS`, default 100, and retried, and each helper
run ends within `LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS`, default 300, #1571), then
`playwright install` runs without
`--with-deps`; an unrecognised dry run falls back to `install --with-deps` with
a warning. macOS and Windows keep `playwright install --with-deps`.

## merge-playwright-reports

Merge multiple Playwright reports from sharded or matrix test runs.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/merge-playwright-reports@<sha> # vX.Y.Z
  with:
    input-dir: "playwright-reports" # default
    output-dir: "merged-report" # default
    report-format: "html" # 'json' or 'html', default 'html'
    expected-matrix: "" # matrix JSON {suite, browser, shard}; default '' (unchecked)
    artifact-prefix: "playwright" # default
    test-result: ${{ needs.test.result }} # default 'success'
```

Download the shard artifacts with `merge-multiple: false`, so each lands in its
own subdirectory of `input-dir`: every shard writes the same
`playwright-results.json`, and a flattened download keeps only the last one.

With `expected-matrix`, the merge fails with an `::error::` unless every
`<artifact-prefix>-<suite>-<browser>-<shard>` directory holds exactly one
results file, that file is a Playwright JSON report (a `suites` array, and
`stats.expected`, `unexpected`, `skipped` and `flaky` as non-negative integers
whose sum equals the tests in `suites`; an empty, truncated or inconsistent
file fails, a consistent zero-test report passes), and no results file sits
elsewhere (`playwright-report/` directories and a previous
`merged-results.json` are ignored). The check runs before the
merge path is chosen, and the merge is then the JSON merge of exactly those
reports: blob zips are ignored with a `::warning::`. Without `expected-matrix`
the check is skipped with a `::warning::`, so existing callers keep working.

Pass the shard job's result as `test-result` when the merge runs under
`if: always()`. When it is not `success`, a leg that died before Playwright
wrote results already explains its missing report: a shard with no results
file is a `::warning::`, and the merge still fails, printing that it is
incomplete because the test job ended `<result>`, but adds no `::error::` of
its own for it. A malformed, inconsistent, duplicate or surplus report, an
invalid `expected-matrix` and a totals mismatch stay `::error::` either way.

**Outputs:** `merged-path`, `report-count`, `total-passed`, `total-failed`,
`total-skipped`, `shard-counts` (JSON array of per-report `passed`, `failed`
and `skipped`; empty after a blob merge).
