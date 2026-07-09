# PR comment actions

Marker-based PR comment transport and result-to-comment generators for
Lighthouse, Playwright, and coverage. Every generator here produces a
`comment-body` that a caller posts with `post-pr-comment`.

## post-pr-comment

Create or update PR summaries and reports with upsert behavior using unique
markers.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/post-pr-comment@main
  with:
    marker: "lighthouse-results" # unique identifier for this comment
    body: |
      ## Results
      Your content here...
    mode: "upsert" # 'upsert', 'create', or 'update'
```

**Outputs:** `comment-id`, `comment-url`, `action-taken` ("created",
"updated", "deleted", or "skipped"). Marker-based identification uses hidden
HTML comments; auto-detects PR number from context; optional
delete-on-empty behavior.

## run-lighthouse

Run Lighthouse CI audits with configurable score thresholds.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-lighthouse@main
  with:
    url: "http://localhost:3000"
    threshold-performance: "80"
    threshold-accessibility: "90"
    threshold-best-practices: "80"
    threshold-seo: "80"
```

**Outputs:** `performance`, `accessibility`, `best-practices`, `seo`,
`passed`, `failed-categories`, `results-path`. Automatic `@lhci/cli`
install; Chrome flags tuned for CI; filesystem upload (no external
services).

## generate-lighthouse-comment

Generate a formatted PR comment from Lighthouse CI results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-lighthouse-comment@main
  with:
    results-path: "lighthouse-results/"
    report-url: "https://example.github.io/lighthouse/"
    threshold-performance: "80"
```

**Outputs:** `comment-body`, `performance-score`, `accessibility-score`,
etc., `passed`.

## generate-playwright-comment

Generate a formatted PR comment from Playwright test results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-playwright-comment@main
  with:
    results-path: "playwright-report/results.json"
    report-url: "https://example.github.io/playwright/"
    show-failed-tests: "true"
```

**Outputs:** `comment-body`, `total-tests`, `passed-tests`, `failed-tests`,
`skipped-tests`, `success`.

## generate-coverage-comment

Generate a formatted PR comment from code coverage results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-coverage-comment@main
  with:
    coverage-file: "coverage/coverage-summary.json"
    format: "auto" # 'istanbul', 'coverage-py', 'lcov', or 'auto'
    threshold-lines: "80"
    threshold-branches: "70"
```

**Outputs:** `comment-body`, `lines-coverage`, `branches-coverage`,
`functions-coverage`, `passed`. Supports Istanbul (JS), coverage.py
(Python), and LCOV formats.
