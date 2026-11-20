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
  removed.
- **Blank lines** (empty, or only spaces and tabs) are skipped.
- **Comment lines** are skipped: a line whose first character after leading
  spaces is `#`. A label cannot start with `#`.
- **Line breaks.** CRLF and a lone CR end a line, as GitHub renders them.
  Line numbers in notes count every line, blank and comment lines included.
- **Links.** A value that starts with `https://` and is a whole safe URL (the
  sanitiser's `url` rules: ASCII host name, no user name or password, no
  spaces) is shown as a link whose visible text is its host:
  `[staging.example.com](https://staging.example.com)`. A URL in the middle of
  a value is shown as plain text and does not link.
- **Order.** Fields are shown in the order given.
- **Duplicates.** Labels compare without regard to case. The first one wins;
  a later line with the same label gets a note.
- **Empty input.** Unset, empty, blank or comment-only input shows nothing,
  and the posted comment is byte for byte what it is without the input.

Every label and value goes through the shared sanitiser
([comment-sanitize.md](comment-sanitize.md)): `text` for labels and plain
values (`cell` in the table style), `link` for an HTTPS value. A label or
value can therefore never mention a person or team, link anywhere else,
inject HTML or markdown, hide text, or imitate a marker.

## Limits

| Limit        | Value       | Why                                                                                                        |
| ------------ | ----------- | ---------------------------------------------------------------------------------------------------------- |
| Whole input  | 8,192 bytes | Room for 20 long fields; keeps the block and its history stamp small inside the 60,000-byte comment budget |
| Fields       | 20          | A context block, not a report; more lines get a note each                                                  |
| Label        | 64 chars    | Fits a table header and a bold label on one line                                                           |
| Value        | 512 chars   | Room for a long URL with a query string                                                                    |
| Notes shown  | 10          | Further bad lines are counted in one closing note (`N more lines not shown`); the job log lists them       |
| Log problems | 50          | Further problems are counted in one log line                                                               |
| History line | 32 / 60     | An archived run's line cuts labels to 32 and values to 60 characters, and shows a link's host only         |

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

| Mistake                                                                                         | Example line                            | Message                                                          |
| ----------------------------------------------------------------------------------------------- | --------------------------------------- | ---------------------------------------------------------------- |
| A control, invisible or line-separator character (NUL, bidi override, zero-width space, U+2028) | `Env: prod` + U+202E + `gnits`          | `the line contains a control or invisible character`             |
| No colon                                                                                        | `Environment staging`                   | `no colon found`                                                 |
| A link with no label                                                                            | `https://staging.example.com`           | `a link needs a label before it`                                 |
| Nothing before the colon                                                                        | `: staging`                             | `nothing before the colon`                                       |
| Label over 64 characters                                                                        | `A very long label …: x`                | `the label is longer than 64 characters`                         |
| Nothing after the colon                                                                         | `Environment:`                          | `nothing after the colon`                                        |
| Value over 512 characters                                                                       | `Notes: …`                              | `the value is longer than 512 characters`                        |
| A link that is not HTTPS                                                                        | `URL: http://staging.example.com`       | `links must start with https://`                                 |
| A link that is not a whole safe HTTPS address                                                   | `URL: https://user@staging.example.com` | `a link must be a whole https:// address with a plain host name` |
| A label used before                                                                             | `region: us-east-1` after `Region: …`   | `this label is already used on line 1`                           |
| A 21st field                                                                                    | any valid line after 20 fields          | `more than 20 fields; this one is not shown`                     |

"Not HTTPS" means a value that starts with a scheme and `//` (`http://`,
`ftp://`), or with `javascript:`, `vbscript:`, `data:<type>/`, `file:/` or
`mailto:`. Other values with colons are plain text.

If the whole input cannot be read, the report is still posted, with one note
in place of the fields:

| Mistake                   | Message                               |
| ------------------------- | ------------------------------------- |
| Over 8,192 bytes          | `the input is larger than 8192 bytes` |
| Not valid UTF-8           | `the input is not valid UTF-8 text`   |
| The runner has no python3 | `this runner has no python3`          |

> ⚠️ `comment-fields` could not be read: the input is larger than 8192 bytes ([job log](https://github.com/owner/repo/actions/runs/1))

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

## History

With `comment-history` on, each earlier run's line under **🕘 Previous runs**
shows that run's fields compactly, so a changed environment stays visible:

```text
Run #12 · 1a2b3c4 · 2026-11-20T12:00:00Z · workflow run · Environment: staging · Region: eu-west-1
```

The latest stamp carries the run's fields as base64 of a small JSON document
(`fields=`, after `summary=`); when that result is archived, the entry line is
rendered from it and sanitised again. A caller's text never reaches a stamp or
sentinel as text: base64 holds only letters, digits, `+`, `/` and `=`, and the
block itself is sanitised, so it can never contain `<!-- lgtm-ci:`. An
archived body keeps its own block. A run with notes adds
`⚠️ N field lines not shown`; an unreadable input adds `⚠️ fields unreadable`.

An older lgtm-ci release that reads a stamp with `fields=` does not recognise
it and archives the whole comment once as an unstamped run.

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

The module is standard library only and Python 3.10 compatible, and is run as
`python3 -I -S`. The renderer guard (`tests/python/test_comment_renderer_guard.py`)
checks that it adds only sanitised values to the comment.
