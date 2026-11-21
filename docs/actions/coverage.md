# Coverage actions

Collecting, thresholding, badging, and publishing coverage. See
[reusable-coverage.yml](../workflows/testing.md#coverage) for the
workflow-level equivalent.

## collect-coverage

Aggregate coverage from multiple sources and formats.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/collect-coverage@<sha> # vX.Y.Z
  with:
    coverage-files: "coverage/*.json" # glob or comma-separated
    input-format: "auto" # 'auto', 'istanbul', 'coverage-py', 'lcov'
    output-format: "" # '' (same as input, default), 'json', 'lcov', 'cobertura'
    merge-strategy: "union" # 'union', 'intersection'
```

**Outputs:** `merged-coverage-file`, `coverage-percent`, `lines-coverage`,
`branches-coverage`, `functions-coverage`. Auto-detects format from file
content; merges coverage across Python and JavaScript projects.

Format integrity (#1078): a detected format is checked against the file's
content before merging, so a mislabeled file fails by name rather than
yielding an empty report. With `output-format` empty the merged file keeps
the input format (`merged-coverage.json`, `.lcov` or `.xml`); requesting a
format with no converter (such as LCOV to JSON) exits 2 with
`unsupported coverage conversion: <src> -> <dst>`. A single LCOV file passes
through untouched, so full LCOV with branch/function records does not need
the `lcov` binary; merging **two or more** full LCOV files still does (the
built-in fallback merges line records only and refuses `FN`/`BRDA` records
by name — install `lcov` in the producing job or upload one file per call;
coverage is single-runtime by design, #756). Line-only LCOV reports `branches-coverage` and
`functions-coverage` as `n/a`; a valid LCOV file with no lines found merges
to 0% with a `::warning::` annotation.

Unreadable reports (#1692): every input, and the merged report, is judged
whole by the same check as the coverage comment (`coverage_report_readable`
in `extract.sh`): a report is readable only when every metric it holds
(lines, branches, functions, statements) is. LCOV is checked record by record
(`LF`/`LH` in every record, each hit total with its found total, hits not
above found, no total twice, no total in the wrong case, data lines with
their totals, every record closed, no NUL byte); Cobertura is parsed as XML
and only the `<coverage>` document root's `line-rate`/`branch-rate` are read
(a `<!DOCTYPE coverage SYSTEM '…coverage-04.dtd'>` such as kcov writes is
allowed and never fetched; any other declaration, and any undeclared entity,
is refused); a JSON percentage must be a number from 0 to 100, and an Istanbul
`coverage-summary.json` holds all four metrics, as Istanbul writes it and as
the coverage comment has always required; in a per-file Istanbul report every
statement's line is a whole number and its hit count a whole number up to
2^53 - 1 (the largest count a JavaScript counter holds exactly). An empty
coverage map, which Istanbul and Vitest write as every metric with
`"pct": "Unknown"` and a total and covered count of 0, is not measured, as
before: the merge and the badge give `coverage-percent=Unknown`, the Node
test leg passes with no coverage recorded, a threshold above 0 fails, and the
comment shows the report as unreadable. `"Unknown"` beside a non-zero total
is unreadable. Each report is read as the format the caller declared
(`input-format` for the merge and convert steps, `format` for the comment),
not as its file name suggests. When a report
in the set is unreadable, even only in its branch or function totals, the
step fails with `::error::`, sets `coverage-percent` to `invalid` and gives no
percentage, so the threshold check and the badge never see one. The
`convert` step refuses an unreadable input and an unreadable result the same
way, reading the input as its declared `input-format` (a coverage.py `.coverage`
data file is read by the coverage CLI instead) and the result as the declared
`output-format`. The test runners' results.v1 documents use the same check
(see the workflow contract). The threshold check takes a coverage and a
threshold from 0 to 100 only. The built-in Istanbul and Cobertura to LCOV converters write the
`LF`/`LH` totals every record needs.

## check-coverage-threshold

Check if coverage meets a minimum threshold.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/check-coverage-threshold@<sha> # vX.Y.Z
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
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-coverage-badge@<sha> # vX.Y.Z
  with:
    coverage-file: "coverage.json" # or use coverage-percent
    format: "svg" # 'svg', 'json', 'shields'
    thresholds: "50,80" # red,yellow boundaries
```

**Outputs:** `badge-file`, `coverage-percent`, `badge-url`, `badge-color`.
Local SVG generation (no external dependencies); shields.io-compatible JSON
endpoint. A `coverage-file` whose line coverage is unreadable fails the
step, like a missing value, with `coverage-percent=invalid` and
`badge-color=lightgrey`; a `coverage-percent` that is not a number draws an
`unknown` light grey badge, never a percentage or a threshold colour (#1692).

## publish-test-results

Publish test results and coverage to GitHub Pages via official OIDC deploy
actions.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-test-results@<sha> # vX.Y.Z
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
