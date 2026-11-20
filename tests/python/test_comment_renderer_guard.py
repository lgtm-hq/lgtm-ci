# SPDX-License-Identifier: MIT
"""Guard: comment renderers sanitise every untrusted value they insert (#1676).

``RENDERERS`` lists each bash renderer with the variables that hold text it
did not write (caller inputs, report content, tool output). The analysis in
``tests/helpers/comment_guard_support.py`` splits each script into statements
with a quote-aware scanner and judges every use of an untrusted value by the
statement it is in:

- a use is safe only inside a command substitution or pipeline stage that
  feeds ``comment_sanitize`` (or the chrome helpers and number checks that
  call or replace it), inside ``[[ ... ]]``, as the subject of ``case``, in a
  default declaration or ``export``, or in a log annotation statement. A
  sanitiser call or ``::warning::`` elsewhere in the line, or in a comment,
  clears nothing;
- assignments carry taint: a copy of an untrusted value is untrusted, and the
  statement that finally emits it (a heredoc line, a ``printf`` to the
  comment file) is reported, naming where the value came from;
- heredoc body lines and multi-line quoted strings are checked line by line,
  so ``# ${X}`` inside a body string is not mistaken for a comment;
- values read from files or jq (``jq``, ``cat``, ``sed``, ``awk``, ``grep``,
  ``tail``, ``head``, ``cut``; ``cat <<EOF`` of the renderer's own heredoc
  excepted) are untrusted too, in file order: an assignment from a reader
  taints its target, an assignment from the sanitiser or
  ``comment_read_count``/``comment_read_decimal`` clears it, and a reader substitution
  inside any other statement is an offence;
- a use that never reaches the comment (a numeric comparison, a path, the job
  log) says so with ``# comment-safe: <reason>`` on its statement or on the
  line above; a reviewed assignment clears its target.

The Python formatter is read function by function, statement by statement in
order, so a raw value assigned after a safe one is caught; ``append``,
``extend``, ``insert``, ``+=`` and rebinding of ``sections`` are all checked.

A scan also finds files that look like renderers and fails on any that is not
classified here; the explicit inventory stays the main control, because
content heuristics cannot find every new renderer.

What it still cannot see, plainly: it trusts the variable lists below to be
complete; it does not follow values through functions, ``printf -v`` with a
computed name, indirect expansion, ``read``, arrays filled by loops, or
across files; it follows ``if``/``elif``/``else``/``fi`` branches (a value
untrusted on any branch stays untrusted after ``fi``) but reads ``case`` arms
and loops in order; it does not parse jq or awk programs (the file-breakdown
jq has an explicit check); it does not check that the sanitiser mode fits
where the value goes (``markdown`` output under a ``##`` heading passes),
which stays out of scope; a bare reader command whose output goes straight
to stdout is caught only when it reads a tainted path; and
``# comment-safe:`` is a reviewer's word, not a proof. Constructs it cannot
follow fail outright instead of passing unseen: a backtick substitution, a
name reference, ``${!...}``, ``envsubst``, ``printenv`` and a subscript
assignment in bash; an assignment into ``sections[...]`` in Python, where
``for``, ``with`` and walrus targets and comprehension variables are never
trusted and only the sanitiser's mode functions (not ``cap`` or
``strip_invisible``) count as safe. Not followed: a list mutated before it is
added with ``extend``, and ``print`` to stdout.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from assertpy import assert_that
from comment_guard_support import offences, python_offences, statements

PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = PROJECT_ROOT / "scripts" / "ci"

#: Bash renderers and the variables holding untrusted text in each.
RENDERERS: dict[str, tuple[str, ...]] = {
    "actions/generate-test-summary.sh": ("TEST_SUITE_NAME", "RESULTS_INCOMPLETE"),
    "actions/generate-coverage-comment.sh": (
        "TEST_SUITE_NAME",
        "REPORT_URL",
        "THRESHOLD_LINES",
        "THRESHOLD_BRANCHES",
        "THRESHOLD_FUNCTIONS",
    ),
    "actions/generate-playwright-comment.sh": ("REPORT_URL", "FAILED_TESTS"),
    "actions/generate-lighthouse-comment.sh": ("REPORT_URL",),
    "actions/generate-lintro-comment.sh": ("SUMMARY",),
    # File and category names are also checked in jq by a test of their own.
    "actions/generate-file-breakdown.sh": ("categories_json",),
    "actions/compose-artifact-report-comment.sh": (
        "REPORT_FILE",
        "TITLE",
        "WORKFLOW_NAME",
    ),
    "actions/compose-artifact-preview-comment.sh": (
        "ARTIFACT_NAME",
        "ARTIFACT_URL",
        "SUMMARY",
        "SUMMARY_TEXT",
        "TITLE",
        "WORKFLOW_NAME",
    ),
    "actions/format-semantic-pr-title-failure-comment.sh": (
        "LENGTH_ERROR",
        "SEMANTIC_ERROR",
        "combined_error",
        "ALLOWED_TYPES",
    ),
    "actions/wrap-lychee-report.sh": (
        "LYCHEE_REPORT",
        "LYCHEE_OUTCOME",
        "PATHS",
        "FILE_EXTENSIONS",
        "EXCLUDE_PATTERNS",
        "TIMEOUT",
        "FAIL_ON_ERROR",
    ),
    "actions/run-validate-script.sh": ("VALIDATION_NAME", "SCRIPT_PATH", "OUTPUT_FILE"),
    "security/run-lintro-audit.sh": ("COMMENT_TITLE",),
    "lib/github/comment_chrome.sh": ("title",),
    # Hands the caller's comment-fields to comment_fields.py by name only.
    "lib/github/comment_fields.sh": ("COMMENT_FIELDS",),
}
#: Python renderers, checked by syntax tree.
PYTHON_RENDERERS = (
    "security/format-security-comment.py",
    "lib/comment_fields.py",
    "lib/comment_fields_history.py",
)
#: Files that look like renderers but are not, and why.
NOT_RENDERERS: dict[str, str] = {
    "actions/render-test-summary.sh": "execs generate-test-summary.sh, which sanitises",
    "actions/post-pr-comment.sh": (
        "posts a body a renderer built (#1674, #1675) and inserts the"
        " comment-fields block lib/comment_fields.py rendered (#1677)"
    ),
    "actions/post-pr-comment-history.sh": (
        "folds earlier bodies into history (#1674); an entry line adds only"
        " lib/comment_fields_history.py output, sanitised in html mode (#1677)"
    ),
    "actions/scan-vulnerabilities.sh": "writes the job summary, not a comment",
    "lib/github/summary.sh": "job summary helpers, not a pull request comment",
    "lib/comment_sanitize.py": "the sanitiser itself",
    "lib/comment_report.py": "the sanitiser's report mode",
    "lib/comment_urls.py": "the sanitiser's URL rules",
    "catalog/render.py": "renders docs/catalog.md, not a pull request comment",
}
RENDERER_SH_MARKS = (
    r"<sub>",
    r"<details>",
    r"comment_chrome_(?:heading|footer)",
    r"\bCOMMENT_(?:OUTPUT|FILE|BODY)\b",
)
LOOKS_LIKE_RENDERER_SH = re.compile("|".join(RENDERER_SH_MARKS))
LOOKS_LIKE_RENDERER_PY = re.compile(r"(?i)\b(?:pr|pull request) comment\b")


def _lines(found: list[str]) -> list[int]:
    """Return the line numbers of guard messages."""
    return [int(message.split(":")[1]) for message in found]


@pytest.mark.parametrize("relative", sorted(RENDERERS))
def test_renderer_sources_the_sanitiser(relative: str) -> None:
    """Each bash renderer loads the sanitiser (directly or through the chrome)."""
    text = (SCRIPTS / relative).read_text(encoding="utf-8")
    sourced = re.search(r"source .*comment_(?:sanitize|chrome)\.sh", text)
    assert_that(sourced).is_not_none()


@pytest.mark.parametrize("relative", sorted(RENDERERS))
def test_untrusted_values_reach_the_comment_only_sanitised(relative: str) -> None:
    """No untrusted or file-read value reaches a statement unsanitised."""
    text = (SCRIPTS / relative).read_text(encoding="utf-8")
    found = offences(text, RENDERERS[relative], f"scripts/ci/{relative}")
    assert_that(found).is_empty()


def _script(*lines: str) -> str:
    """Join script lines, one per argument, each ending in a newline."""
    return "".join(line + "\n" for line in lines)


#: A sanitised value of another variable, for the unrelated-sanitiser case.
_SANITISED_X = '"$(printf \'%s\' "$X" | comment_sanitize text)"'

RAW_USES = [
    pytest.param(
        _script(
            ': "${NAME:=x}"',
            'if [[ -n "$NAME" ]]; then :; fi',
            'safe="$(printf \'%s\' "$NAME" | comment_sanitize text)"',
            'echo "## ${NAME} Report"',
            'copy="$NAME"',
            'BODY="## ${copy}"',
            'printf \'%s\\n\' "$BODY" >>"$COMMENT_OUTPUT"',
        ),
        [4, 7],
        id="heading-and-copy-emitted",
    ),
    pytest.param(
        _script(f"printf '## %s %s\\n' {_SANITISED_X} \"$NAME\""),
        [1],
        id="unrelated-sanitiser-on-the-line",
    ),
    pytest.param(
        _script(
            "printf '%s' \"$NAME\" # comment_sanitize",
            "printf -v BODY '%s' \"$NAME\" # ::notice",
            'printf \'%s\' "$BODY" >"$COMMENT_OUTPUT"',
        ),
        [1, 3],
        id="sink-or-annotation-only-in-a-comment",
    ),
    pytest.param(
        _script('echo "::warning::x"; echo "$NAME" >>"$COMMENT_OUTPUT"'),
        [1],
        id="annotation-then-raw-statement",
    ),
    pytest.param(
        _script(
            "cat <<EOF",
            "## $(printf '%s' \"$NAME\") $(comment_sanitize text --env OTHER)",
            "# ${NAME}",
            "EOF",
        ),
        [2, 3],
        id="heredoc-lines",
    ),
    pytest.param(
        _script(
            'BODY="intro',
            "# ${NAME}",
            'end"',
            'printf \'%s\' "$BODY" >"$COMMENT_OUTPUT"',
        ),
        [4],
        id="level-one-heading-in-a-quoted-string",
    ),
    pytest.param(
        _script(
            'printf \'%s\' "$(jq -r .title "$F")"',
            "cat <<EOF",
            '$(cat "$F")',
            "EOF",
        ),
        [1, 3],
        id="file-content-read-inline",
    ),
    pytest.param(
        _script(
            'V=$(jq -r .x "$F")',
            'echo "## $V"',
            'comment_read_count V x "$V"',
            'echo "## $V"',
        ),
        [2],
        id="reader-taint-cleared-in-order",
    ),
    pytest.param(
        _script(
            "if x; then",
            '\tV=$(jq -r .x "$F")',
            "else",
            "\tV=$(helper)",
            "fi",
            'printf \'%s\' "$V" >"$COMMENT_OUTPUT"',
        ),
        [6],
        id="unknown-command-keeps-taint",
    ),
    pytest.param(
        _script(
            "if x; then",
            '\tV=$(jq -r .x "$F")',
            "else",
            '\tcomment_read_count V label "$W"',
            "fi",
            'printf \'%s\' "$V" >"$COMMENT_OUTPUT"',
        ),
        [6],
        id="checked-in-one-branch-only",
    ),
    pytest.param(
        _script("Q='multi", "line", "quote'", 'echo "## $NAME"'),
        [4],
        id="line-numbers-after-a-multi-line-quote",
    ),
    pytest.param(
        _script(
            "f() {",
            '\tn=$(jq .x "$F") # comment-safe: a number',
            "\tprintf '%s' \"$NAME\"",
            "}",
        ),
        [3],
        id="review-covers-its-own-indented-line-only",
    ),
    pytest.param(
        _script(
            'BODY="$(comment_sanitize text --env OTHER; printf \'%s\' "$NAME")"',
            'printf \'%s\' "$BODY" >"$COMMENT_OUTPUT"',
        ),
        [2],
        id="sanitiser-then-raw-printf-in-one-substitution",
    ),
    pytest.param(
        _script(
            'X="$(printf %s "$NAME" | comment_sanitize text || echo "$NAME")"',
            'Y="$(comment_sanitize text --env A && printf %s "$NAME")"',
            'printf \'%s %s\' "$X" "$Y" >"$COMMENT_OUTPUT"',
        ),
        [3],
        id="fallback-after-or-and-and",
    ),
    pytest.param(
        _script(
            'Z="$(',
            "\tprintf '%s' \"$NAME\" | comment_sanitize text",
            "\tprintf '%s' \"$NAME\"",
            ')"',
            'printf \'%s\' "$Z" >"$COMMENT_OUTPUT"',
        ),
        [5],
        id="second-command-on-its-own-line",
    ),
    pytest.param(
        _script(
            'printf \'%s\' "$NAME" | tee "$COMMENT_OUTPUT" | comment_sanitize text',
            'printf \'%s\' "$NAME" >"$COMMENT_OUTPUT" | comment_sanitize text',
        ),
        [1, 2],
        id="copy-written-before-the-sanitiser",
    ),
    pytest.param(
        _script('X=` jq -r .x "$F" `', 'printf \'%s\' "$X" >"$COMMENT_OUTPUT"'),
        [1],
        id="backtick-substitution-with-spaces",
    ),
    pytest.param(
        _script("declare -n REF=NAME", 'echo "$REF" >>"$COMMENT_OUTPUT"'),
        [1],
        id="name-reference",
    ),
    pytest.param(
        _script("local -n REF=NAME"),
        [1],
        id="local-name-reference",
    ),
    pytest.param(
        _script("REF=NAME", 'echo "${!REF}" >>"$COMMENT_OUTPUT"'),
        [2],
        id="indirect-expansion",
    ),
    pytest.param(
        _script(
            'envsubst <tmpl >>"$COMMENT_OUTPUT"',
            'printenv NAME >>"$COMMENT_OUTPUT"',
        ),
        [1, 2],
        id="environment-expansion",
    ),
    pytest.param(
        _script('ROWS[0]="$NAME"', 'printf \'%s\' "${ROWS[0]}" >"$COMMENT_OUTPUT"'),
        [1],
        id="subscript-assignment",
    ),
]


@pytest.mark.parametrize(("script", "bad_lines"), RAW_USES)
def test_guard_catches_raw_uses(script: str, bad_lines: list[int]) -> None:
    """Each known way past the old line-based guard is reported."""
    assert_that(_lines(offences(script, ("NAME",), "bad.sh"))).is_equal_to(bad_lines)


def test_guard_accepts_reviewed_and_sanitised_uses() -> None:
    """Sanitised, tested, logged and reviewed uses pass."""
    script = (
        ': "${NAME:=x}"\nif [[ -n "$NAME" ]]; then :; fi\n'
        'safe="$(printf \'%s\' "$NAME" | comment_sanitize text)"\n'
        "printf '%s' \"$NAME\" | comment_sanitize fence\n"
        'echo "::warning::bad value"\ncase "$NAME" in a) ;; esac\n'
        '# comment-safe: numeric only\n[ "$NAME" -gt 0 ]\n'
        'n="$NAME" # comment-safe: path only\necho "$n"\n'
        "# ${NAME} in a shell comment\n"
        'comment_read_count N label "$NAME"\necho "## $N"\n'
        'printf \'%s\' "$NAME" | comment_sanitize text | tee "$COMMENT_OUTPUT"\n'
        "cat <<'EOF'\n## ${NAME} is literal in a quoted heredoc\nEOF\n"
    )
    assert_that(offences(script, ("NAME",), "ok.sh")).is_empty()


def test_scanner_keeps_quoted_strings_and_comments_apart() -> None:
    """A multi-line string is one statement and comments are kept separately."""
    found = statements('A="x\n# y" # note\nB=1; C=2\n')
    codes = [(statement.line, statement.code, statement.comment) for statement in found]
    assert_that(codes).is_equal_to(
        [(1, 'A="x\n# y"', "# note"), (3, "B=1", ""), (3, "C=2", "")],
    )


def test_file_breakdown_jq_never_interpolates_names() -> None:
    """jq builds rows from the sanitised arrays, never from raw names."""
    text = (SCRIPTS / "actions/generate-file-breakdown.sh").read_text(encoding="utf-8")
    names = (
        r"\$f\b",
        r"\.(?:filename|category|name)",
        r"\.\[0\]\.(?:category|name)",
    )
    raw_name = r"\\\(\s*(?:" + "|".join(names) + ")"
    assert_that(re.search(raw_name, text)).is_none()
    assert_that(text).contains(
        "comment_sanitize cell --json",
        "comment_sanitize cell-code --json",
    )


@pytest.mark.parametrize("relative", PYTHON_RENDERERS)
def test_python_renderer_adds_only_sanitised_values(relative: str) -> None:
    """Every value the formatter adds is sanitiser output or a constant."""
    source = (SCRIPTS / relative).read_text(encoding="utf-8")
    assert_that(python_offences(source, f"scripts/ci/{relative}")).is_empty()
    assert_that(source).contains("import comment_sanitize")


@pytest.mark.parametrize(
    ("body", "bad"),
    [
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "safe = raw",
                "sections.append(f'| {safe} |')",
            ),
            True,
            id="raw-after-safe",
        ),
        pytest.param(
            _script(
                "safe = raw",
                "safe = comment_sanitize.cell(raw)",
                "sections.append(f'| {safe} |')",
            ),
            False,
            id="safe-after-raw",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "safe = other = raw",
                "sections.append(safe)",
            ),
            True,
            id="chained-assignment-after-safe",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "safe, extra = raw, 1",
                "sections.append(safe)",
            ),
            True,
            id="unpacking-after-safe",
        ),
        pytest.param(
            _script(
                "a = b = comment_sanitize.cell(raw)",
                "sections.append(f'{a} {b} {NOTE}')",
            ),
            False,
            id="chained-safe-and-module-constant",
        ),
        pytest.param(
            _script("for safe in [raw]:", "    sections.append(safe)"),
            True,
            id="for-target",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "with open(raw) as safe:",
                "    sections.append(safe)",
            ),
            True,
            id="with-target",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "if (safe := raw):",
                "    sections.append(safe)",
            ),
            True,
            id="walrus-target",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "sections.extend([safe for safe in raw])",
            ),
            True,
            id="comprehension-target",
        ),
        pytest.param(
            _script("sections.extend([comment_sanitize.cell(r) for r in raw])"),
            False,
            id="comprehension-of-sanitised",
        ),
        pytest.param(
            _script("sections[len(sections):] = [raw]"),
            True,
            id="subscript-assignment",
        ),
        pytest.param(
            _script("sections.append(comment_sanitize.cap(raw, 10))"),
            True,
            id="helper-is-not-a-mode",
        ),
        pytest.param("sections.extend([raw])", True, id="extend"),
        pytest.param("sections.insert(0, raw)", True, id="insert"),
        pytest.param("sections += [f'{raw}']", True, id="augmented"),
        pytest.param("sections = sections + [raw]", True, id="rebinding"),
        pytest.param("sections.append(str(_count(raw)))", True, id="unknown-call"),
        pytest.param(
            _script("n = _count(raw)", "sections.append(f'{n} found')"),
            False,
            id="count",
        ),
    ],
)
def test_python_guard_catches_raw_values(body: str, bad: bool) -> None:
    """The Python analysis is order-sensitive and covers every way to add a section."""
    indented = "\n".join("    " + line for line in body.splitlines())
    source = f"NOTE = 'constant'\n\ndef build(raw, sections):\n{indented}\n"
    assert_that(bool(python_offences(source, "fake.py"))).is_equal_to(bad)


def test_python_guard_does_not_trust_an_argument_shadowing_a_constant() -> None:
    """A parameter named like a module constant holds the caller's value."""
    body = "    sections.append(NOTE)\n"
    for signature in ("def build(NOTE, sections):", "def build(sections, *, NOTE):"):
        source = f"NOTE = 'constant'\n\n{signature}\n{body}"
        assert_that(python_offences(source, "fake.py")).is_not_empty()


def test_every_renderer_like_file_is_classified() -> None:
    """A new comment renderer must be listed, with its untrusted inputs."""
    known = set(RENDERERS) | set(PYTHON_RENDERERS) | set(NOT_RENDERERS)
    found = set()
    for path in SCRIPTS.rglob("*"):
        pattern = {".sh": LOOKS_LIKE_RENDERER_SH, ".py": LOOKS_LIKE_RENDERER_PY}.get(
            path.suffix,
        )
        if pattern and pattern.search(path.read_text(encoding="utf-8")):
            found.add(path.relative_to(SCRIPTS).as_posix())
    assert_that(sorted(found - known)).is_empty()
    missing = sorted(name for name in known if not (SCRIPTS / name).is_file())
    assert_that(missing).is_empty()
