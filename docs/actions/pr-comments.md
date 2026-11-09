# PR comment actions

Marker-based PR comment transport and result-to-comment generators for
Lighthouse, Playwright, and coverage. Every generator here produces a
`comment-body` that a caller posts with `post-pr-comment`.

## post-pr-comment

Create or update PR summaries and reports with upsert behavior using unique
markers.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/post-pr-comment@<sha> # vX.Y.Z
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

### Run history (`history`, #1346)

By default every run overwrites the marker comment, so it shows the latest
push only. With `history: "true"` the latest result stays on top and earlier
results fold into one collapsible **🕘 Previous runs** archive below it.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/post-pr-comment@<sha> # vX.Y.Z
  with:
    marker: "python-test-results"
    file: test-summary.md
    history: "true"
    history-limit: "3"
    history-summary: "42 passed, 1 failed · 91.2% cov"
```

<!-- markdownlint-disable MD013 -- input reference table -->

| Input             | Default   | Purpose                                                                                  |
| ----------------- | --------- | ---------------------------------------------------------------------------------------- |
| `history`         | `"false"` | `"true"` keeps earlier runs in the archive; `"false"` overwrites as before               |
| `history-limit`   | `"3"`     | Earlier runs kept; `0` = unlimited within the size budget                                |
| `history-summary` | `""`      | One-line text on this run's archived entry; without it the entry shows run metadata only |

<!-- markdownlint-enable MD013 -->

How it works:

- **Stamp.** Every body posted with history on starts (after the marker) with
  `<!-- lgtm-ci:history:latest sha=… run=… attempt=… number=… at=… -->`: the
  PR head commit, the workflow run id, attempt and number, and the UTC time.
  When `history-summary` is set the stamp also carries it (base64) for the
  entry this result becomes later.
- **Archive.** On the next run the previous latest section becomes an entry shaped
  like this:

  <!-- prettier-ignore -->
  `<details><summary>Run #<number> · <short sha> · <at> · workflow run[ ·
  <history-summary>]</summary>…</details>`

  The entry sits between the
  `lgtm-ci:history:start` / `lgtm-ci:history:end` sentinels, each entry opened
  by an `lgtm-ci:history:entry` line that repeats the stamp's fields. Only
  those sentinels are parsed; `<details>` blocks inside a body, such as a
  coverage file table, are left alone.

- **Ordering.** Entries are ordered by run id, newest first. A re-run (same
  run id, higher attempt) replaces that run's entry. If a run finishes after a
  newer run has already posted, its result is archived under the newer one
  instead of replacing it.
- **Comments posted before history.** A marker comment without a stamp is
  archived once, as `earlier run (unstamped)`, sorted last.
- **Size.** The archive is trimmed to `history-limit` silently, then the
  whole body is held to 60,000 bytes (headroom under GitHub's 65,536): entries
  are kept newest first until one does not fit, that entry and every older one
  are dropped, and `> ✂️ <k> older runs not listed (size limit)` counts them,
  so the archive is always the newest runs without gaps. The latest result
  is never cut; a body that is too large on its own fails the update with
  HTTP 422, as without history.
- **Untrusted text.** The four `lgtm-ci:history:*` sentinels are neutralised
  (`< !--`) where they appear in a body, so test names or failure output
  cannot forge archive structure. Other `<!-- lgtm-ci:… -->` markers are kept.
- **Listing.** History reads every page of PR comments (`per_page=100`) and
  fails the step when the listing fails, instead of creating a second comment.
  When several comments carry the marker, the newest one with a stamp or
  archive is kept (else the newest). The others are deleted only after the
  kept comment has been updated, so a failed update deletes nothing; a 403 or
  404 on that delete is a warning. Archive entries that only a deleted
  duplicate carried are not merged into the kept comment.
- **Concurrency.** Editing an issue comment has no conditional write. Two
  runs that both read the comment before either writes it race, and the last
  writer wins: the other run's result is missing from the archive.

`delete-on-empty` still deletes the whole comment, archive included, and
`mode: update` without an existing comment still skips. Turning history off
again overwrites the comment, archive and all, on the next run.

## run-lighthouse

Run Lighthouse CI audits with configurable score thresholds.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-lighthouse@<sha> # vX.Y.Z
  with:
    package-manager: npm # required: 'bun', 'npm', 'pnpm'
    url: "http://localhost:3000"
    threshold-performance: "80"
    threshold-accessibility: "90"
    threshold-best-practices: "80"
    threshold-seo: "80"
```

**Outputs:** `performance`, `accessibility`, `best-practices`, `seo`,
`passed`, `failed-categories`, `results-path`. `@lhci/cli` is a
prerequisite — a devDependency of the project in `working-directory`
(default `.`) resolved through the selected manager, or an `lhci` already on
`PATH`; nothing is installed (#1077). `output-dir` and `config-path` are
relative to `working-directory`. Chrome flags tuned for CI; filesystem
upload (no external services). Scores come from the representative run named
in LHCI's `manifest.json` (falling back to the newest `*.report.json`); with
several URLs only the first URL is scored, with a warning. When the audit
wrote no report the action fails with `No Lighthouse report` and the job
summary says so, instead of reporting zero scores (#1088).

## generate-lighthouse-comment

Generate a formatted PR comment from Lighthouse CI results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-lighthouse-comment@<sha> # vX.Y.Z
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
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-playwright-comment@<sha> # vX.Y.Z
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
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-coverage-comment@<sha> # vX.Y.Z
  with:
    coverage-file: "coverage/coverage-summary.json"
    format: "auto" # 'istanbul', 'coverage-py', 'lcov', or 'auto'
    threshold-lines: "80"
    threshold-branches: "70"
```

**Outputs:** `comment-body`, `lines-coverage`, `branches-coverage`,
`functions-coverage`, `passed`. Supports Istanbul (JS), coverage.py
(Python), and LCOV formats.
