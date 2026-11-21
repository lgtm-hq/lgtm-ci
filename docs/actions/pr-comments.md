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

### Which comment is updated (#1674)

The first line of every comment the action writes is the marker line
`<!-- lgtm-ci:<marker> -->`. A later run updates, deletes or de-duplicates a
comment only when both hold:

- **Leading marker.** The comment's first line is exactly the marker line. A
  marker anywhere else, or with other text on the same line, does not match.
- **Same account.** "Own" means posted by the same account, nothing finer.
  The action asks GitHub GraphQL for `viewer { login databaseId }`, which
  needs no extra permission: `github-actions[bot]` for `GITHUB_TOKEN`,
  `<app-slug>[bot]` for a GitHub App installation token, the user for a
  personal token. A comment matches only when both its REST `user.login` and
  `user.id` equal those values, so another bot's or a user's comment never
  matches even when it carries the marker.

**The account is shared.** Every workflow in a repository that posts with the
default token posts as the same `github-actions[bot]` account (id 41898282).
To this action, a comment another workflow in the same repository posted with
that token is "own". If that comment's first line is this action's marker line,
the action can select, overwrite or delete it. Same-account workflows are not
isolated from each other:

- Give every publisher in the repository its own `marker`. Two jobs or
  matrix legs that share a marker share one comment.
- Never let another workflow post a comment whose first line comes from
  untrusted text (a PR title, a branch name, a test name, a pasted report).
  This action neutralises the namespace only in bodies it posts itself.

If the account cannot be determined, the action fails closed: it touches no
existing comment and logs a warning with the reason (the HTTP status or GraphQL
error, on one line). In `upsert` mode it posts a new comment. `update` mode
and `delete-on-empty` skip. `create` mode with a body reads neither the account
nor the comments.

Every mode reads every page of comments (`per_page=100`). If the listing fails,
the step fails and posts nothing. Without `history`, earlier releases read
only the first page and posted a new comment when the listing failed.

**Reserved namespace.** `<!-- lgtm-ci:` belongs to the marker line and the
history stamps the action writes. Anywhere else in a body it is rewritten to
`< !-- lgtm-ci:`, which shows as text and can never match. That covers test
names, file paths, pasted reports, and anything else that reaches the body.
Line endings are normalised first: CRLF and a lone carriage return both become
LF, which is how GitHub renders them, so a CR can neither hide the prefix
(`<!-\r- lgtm-ci:`) nor join two lines. A body
whose first line is already this comment's own marker line has that line
dropped, so the marker is not written twice. A body that is only that marker
line is therefore empty: with `delete-on-empty: "true"` it deletes the comment,
otherwise the step skips. A body without `<!-- lgtm-ci:` or carriage returns is
posted byte for byte as before.

**Upgrading.** Comments written by the lgtm-ci publishers already start with
their marker line and are written with `github.token`, so they keep updating
in place. A comment that an older release wrote under another account, or one
that does not start with the marker line, is no longer updated or deleted.
The next run posts a new comment beside it, which you can delete by hand.

