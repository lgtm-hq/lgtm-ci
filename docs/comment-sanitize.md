# Untrusted text in pull request comments

Every pull request comment lgtm-ci posts inserts text it did not write: suite and test names, file
paths, tool output, artifact names, error strings and caller inputs. All of it goes through one
sanitiser, `scripts/ci/lib/comment_sanitize.py` (#1676), so a value can never mention a person or
team, link somewhere, inject HTML or markdown, hide text, or imitate a marker the posting code
matches. Markdown keeps its structure: `markdown` mode is for a caller's own report, whose author
the caller trusts; `report` mode is for markdown a tool wrote from untrusted data (a link checker's
report quoting repository file names, a body around a pull request's script output), and also
removes mentions, references, raw HTML, images and links that are not plain HTTPS or relative.

The module is standard library only and Python 3.10 compatible: composite actions run it on the
caller's runner.

## Modes

| Mode        | Output                                   | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------- | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `text`      | One inline line                          | Removes control characters, ANSI escapes and Unicode category `Cf` (bidi overrides and isolates, zero-width characters); line breaks become spaces; caps at 2,000 characters; escapes `<`, `>` and an `&` that would start an entity; backslash-escapes ``\ ` * _ [ ] \| ~ # $``; breaks `@mentions`, `#123`, `GH-123`, `/issues/123`-style paths (#1677), `scheme://` and `www.`                                                                                      |
| `cell`      | One table cell                           | The same as `text`, which already escapes `\|` and flattens line breaks                                                                                                                                                                                                                                                                                                                                                                                                |
| `code`      | One inline code span, backticks included | Backtick run longer than any inside; padded when the value starts or ends with a backtick                                                                                                                                                                                                                                                                                                                                                                              |
| `cell-code` | A code span inside a table cell          | `code`, then `\|` escaped (GFM removes that backslash inside a cell)                                                                                                                                                                                                                                                                                                                                                                                                   |
| `fence`     | A fenced code block, fences included     | Backtick fence of at least three, longer than any run inside; keeps line breaks and tabs; drops trailing line breaks                                                                                                                                                                                                                                                                                                                                                   |
| `markdown`  | The markdown as given                    | Removes control characters, ANSI escapes and `Cf` only; keeps markup and trailing newlines                                                                                                                                                                                                                                                                                                                                                                             |
| `report`    | The markdown, made inert                 | Never parses or deletes: removes invisible characters, then inserts a zero-width space (U+200B) everywhere, code included, after every `@`, in `#1`, `GH-1` and `/issues/1`-style paths, after `<` before a letter, `/`, `!` or `?`, in `![`, `](`, `][`, `]:`, `://`, `www.` and entity starts. Exempt: the layout tags below, `[label](dest)` with a plain HTTPS or relative destination, and plain HTTPS URLs bare or in `<...>`, never on GitHub hosts. Idempotent |
| `url`       | The URL, or nothing                      | `https` only; ASCII host of letters, digits, dots and hyphens; no `xn--` label, no bracketed IP, no host a browser reads as an IPv4 address other than a plain dotted quad (`0x08080808`, `010.010.010.010`, `134744072`, `8.8.8`), no userinfo; optional port; no whitespace, control or non-ASCII character; at most 2,048 characters; `(` and `)` percent-encoded                                                                                                   |
| `host`      | The host of a safe URL, or nothing       | Lower case, no port                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `link`      | `[host](url)`                            | The visible text is the host itself, with its port when that is not 443, so it can never name another host or hide a port; an unsafe URL becomes inert `text`                                                                                                                                                                                                                                                                                                          |
| `html`      | One inline line for raw HTML             | For a raw-HTML line such as a `<summary>`, where GitHub reads no markdown: the same as `text` (invisible characters removed, one line, capped, mentions, references, `/issues/N` paths and URLs broken with `&#8203;`) but with `&`, `<`, `>` and `"` written as entities and no backslash escapes                                                                                                                                                                     |

Breaking a mention or link inserts `&#8203;` (a zero-width space entity) after `@` when a letter,
digit or one of `_ . + -` follows (every start of a mention or of an email autolink's domain, so
`foo@-bar.com` no longer links), after `#` before a digit, before the `:` of `scheme://`, after
`www` and after `GH`. GitHub renders the text unchanged but neither notifies nor links. `report`
mode inserts the character itself, because the entity would show literally inside a code span. An
`_` between two letters or digits is not escaped: it cannot start emphasis, so `my_suite` stays as
it is.

**Reserved marker.** `<!-- lgtm-ci:` opens every marker the posting code matches. In `text` and
`cell` the `<` is escaped; in `report` a zero-width space follows every `<!`. In `code`,
`cell-code`, `fence` and `markdown` a zero-width space is inserted after `<!--` whenever `lgtm-ci`
follows (any case, any spacing), so the text renders the same but never matches.

**Already escaped input.** No mode trusts it. Input is always raw text: `&lt;` renders as `&lt;`,
`\*` as `\*`. Invisible characters are removed before escaping, so a zero-width space a producer
inserted cannot pre-break or hide anything.

**Limits.** `text` is for inline positions: a value placed at the very start of a line can still
begin a list item. Commit SHAs are not broken; GitHub links them within the repository only.
`markdown` does not break mentions: use `report` for markdown whose content nobody reviewed.
GitHub's math rendering of `$` is escaped with a backslash, as GitHub documents.

## `report` mode

`report` mode does not try to read the document's structure, because every way past the earlier
design came from reading it differently from GitHub (a fence that ends inside a list, an HTML
block, a code span split by a table cell, a removed link that joined its neighbours into new
syntax). Its only edits are removing control and invisible characters, then inserting a literal
zero-width space at each of these points, anywhere in the text, inside code and fences too:

- after every `@`, and before and after every `$` (GitHub renders `$...$` as math while only the
  space after the `$` is there);
- after `#` before a digit (this covers `owner/repo#1`), between `GH` and `-` before a digit, and
  before the number or hash in `/issues/N`, `/pull/N`, `/pulls/N`, `/discussions/N` and
  `/commit/SHA` (GitHub links such a path as a reference even when the URL's scheme is broken;
  `owner/repo@SHA` is covered by the `@` break, and a bare hexadecimal word stays as it is);
- after `<` before a letter, `/`, `!` or `?` (tags, comments, autolinks and the reserved marker);
- between `!` and `[`; after `]` before `(`, `[` or `:` (inline, reference and definition syntax);
- before `://` and after `www` before `.`;
- after `&` that starts an entity other than `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#8203;`.

Three kinds of construct keep some of these points, and only their own syntax:

- the layout tags `<details>`, `</details>`, `<summary>`, `</summary>`, `<sub>`, `</sub>` keep their
  `<`, exactly so: `reusable-validate.yml` wraps the script output in
  `<details><summary>Output</summary>`, and the link-check body wraps lychee's report in
  `<details><summary>` and ends with a `<sub>` footer;
- an inline link `[label](https://...)` keeps its `](` and the `://` of its destination; the label
  has no `[`, `]`, backtick or `!` and still gets every insertion;
- a bare HTTPS URL keeps its `://`, and the same URL as `<https://...>` (how lychee writes every
  link) keeps its `<` and `://`. A bare URL runs, as GitHub's autolink does, to the next space,
  tab, newline or `<`, less trailing punctuation and an unbalanced `)`.

A URL qualifies only as a whole: it passes the `url` rules, has no `@`, `$`, `&`, `(`, `)`, `|`,
backtick or backslash, holds no other break point at all (no reference, no second `://`, no
`www.`), and is not on a GitHub host (`github.com`, `githubusercontent.com`, `githubassets.com`,
`github.io`, `github.dev`, `gh.io`, `git.io` and their subdomains), where a link to an issue, pull
request, discussion or commit would create a cross-reference. The host list is defined once, in
`scripts/ci/lib/comment_urls.py` (`comment_sanitize.github_host`), and caller `comment-fields`
use the same one. The URL of a link or autolink must
also end where GitHub's bare-URL read would end: after its closing `)` or `>` only trailing
punctuation may come before the next space or `<`, because a backslash before the `[` or `<`
makes GitHub read the URL as a bare one and link it on (`\[a](https://ok.example)@other.example`).
So an exemption never switches off any other protection inside its range. A link followed
directly by other text with no space (`[a](https://e.example)|x`) is therefore shown as plain
text. Relative destinations are not exempt: none of
lgtm-ci's report bodies uses one, and a relative destination GitHub does not read as a link (after
`\[`, inside a code span, split by a table cell) can carry a live `http://` or `www.` autolink.

Removing the inserted characters gives back the cleaned input, so a second pass gives the same
text: `report(report(x)) == report(x)` for every input. A value can still change layout (close a
`<details>` early, start a list); it cannot notify, link outside the rules above, or embed HTML.

**Cost.** Text copied out of such a comment, code blocks included, may carry invisible zero-width
spaces, for example after an `@` in a log line or after `<` in an HTML snippet. lgtm-ci's own
report bodies (validate, link-check, a lychee report) contain none of the trigger points in normal
output and pass byte for byte.

## Numbers

A count or percentage read from a report file or from jq is checked before any arithmetic or
output, and a malformed one never reads as a clean result. In bash,
`comment_read_count VAR LABEL VALUE` sets `VAR` to a whole number of at most nine digits and
`comment_read_decimal VAR LABEL VALUE [KEEP]` to a non-negative decimal (or exactly `KEEP`, a plain
lower-case word such as `n/a`; any other `KEEP` is ignored). Anything else sets `VAR` to 0 for
arithmetic, logs a `::warning::` that names the label (never the value), and adds the label to
`COMMENT_UNREADABLE`; `comment_unreadable_lines` then prints, for the comment,
"⚠️ The report's `<label>` value is not a number; see the job log."

| Renderer       | Malformed value                                      | Status                                                                                 |
| -------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Playwright     | a count, or no readable `stats`/`suites` at all      | `⚠️ UNKNOWN`, "Test counts unreadable", output `success=false`                         |
| Playwright     | the duration: N/A, notice under the table            | unchanged (the duration decides nothing)                                               |
| Coverage       | a percentage: `⚠️ unreadable` cell and notice        | `⚠️ UNREADABLE`, output `passed=false`                                                 |
| Lighthouse     | a score: `⚠️ unreadable` cell and notice             | `⚠️ UNREADABLE`, output `passed=false`                                                 |
| Test summary   | a count: no totals, notice                           | `⚠️ NO COUNTS`, "Test counts unreadable"                                               |
| Test summary   | the coverage percentage: `unreadable`, notice        | coverage "Unable to retrieve coverage"                                                 |
| Test summary   | `expected_failures.omitted`: no "and N more", notice | unchanged (the list decides nothing)                                                   |
| File breakdown | additions or deletions: counted as 0, notice         | (no status)                                                                            |
| Security       | `issues_count`: the issues list's length, notice     | never "No security vulnerabilities found"; `AUDIT FAILED` when there is no issues list |

A value the report format always writes is unreadable when it is missing or `null`, never 0: the
Playwright stats (`expected`, `unexpected`, `flaky`, `skipped`, `duration`), every coverage
percentage (the `n/a` keep word comes only from lgtm-ci's own extractor, never from the file), a
Lighthouse score (`null` for a category that errored) and the security `issues_count`. A file that
is not JSON is unreadable too. A readable Playwright report with no tests says `⚠️ NO TESTS`,
never PASSED.

The security formatter also accepts an integral float such as `2.0`, and an `issues` list longer
than `issues_count` wins over the count, with its own notice.

## Caller fields

`comment-fields` (#1677) is parsed and rendered by
`scripts/ci/lib/comment_fields.py`, which passes every label and value through
this module (`text`, `cell`, `link`); see [comment-fields.md](comment-fields.md).

## Publishing a report file

`reusable-publish-artifact-report.yml` posts a file another job wrote, and that job may have run the
pull request's code. The publisher therefore passes the file through the sanitiser itself, raw or
not, through `compose-artifact-report-comment.sh` (`RAW`, `SANITIZE_MODE`). Its `raw-sanitize`
input picks the mode: `markdown` (default) for a caller's own report, `report` for lgtm-ci's
link-check and validate workflows.

## Python

```python
import comment_sanitize  # scripts/ci/lib on sys.path

comment_sanitize.text(value)            # also cell, code, cell_code; max_chars=
comment_sanitize.fence(value)           # max_chars=None, info=""
comment_sanitize.markdown(value)        # max_chars=None
comment_sanitize.report(value)          # max_chars=None; scripts/ci/lib/comment_report.py
comment_sanitize.url(value)             # str | None
comment_sanitize.host(value)            # str | None
comment_sanitize.link(value)            # "[host](url)" or inert text
comment_sanitize.display_host(value)    # "host" or "host:port" (not 443), or None
comment_sanitize.github_host(value)     # True for a safe URL on a GitHub host
comment_sanitize.html(value)            # inline text for a raw-HTML line
comment_sanitize.labelled_link(value, "View report")  # label written by the renderer only
```

A script run as `python3 -I` puts `scripts/ci/lib` on `sys.path` first, as
`scripts/ci/security/format-security-comment.py` does.

## Command line and bash

The value never travels on argv, where it could be read as an option:

```bash
python3 -I -S scripts/ci/lib/comment_sanitize.py MODE [--env NAME] [--nul | --json] [--max N]
```

The value comes from the environment variable `NAME`, or from stdin. `--nul` reads NUL-separated
values and writes each result followed by a NUL; `--json` reads a JSON array of strings and writes
one back. An unsafe URL is an empty result. Output has no trailing newline. Exit status 2 is a
usage error.

Bash renderers source `scripts/ci/lib/github/comment_sanitize.sh`:

```bash
safe_name="$(comment_sanitize text --env TEST_SUITE_NAME)"
safe_url="$(comment_sanitize url --env REPORT_URL)"
printf '%s' "$tool_output" | comment_sanitize fence
mapfile -d '' safe < <(printf '%s\0' "${values[@]}" | comment_sanitize text --nul)
```

Batch with `--nul` or `--json` when a renderer has many values: each call starts Python once.

The wrapper looks up `python3` on `PATH` without running it, so a script that checks its own
Python first is not overtaken. A runner without `python3` gets a fail-closed fallback with a
warning: inline modes keep only letters, digits, spaces and `, ( ) + = -`, the
others become `?` (`report` the same, line by line); `url`, `host` and `link` give nothing;
`markdown` only breaks `<!--`. It always succeeds, so a renderer under `set -e` carries on, and a
`--nul` batch keeps every record.

## The guard

`tests/python/test_comment_renderer_guard.py` lists every comment renderer with the untrusted
values it reads. A quote-aware scanner (`tests/helpers/comment_guard_support.py`) splits each
script into statements and follows untrusted values, and values read from files or jq, through
assignments in file order; it fails when one reaches a statement outside a sanitiser feed, a test,
a default or a log annotation, when a renderer is not listed, or when the Python formatter adds a
value to the comment that it did not sanitise (checked statement by statement, in order). The
test's docstring lists what it still cannot see: values passed through functions, computed
`printf -v` names, `read`, other files; branches are read in order; jq and awk programs are not
parsed; whether the sanitiser mode fits the place the value goes; `# comment-safe:` is a reviewer's
word. Each `;`, `&&`, `||` or newline part of a command substitution is judged on its own, and a
stage that writes a file (`tee`, `>`) before the sanitiser keeps the value untrusted. Constructs it
cannot follow fail outright: backtick substitution, name references, `${!...}`, `envsubst`,
`printenv` and subscript assignment in bash; assignment into `sections[...]` in Python, where
`for`, `with` and walrus targets and comprehension variables are never trusted and only the
sanitiser's mode functions count as safe.
