# Coverage actions

Collecting, thresholding, badging, and publishing coverage. See
[reusable-coverage.yml](../workflows/testing.md#coverage) for the
workflow-level equivalent.

## collect-coverage

Aggregate coverage from multiple sources and formats.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/collect-coverage@main
  with:
    coverage-files: "coverage/*.json" # glob or comma-separated
    input-format: "auto" # 'auto', 'istanbul', 'coverage-py', 'lcov'
    output-format: "json" # 'json', 'lcov'
    merge-strategy: "union" # 'union', 'intersection'
```

**Outputs:** `merged-coverage-file`, `coverage-percent`, `lines-coverage`,
`branches-coverage`, `functions-coverage`. Auto-detects format from file
content; merges coverage across Python and JavaScript projects.

## check-coverage-threshold

Check if coverage meets a minimum threshold.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/check-coverage-threshold@main
  with:
    coverage-percent: "85.5"
    threshold: "80"
    fail-on-error: "true" # optional, default: true
```

**Outputs:** `passed`, `message`. Portable decimal comparison via awk; clear
GitHub annotation on failure.

## generate-coverage-badge

Generate a coverage badge SVG/JSON for README display.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-coverage-badge@main
  with:
    coverage-file: "coverage.json" # or use coverage-percent
    format: "svg" # 'svg', 'json', 'shields'
    thresholds: "50,80" # red,yellow boundaries
```

**Outputs:** `badge-file`, `coverage-percent`, `badge-url`, `badge-color`.
Local SVG generation (no external dependencies); shields.io-compatible JSON
endpoint.

## publish-test-results

Publish test results and coverage to GitHub Pages via official OIDC deploy
actions.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-test-results@main
  with:
    results-path: "test-results/" # optional
    coverage-path: "coverage/" # optional
    badge-path: "coverage/badge.svg" # optional
    merge-existing-site: "false" # optional Model A multi-publisher merge
```

**Outputs:** `pages-url`. Optional `merge-existing-site` preserves sibling
subtrees when multiple Model A publishers deploy to the same Pages site —
see [pages-publishing.md](../pages-publishing.md). Requires
`contents: read`, `pages: write`, `id-token: write` on the caller job.
