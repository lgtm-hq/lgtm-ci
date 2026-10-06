# Playwright report fixtures

Native Playwright reporter output for the parsers under
`scripts/ci/lib/testing/parse/` (#804). They are the inputs the normalized
results contract (#1080) consumes, so keep them as Playwright writes them:
sanitize paths, do not reshape.

Unless marked hand-made, every file was produced by `@playwright/test` 1.63.0
on a four-test project (`renders inline content` passed, `skipped on purpose`
skipped, `fails on purpose` failed twice with `retries: 1`, `flaky on purpose`
failed then passed) with `CI=1`. Absolute paths were rewritten to
`/work/consumer`, and ANSI colour sequences were stripped.

Counts below are passed / failed / skipped as `parse_playwright_json` reports
them (flaky counts as failed), followed by the raw `stats.duration` in ms.

- `json-mixed.json` — `--reporter=json,junit,html`; 1 / 2 / 1;
  `2374.6090000000004`.
- `json-passing.json` — `--reporter=json tests/smoke.spec.js`; 1 / 0 / 1;
  `531.5540000000001`.
- `json-empty.json` — `--reporter=json <pattern matching no file>` (exit 1,
  `suites: []`); 0 / 0 / 0; `7.275000000000006`.
- `json-malformed.json` — hand-made: the first 600 bytes of `json-mixed.json`,
  a report truncated mid-write; not parseable.
- `json-shard-1of2.json` — `--shard=1/2 --reporter=json,blob`
  (`config.shard` set); 0 / 2 / 0; `2372.614`.
- `json-shard-2of2.json` — `--shard=2/2 --reporter=json,blob`; 1 / 0 / 1;
  `567.2249999999999`.
- `json-merged.json` — `playwright merge-reports --reporter=json` over both
  shard blobs; 1 / 2 / 1 (the sum of the shards); `3316.22509765625`.
- `json-fractional-duration.json` — hand-made: the duration from the #804
  report; 1 / 0 / 0; `117018.533`.
- `json-half-millisecond.json` — hand-made: half-up rounding at both stages;
  1 / 0 / 0; `1499.5`.
- `junit-mixed.xml` — `--reporter=json,junit,html`, same run as `json-mixed`;
  `tests="4" failures="1" skipped="1" errors="0"`, `time` in seconds.
- `html-sidecar/playwright-results.json` — copy of `json-passing.json`, laid
  out next to the report directory as `--reporter=html,json` leaves it.
- `html-sidecar/playwright-report/index.html` — hand-made stand-in for the
  ~500 KB single-file report; never parsed, only its directory is asserted.

Note that Playwright's JUnit reporter counts the flaky test as passed
(`failures="1"`), while the JSON parser counts `flaky` as failed; the two
reporters disagree by design and the contract test in #1080 should expect that.

Durations are fractional milliseconds in every real report. `parse_playwright_json`
rounds them half-up to integer milliseconds (`TESTS_DURATION_MS`) before any
Bash arithmetic, then half-up to whole seconds (`TESTS_DURATION`); see the
rounding rule in `scripts/ci/lib/testing/parse/playwright.sh`.
