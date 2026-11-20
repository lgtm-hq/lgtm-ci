# Comment fields (`comment-fields`, #1677)

A caller can attach labelled values to any pull request comment lgtm-ci
posts, for example the environment a test run targeted. lgtm-ci does not
need to know the labels in advance.

```yaml
jobs:
  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-playwright.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      pull-requests: write
    with:
      comment-fields: |
        Environment: staging
        Environment URL: https://staging.example.com
        Region: eu-west-1
```

The comment then shows, directly under its first heading:

> **Environment:** staging
> **Environment URL:** [staging.example.com](https://staging.example.com)
> **Region:** eu-west-1

The input is on the `post-pr-comment` action and on every reusable workflow
that posts a comment (the list is in
[reusable-workflows.md](reusable-workflows.md#pr-comment-fields-comment-fields-1677)).
It is untrusted text: a caller may pass through a pull request title or a
branch name. It reaches the poster through `env`, never through the shell.

## Format

One field per line, `Label: value`. The label is the text before the first
colon; the value is the rest of the line, so a value may contain colons
(`Started: 12:30:05 UTC`). There are no nested keys and no list of supported
labels: any label works.

- **Spaces.** Spaces and tabs around the line, the label and the value are
  removed. A tab inside is shown as a space. Every other kind of space (a
  no-break space, U+2000 to U+200A, U+3000 and the like) is refused, see
  below.
- **Blank lines** (empty, or only spaces and tabs) are skipped.
- **Comment lines** are skipped: a line whose first character after leading
  spaces is `#`. A label cannot start with `#`.
- **Line breaks.** CRLF and a lone CR end a line, as GitHub renders them.
  Line numbers in notes count every line, blank and comment lines included.
- **Links.** A value that starts with `https://` and is a whole safe URL (the
  sanitiser's `url` rules: ASCII host name, no user name or password, no
  spaces, no numeric host other than a plain dotted quad) is shown as a link
  whose visible text is its host, with its port when that is not 443:
  `[staging.example.com](https://staging.example.com)`,
  `[staging.example.com:8443](https://staging.example.com:8443/)`. A URL in
  the middle of a value is shown as plain text and does not link.
- **Links to GitHub are shown as text.** A link to a GitHub host
  (`github.com`, `*.github.io`, `githubusercontent.com`, `gh.io`, `git.io` and
  the others the sanitiser lists) is shown as code, `` `https://github.com/o/r/issues/1` ``,
  never as a link: a link to an issue, pull request, discussion or commit
  would add a cross-reference to it. There is no note; the job log says so for
  the line. A GitHub path in plain text (`o/r/issues/1`) does not link either.
- **Values that start with `//`** (`Target: //app:test`, `Path: //server/share`)
  are plain text. Only a line that is nothing but a URL needs a label.
- **Commit hashes.** A bare 40-character hexadecimal value may still be linked
  by GitHub as a commit of the same repository (the sanitiser's existing
  policy, [comment-sanitize.md](comment-sanitize.md)).
- **Order.** Fields are shown in the order given.
- **Duplicates.** Labels compare as they are displayed: runs of spaces and
  tabs count as one space, then Unicode NFKC and case folding apply, so
  `Environment Name` and `Environment<TAB>Name`, `Café` written composed and
  decomposed, `REGION` and `region` are the same label. The first one wins; a
  later line with the same label gets a note.
- **Empty input.** Unset, empty, blank or comment-only input shows nothing,
  and the posted comment is byte for byte what it is without the input.

Every label and value goes through the shared sanitiser
([comment-sanitize.md](comment-sanitize.md)): `text` for labels and plain
values (`cell` in the table style), `link` for an HTTPS value. A label or
value can therefore never mention a person or team, link anywhere else,
inject HTML or markdown, hide text, or imitate a marker.

## Limits

| Limit          | Value       | Why                                                                                                                                                              |
| -------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Whole input    | 8,192 bytes | Room for 20 long fields                                                                                                                                          |
| Rendered block | 4,000 chars | Escaping can make a value five times longer; once the next field would pass the budget, the rest are counted in one note, `N more fields not shown (size limit)` |
| History stamp  | 1,024 chars | The `fields=` data of the latest run; fields that do not fit show as `+N more` on the history line                                                               |
| Fields         | 20          | A context block, not a report; more lines get a note each                                                                                                        |
| Label          | 64 chars    | Fits a table header and a bold label on one line                                                                                                                 |
| Value          | 512 chars   | Room for a long URL with a query string                                                                                                                          |
| Notes shown    | 10          | Further bad lines are counted in one closing note (`N more lines not shown`); the job log lists them                                                             |
| Log problems   | 50          | Further problems are counted in one log line                                                                                                                     |
| History line   | 32 / 60     | An archived run's line cuts labels to 32 and values to 60 characters, and shows a link's host only                                                               |

## Bad lines never fail anything

A bad line never fails the job or the posting. Every valid field is still
shown. In the place of each bad field the comment shows a note that lgtm-ci
writes, naming the line number and the reason, with a link to the job run:

> ⚠️ `comment-fields` line 2: no colon found ([job log](https://github.com/owner/repo/actions/runs/1))

The bad line's own content is never shown, in the comment or in the log. The
job log prints each reason with its line number and an example of a correct
line, then a short summary of the format, and the step raises one
`::warning` annotation that lists the line numbers:

```text
comment-fields: 2 fields shown.
comment-fields: line 2: no colon found. A correct line looks like "Environment: staging".
comment-fields: write one field per line as "Label: value". ...
::warning title=comment-fields::1 comment-fields line not shown (line 2); the job log lists each reason
```

## Rules and messages

Each rule has a stable message; the tests quote them. Line rules are checked
in this order, and a line gets the first that applies.

| Mistake                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Example line                            | Message                                                          |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ---------------------------------------------------------------- |
| A character that renders as nothing or as a space other than U+0020: controls (NUL, ESC), format characters (bidi overrides, zero-width space, tags), unpaired surrogates, private-use and unassigned code points, every Unicode space and separator other than U+0020 (no-break space, U+2000 to U+200A, U+202F, U+205F, U+3000, U+2028, U+2029), the combining grapheme joiner U+034F, variation selectors (U+FE00 to U+FE0F, U+E0100 to U+E01EF), Mongolian variation selectors, Hangul fillers (U+115F, U+1160, U+3164, U+FFA0) and the braille blank U+2800. A tab is allowed | `Env: prod` + U+202E + `gnits`          | `the line contains a control or invisible character`             |
| No colon                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `Environment staging`                   | `no colon found`                                                 |
| A line that is only a URL, whatever its scheme                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | `https://staging.example.com`           | `a link needs a label before it`                                 |
| Nothing before the colon                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `: staging`                             | `nothing before the colon`                                       |
| Label over 64 characters                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `A very long label …: x`                | `the label is longer than 64 characters`                         |
| Nothing after the colon                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | `Environment:`                          | `nothing after the colon`                                        |
| Value over 512 characters                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `Notes: …`                              | `the value is longer than 512 characters`                        |
| A link that is not HTTPS                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `URL: http://staging.example.com`       | `links must start with https://`                                 |
| A link that is not a whole safe HTTPS address                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `URL: https://user@staging.example.com` | `a link must be a whole https:// address with a plain host name` |
| A label used before                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `region: us-east-1` after `Region: …`   | `this label is already used on line 1`                           |
| A 21st field                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | any valid line after 20 fields          | `more than 20 fields; this one is not shown`                     |

"Not HTTPS" means a value that starts with a scheme and `//` (`http://`,
`ftp://`), or with `javascript:`, `vbscript:`, `data:<type>/`, `file:/` or
`mailto:`. Other values with colons are plain text.

If the whole input cannot be read, the report is still posted, with one note
in place of the fields:

| Mistake                                                                                  | Message                                 |
| ---------------------------------------------------------------------------------------- | --------------------------------------- |
| Over 8,192 bytes                                                                         | `the input is larger than 8192 bytes`   |
| Not valid UTF-8                                                                          | `the input is not valid UTF-8 text`     |
| The runner has no python3                                                                | `this runner has no python3`            |
| The renderer failed (it crashed, wrote nothing, or no temporary directory could be made) | `internal error, see the job log`       |
| The report already fills the comment: the block would pass the 65,536-character budget   | `the comment is at GitHub's size limit` |

> ⚠️ `comment-fields` could not be read: the input is larger than 8192 bytes ([job log](https://github.com/owner/repo/actions/runs/1))

Each of these also raises one `::warning`. None of them fails the step.

## Where the block goes

The poster (`scripts/ci/actions/post-pr-comment.sh`) inserts the block, so
every comment gets it: the test summary, the prebuilt and rich-coverage
summaries, quality, security, file breakdown, artifact previews and reports
(`raw` ones included), link check, validate and the semantic PR title failure
comment.

- The block sits directly under the body's first heading: the first line that
  is not blank and not a one-line HTML comment, when it is a `#` to `######`
  heading. A blank line separates it from the heading and from what follows.
- When the first visible line is not a heading, the block goes at the top of
  the body.
- It always comes after the hidden marker line, which the poster writes
  itself, and after the history stamp.
- **Identity.** The fields never change which comment is updated: the marker
  line and the posting account decide that (#1674).
- **Emptiness.** The fields never keep a comment alive: an empty report is
  skipped, or deleted with `delete-on-empty`, before the block is added.
- **Size.** The block is at most 4,000 characters and the `fields=` stamp
  1,024, so a body the publishers keep under their 60,000-byte budget stays
  under 65,536 characters with them, a conservative budget far below GitHub's
  limit of 262,144 bytes ([Size limit](actions/pr-comments.md#size-limit-1705)).
  If the body is so large that the block would push the comment past that
  budget, the poster shows the short note
  `could not be read: the comment is at GitHub's size limit` instead. A
  report over GitHub's limit on its own is replaced by the size notice, and
  its fields are not rendered.

## History

With `comment-history` on, each earlier run's line under **🕘 Previous runs**
shows that run's fields compactly, so a changed environment stays visible:

```text
Run #12 · 1a2b3c4 · 2026-11-20T12:00:00Z · workflow run · Environment: staging · Region: eu-west-1
```

The latest stamp carries the run's fields as base64 of a small JSON document
(`fields=`, after `summary=`); when that result is archived, the entry line is
rendered from it and sanitised again. The line sits inside a raw-HTML
`<summary>`, where GitHub reads no markdown, so it is escaped for HTML (the
sanitiser's `html` mode): `a*b` and `#12` read as written, and nothing in it
links or mentions. The composer reads the stamp's run metadata on its own: a
malformed, empty or oversized `fields=` (or `summary=`) is dropped, and the
run keeps its place in the history. A caller's text never reaches a stamp or
sentinel as text: base64 holds only letters, digits, `+`, `/` and `=`, and the
block itself is sanitised, so it can never contain `<!-- lgtm-ci:`. An
archived body keeps its own block. A run with notes adds
`⚠️ N field lines not shown`; an unreadable input adds `⚠️ fields unreadable`.

**Downgrading.** An older lgtm-ci release does not recognise a stamp with
`fields=`. Its next run nests the whole previous comment, archive included,
inside one "earlier run (unstamped)" entry. The neutralised history lines then
show as visible text in that entry (`< !-- lgtm-ci:history:latest … fields=… -->`,
`< !-- lgtm-ci:history:start -->` and so on), and the earlier runs stay nested
there. Nothing is lost; the comment is untidy until it is deleted or the
pull request ends.

## Styles

`scripts/ci/lib/comment_fields.py` renders three styles, for the three test
report formats of #1678. Callers get `block` only, until `comment-format`
selects the others.

- `block`: one quoted line per field, `> **Label:** value`.
- `compact`: one line, `**Label:** value · **Label:** value`; a note is
  one more `·` item.
- `table`: labels in the header row, values below; a note is a column headed
  `⚠️ comment-fields line N` whose cell is the reason.

The compact mock-up on #1678 left out the label of the URL field; the
renderer keeps every label, so no format drops information.

## Use from code

```bash
source scripts/ci/lib/github/comment_fields.sh
COMMENT_FIELDS_RUN_URL="$run_url" comment_fields render --env COMMENT_FIELDS \
  --style block --out block.md --stamp stamp.txt   # log lines on stdout
STAMP="$b64" comment_fields history --env STAMP     # an archived run's line
```

```python
import comment_fields  # scripts/ci/lib on sys.path

parsed = comment_fields.parse(raw)  # bytes or str; never raises
comment_fields.render(parsed, "block", run_url)
comment_fields.log_lines(parsed)
comment_fields.history_stamp(parsed)
```

The modules (`comment_fields.py` renders and runs the command line,
`comment_fields_parse.py` parses and logs, `comment_fields_history.py` keeps
the stamp) are standard library only and Python 3.10 compatible, and are run
as `python3 -I -S`. The renderer guard
(`tests/python/test_comment_renderer_guard.py`) checks that they add only
sanitised values to the comment. An internal error in the command line never
fails the step: it writes the internal-error note and one warning.
