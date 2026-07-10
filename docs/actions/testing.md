# Testing and quality actions

Test runners, quality checks, and change detection. For reusable
per-language test workflows, see [workflows/testing.md](../workflows/testing.md).

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
      - uses: lgtm-hq/lgtm-ci/.github/actions/run-quality@main
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
- uses: lgtm-hq/lgtm-ci/.github/actions/run-tests@main
  with:
    runner: "auto" # 'pytest', 'vitest', 'playwright', or 'auto'
    coverage: "true" # optional
    coverage-format: "json" # 'xml', 'json', 'lcov'
```

**Outputs:** `exit-code`, `runner`, `tests-passed`, `tests-failed`,
`tests-skipped`, `coverage-file`.

## run-pytest

Run Python tests with pytest and optional coverage.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@main
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
- uses: lgtm-hq/lgtm-ci/.github/actions/run-vitest@main
  with:
    node-version: "20" # optional
    coverage: "true" # optional
    coverage-format: "json" # 'json', 'lcov', 'html'
```

**Outputs:** `exit-code`, `tests-passed`, `tests-failed`, `tests-skipped`,
`tests-total`, `coverage-file`, `coverage-percent`. Uses bun for package
management; Istanbul-compatible coverage output.

## run-playwright

Run E2E tests using Playwright with browser automation.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-playwright@main
  with:
    node-version: "20" # optional
    browser: "chromium" # 'chromium', 'firefox', 'webkit', 'all'
    reporter: "html" # 'json', 'html', 'junit'
    shard: "1/3" # optional, for parallel execution
```

**Outputs:** `exit-code`, `tests-passed`, `tests-failed`, `tests-skipped`,
`tests-total`, `report-path`.

## merge-playwright-reports

Merge multiple Playwright reports from sharded or matrix test runs.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/merge-playwright-reports@main
  with:
    input-dir: "playwright-reports" # default
    output-dir: "merged-report" # default
    report-format: "html" # 'json' or 'html', default 'html'
```

**Outputs:** `merged-path`, `report-count`, `total-passed`, `total-failed`,
`total-skipped`.