**Body file (#1716).** With `file`, a load step reads the file and writes
a snapshot of it to `RUNNER_TEMP`: a new file with an unpredictable name,
readable only by the runner user. The post step, which holds the token,
reads only that snapshot and never opens the caller's path, so a file
changed or swapped after the load step does not change what is posted, and
the body never passes through a step output or an environment variable
(which Linux caps at 128 KiB).

- **Token.** The load step's own environment holds no token, and the
  process that reads the caller's file runs with `GH_TOKEN` and
  `GITHUB_TOKEN` removed besides. A composite action still inherits the
  rest of its caller's job-level environment: keep secrets out of the job's
  `env`.
- **What the post step checks.** Before it reads the snapshot it checks the
  path: absolute, with no `.` or `..` component, in a directory that is
  physically `RUNNER_TEMP`, named as the load step names snapshots, a
  regular file, not a symlink, owned by the runner user. These checks
  establish location, name, type and owner; they do not authenticate who
  wrote the file. The guarantee rests on the unpredictable name and on the
  load step's output, which no other step can write, inside a job that runs
  no pull request code. A snapshot that passes the checks is removed when
  the post step ends, however it ends; one that fails them is left alone.
  When `file` is set but the load step reported no state, nothing is posted
  or deleted.
- **Path rule.** As before, a regular file, with symlinks followed: a
  symlink to a file in the workspace or in `RUNNER_TEMP` works, and a file
  name may hold any byte (a trailing newline included). A missing path, a
  directory, a FIFO or a device logs `Comment file not found` and counts as
  an empty body, as before. A path that resolves under `/proc`, `/sys` or
  `/dev` (so `/dev/stdin` and `/dev/fd/N`, which main read) fails the step
  as an unreadable file, as does a path that cannot be resolved: it never
  counts as empty, so `delete-on-empty` cannot fire. Without `realpath`
  (macOS before 13) the path is resolved the same way with `cd -P` and
  `readlink`. On a Windows runner `RUNNER_TEMP` is turned into a POSIX path
  with `cygpath` (not tested on a Windows runner).
- **Same body as before.** NUL bytes are dropped and one trailing newline is
  stripped, then line endings are normalised, exactly as before; the size
  is decided only after that. With history, composition also drops any
  amount of trailing whitespace, as before.
- **Bounded.** The file is read once, as bytes, into a private copy in
  `RUNNER_TEMP`: at most 64 MiB and one byte (256 times the limit, so a
  report padded with NUL bytes still posts as before). `wc -c` counts it;
  a copy of more than 64 MiB, that is 64 MiB and one byte, gives the
  notice, and exactly 64 MiB is read and measured. Its NUL-free bytes go to
  the snapshot file and the copy is removed, so `RUNNER_TEMP` holds at most
  twice 64 MiB and one byte for a moment. A NUL-free body of more than
  524,291 bytes is over the limit whatever line endings do (they can at most
  halve it), unless everything past those bytes is trailing whitespace,
  which history drops: then the snapshot is cut to 524,292 bytes, history
  posts what it always posted, and without history the body is still over
  the limit and gets the notice. Otherwise such a file gets the notice and
  its snapshot is removed after the bounded read. A read that does not
  finish cleanly fails the step; its bytes are never posted. One exception
  to "as before": a file over 64 MiB that is almost entirely NUL bytes
  posted its few other bytes on main and gets the notice now.
- **The `body` input** still reaches the post step through an environment
  variable: a value over 128 KiB fails the step before the script runs,
  with nothing posted. Write such a body to a file and pass `file`.
- **Earlier releases.** The script's `read-file` step, which delivered the
  file through a step output under a random delimiter (#1675), stays for
  direct callers of earlier releases; its reader also runs without the
  token. The action and the reusable workflows use the load step.

### Size limit (#1705)

GitHub rejects a comment body over **262,144 bytes** of UTF-8. Its error
message says "maximum is 65536 characters", but posting shows the limit is
in bytes: 65,537 or 262,144 ASCII characters are accepted and 262,145 are
not; 131,072 two-byte characters (262,144 bytes) are accepted and one more is
not; 65,536 four-byte characters are accepted and one more is not; CRLF line
ends do not change the stored length. Before this check an oversized body
failed the post and left the previous push's comment up, still showing that
push's result.

The action measures the final body (marker line, history stamp and archive
included) just before it posts:

- **Measure.** Bytes of the decoded body GitHub stores. A body up to 65,536
  bytes goes to the GitHub CLI as a form field, exactly as before; the CLI
  replaces each invalid UTF-8 byte with U+FFFD (3 bytes), so even an invalid
  body of that size decodes to at most 196,608 bytes. A larger body is
  encoded as JSON by `jq` and measured as encoded: `jq` replaces invalid
  UTF-8 too, and what is measured is exactly the body GitHub stores. A body
  whose size cannot be measured counts as over the limit.
- **Within the limit.** The body is posted exactly as before.
- **History first.** With `history: "true"` archive entries are dropped,
  oldest first, until the whole body fits as it will be sent (see
  [Run history](#run-history-history-1346)), then the archive with its size
  note; only a result too large on its own, with no archive and no note, is
  replaced. The composer caps the archive budget at the limit; it can still
  hand back a latest result that is itself over the limit, and the poster,
  which measures what it sends, enforces the final limit.
- **Over the limit.** A short notice is posted in the body's place, then the
  step fails with one `::error` that says the summary was too long and that
  the notice was posted, so an oversized report still turns the job red.
  That error is the one annotation about the size; other warnings the step
  logs on the way (an account it cannot determine, a duplicate it cannot
  delete) are logged as well, and the `comment-fields` messages of a
  replaced body are not. The
  notice keeps the marker line, so it overwrites the stale comment and the
  next run updates the same one. With history it also keeps the stamp
  (without `history-summary` or `comment-fields`, which describe the body
  that is not shown) and the archive of earlier runs, below it. It reads
  (lines wrapped here):

  ```markdown
  ### ⚠️ Summary too long to post

  > [!WARNING]
  > GitHub accepts at most 262,144 bytes in one comment.
  > The comment for this run (commit `abc1234`) would be 300,029 bytes,
  > so the summary is not shown.
  > **No result is shown for this run**, and no earlier result applies
  > to it: see the [workflow run](<run URL>) for the outcome.
  ```

  The notice states no result, because the action cannot know one, and
  nothing from the body reaches it: not its text, its fields or its
  `history-summary`. A pull request that inflates its own report to hide a
  failure therefore replaces a passing comment with this notice and fails
  the step; it cannot keep the earlier result on top.

- **When the notice cannot be posted.** If writing the notice fails, the
  `::error` says so and that the previous comment is unchanged. The step
  writes nothing, and so cannot replace a stale comment, when:
  - the pull request comes from a fork (the step skips, as before);
  - `mode: update` finds no comment of its own, including when the posting
    account cannot be determined (the step skips, as before);
  - `mode` is not `upsert`, `create` or `update` (the step skips, as before);
  - the `body` input is over 128 KiB (the step fails before the script
    runs);
  - the load step cannot read or resolve the file, or the file resolves
    under `/proc`, `/sys` or `/dev` (the load step fails and says why);
  - `history-limit` or the history budget is not a number (the step fails
    and, for a result over the limit, says the notice could not be posted).

  In `upsert` mode, when the posting account cannot be determined, the
  notice is posted as a new comment and the earlier one stays (see
  [Which comment is updated](#which-comment-is-updated-1674)); the step
  still fails.

### Comment fields (`comment-fields`, #1677)

`comment-fields` attaches labelled values to the comment, one `Label: value`
per line; the block sits under the body's first heading. It never decides
which comment is updated or whether an empty one is deleted, and a bad line
becomes a note, never a failure. Rules, limits and messages:
[comment-fields.md](../comment-fields.md).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/post-pr-comment@<sha> # vX.Y.Z
  with:
    marker: "e2e-results"
    file: e2e-summary.md
    comment-fields: |
      Environment: staging
      Environment URL: https://staging.example.com
```

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
  entry this result becomes later, and with `comment-fields` set it carries
  the fields the same way (`fields=`, #1677), so the archived entry shows
  them.
- **Archive.** On the next run the previous latest section becomes an entry shaped
  like this:

  <!-- prettier-ignore -->
  `<details><summary>Run #<number> · <short sha> · <at> · workflow run[ ·
  <fields>][ · <history-summary>]</summary>…</details>`

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
  whole body is held to 60,000 bytes, a budget well under GitHub's limit of
  262,144 bytes (a script caller's `HISTORY_MAX_BYTES` can raise the budget,
  never past that limit): entries are kept newest first until one does not
  fit, that entry and every older one are dropped, and
  `> ✂️ <k> older runs not listed (size limit)` counts them, so the archive
  is always the newest runs without gaps. Every size is in bytes, whatever
  the runner's locale, and a body over 65,536 bytes is measured as it will
  be sent (invalid UTF-8 grows when encoded). The latest result is never cut.
  When no earlier run fits and the body is still over GitHub's limit, the
  archive and its note go entirely. A result too large on its own is
  replaced by a notice, as without history (see
  [Size limit](#size-limit-1705)).
- **Untrusted text.** Every `<!-- lgtm-ci:` in a body is neutralised
  (`< !--`), the `lgtm-ci:history:*` sentinels included, so test names or
  failure output can neither forge archive structure nor carry another
  publisher's marker (see [Which comment is updated](#which-comment-is-updated-1674)).
  Re-composing also neutralises the latest section and archived entries
  carried over from the existing comment, so a raw marker an older release
  archived is rewritten on the next run. Each entry's own sentinel line is
  kept, and entries without such text are carried byte for byte.
- **Listing.** Like every mode, history reads every page of PR comments
  (`per_page=100`) and fails the step when the listing fails, instead of
  creating a second comment. When several of the poster's own comments carry
  the marker, the newest one with a stamp or archive is kept (else the newest).
  The other own duplicates are deleted only after the kept comment has been
  updated, so a failed update deletes nothing; a 403 or 404 on that delete is
  a warning. Another account's comment is never deleted. Archive entries that
  only a deleted duplicate carried are not merged into the kept comment.
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
summary says so, instead of reporting zero scores (#1088); its score outputs
are `invalid`. A category the report holds must have a score from 0 to 1:
a missing, null, non-numeric or out-of-range score (1.5 is not 150) is output
as `invalid`, annotated `Unreadable Lighthouse scores`, listed in
`failed-categories` and fails its threshold, 0 included, so `passed` is
`false`; the job summary shows it as unreadable (#1692). A category the report
does not hold at all (a config with `onlyCategories`) is output as `0`,
unchanged: it passes a threshold of 0 and fails any other.

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

When no results file is found, the step still fails, but it first sets
`passed` to `false` and `comment-body` to a comment that says the results are
missing, with no scores. A posting step with `if: always()` can post it.

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

A report's top-level `errors` list (Playwright writes it for a global setup
or configuration failure, a crash outside a test, or "No tests found") makes
the result ❌ FAILED with `success=false`, never PASSED or NO TESTS; an
`errors` value that is not a list, `null` included, is unreadable. Whenever
the report has `suites`, with or without `stats`, a suite whose
`suites`/`specs` is not a list, a spec without a `tests` list, a spec with
`ok: false` and no failed test, a test without a recognised status, or more
failed tests listed than `stats` counts makes the result ⚠️ UNKNOWN (#1692).

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
