# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/lib/comment_fields.py`` (#1677).

Every rule has a case with its stable message; the multi-environment example
is rendered in each of the three styles exactly; hostile labels and values
never leave a raw ``<``, a live mention, reference or link, a hidden
character or the reserved marker in any style; limits turn into notes or one
whole-input note, never an error; the log carries line numbers and lgtm-ci's
own text only; the history stamp round-trips and is re-sanitised.
"""

from __future__ import annotations

import base64
import html
import json
import os
import re
import subprocess
import sys
import unicodedata
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci/lib/comment_fields.py"
RUN_URL = "https://github.com/o/r/actions/runs/42"
RUN_LINK = f"([job log]({RUN_URL}))"
NOTE = "> ⚠️ `comment-fields`"
MARKER = "<!-- lgtm-ci:"
EXAMPLE_LINES = (
    "Environment: staging",
    "Environment URL: https://staging.example.com",
    "Region: eu-west-1",
)
EXAMPLE = "".join(line + "\n" for line in EXAMPLE_LINES)
STYLES = ("block", "compact", "table")
INVISIBLE = "the line contains a control or invisible character"
HOSTILE = [
    "@org/team",
    "#1",
    "<img src=x>",
    "[x](javascript:y)",
    "<!-- lgtm-ci:history:start -->",
    "<!-- lgtm-ci:history:latest sha=a run=9 attempt=1 number=9 at=t -->",
    "\\[a](https://ok.example)@other.example",
    "\\https://evil.example",
    "www.evil.example and o/r#4 GH-5",
    "</details><details><summary>x",
    "`code` | pipe || \\| *b* _i_ $x$",
    "&lt;b&gt; &#64;org",
]


@pytest.fixture(name="fields", scope="module")
def fixture_fields(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the module by path."""
    return load_script("scripts/ci/lib/comment_fields.py")


def _render(fields: ModuleType, raw: str | bytes, style: str = "block") -> str:
    """Parse and render ``raw`` with the run link."""
    return str(fields.render(fields.parse(raw), style, RUN_URL))


def _hidden(value: str) -> list[str]:
    """List control and invisible characters other than the newline."""
    hidden = {"Cc", "Cf", "Cs"}
    return [c for c in value if c != "\n" and unicodedata.category(c) in hidden]


def _assert_inert_html(out: str) -> None:
    """Inert in a raw-HTML line: no tag, marker, live mention, reference or URL."""
    assert_that(out).does_not_contain("<", MARKER)
    assert_that(_hidden(out)).is_empty()
    shown = html.unescape(out)
    assert_that(re.search(r"@[A-Za-z0-9_.+-]", shown)).is_none()
    assert_that(re.search(r"#[0-9]", shown)).is_none()
    assert_that(re.search(r"[A-Za-z]://", shown)).is_none()
    assert_that(re.search(r"(?i)/(?:issues|pulls?|discussions)/[0-9]", shown)).is_none()


def _assert_inert(out: str) -> None:
    """No raw HTML, marker, hidden character or live mention, reference or link."""
    assert_that(out).does_not_contain(MARKER)
    assert_that(_hidden(out)).is_empty()
    # The only links are [host](https://host...) and the run link.
    links = re.findall(r"(?<!\\)\[([^\]\\]*)\]\(([^)]*)\)", out)
    for text, target in links:
        assert_that(target).starts_with("https://")
        assert_that(text in {"job log", target.split("/")[2]}).is_true()
    without_links = re.sub(r"\[[^\]]*\]\(https://[^)]*\)", "", out)
    # A code span is inert: GitHub links nothing inside one.
    without_links = re.sub(r"(?<!\\)(`+)[^`].*?(?<!`)\1(?!`)", "", without_links)
    raw_html = re.search(r"<(?!/?(?:details|summary)>)[A-Za-z!/?]", without_links)
    assert_that(raw_html).is_none()
    shown = html.unescape(without_links)
    assert_that(re.search(r"(?i)/(?:issues|pulls?|discussions)/[0-9]", shown)).is_none()
    assert_that(re.search(r"@[A-Za-z0-9_.+-]", shown)).is_none()
    assert_that(re.search(r"#[0-9]", shown)).is_none()
    assert_that(re.search(r"[A-Za-z]://", shown)).is_none()
    assert_that(re.search(r"(?i)(?<![A-Za-z0-9])www\.", shown)).is_none()


# =============================================================================
# Rules and messages
# =============================================================================

RULES = [
    ("Environment staging", "no-colon", "no colon found"),
    (": staging", "empty-label", "nothing before the colon"),
    ("  \t: staging", "empty-label", "nothing before the colon"),
    ("Environment:", "empty-value", "nothing after the colon"),
    ("Environment:   \t", "empty-value", "nothing after the colon"),
    ("L" * 65 + ": x", "label-too-long", "the label is longer than 64 characters"),
    (
        "Label: " + "v" * 513,
        "value-too-long",
        "the value is longer than 512 characters",
    ),
    ("URL: http://staging.example.com", "not-https", "links must start with https://"),
    ("URL: ftp://staging.example.com", "not-https", "links must start with https://"),
    ("URL: javascript:alert(1)", "not-https", "links must start with https://"),
    ("URL: data:text/html,x", "not-https", "links must start with https://"),
    ("https://staging.example.com", "no-label", "a link needs a label before it"),
    (
        "URL: https://user@staging.example.com",
        "unsafe-link",
        "a link must be a whole https:// address with a plain host name",
    ),
    (
        "URL: https://staging.example.com (primary)",
        "unsafe-link",
        "a link must be a whole https:// address with a plain host name",
    ),
    (
        "URL: https://xn--e1afmkfd.example/",
        "unsafe-link",
        "a link must be a whole https:// address with a plain host name",
    ),
    (
        "Env: a\x00b",
        "invisible",
        INVISIBLE,
    ),
    (
        "Env: prod\u202egnits",
        "invisible",
        INVISIBLE,
    ),
    ("Env: a\u200bb", "invisible", INVISIBLE),
    ("Env: a\u2028b", "invisible", INVISIBLE),
]


@pytest.mark.parametrize(("line", "code", "message"), RULES)
def test_each_rule_gives_its_note(
    fields: ModuleType,
    line: str,
    code: str,
    message: str,
) -> None:
    """A bad line is one note with the rule's stable message, on its line number."""
    parsed = fields.parse(f"Region: eu-west-1\n{line}\n")

    assert_that(parsed.fields).is_length(1)
    assert_that(parsed.notes).is_length(1)
    note = parsed.notes[0]
    assert_that((note.line, note.code, note.reason)).is_equal_to((2, code, message))
    assert_that(fields.REASONS[code][0]).is_equal_to(message)


def test_every_reason_has_a_case(fields: ModuleType) -> None:
    """The rule table above covers every line reason but the counted ones."""
    covered = {code for _, code, _ in RULES} | {"duplicate", "too-many"}
    assert_that(covered).is_equal_to(set(fields.REASONS))


def test_duplicate_label_names_the_first_line(fields: ModuleType) -> None:
    """Labels compare case-insensitively; the later line gets the note."""
    parsed = fields.parse("Region: eu-west-1\n\nregion: us-east-1\n")

    assert_that([f.value for f in parsed.fields]).is_equal_to(["eu-west-1"])
    reason = parsed.notes[0].reason
    assert_that(reason).is_equal_to("this label is already used on line 1")
    assert_that(parsed.notes[0].line).is_equal_to(3)


def test_blank_and_comment_lines_are_skipped(fields: ModuleType) -> None:
    """Blank lines, whitespace-only lines and # lines are neither fields nor notes."""
    parsed = fields.parse("\n   \n\t\n# a comment\n  # indented: comment\n")

    assert_that(parsed.empty).is_true()
    assert_that(fields.render(parsed, "block", RUN_URL)).is_equal_to("")
    assert_that(fields.log_lines(parsed)).is_empty()
    assert_that(fields.history_stamp(parsed)).is_equal_to("")


def test_first_colon_splits_and_spaces_are_trimmed(fields: ModuleType) -> None:
    """The label ends at the first colon; a value keeps its own colons."""
    parsed = fields.parse("  \tStarted :  12:30:05 UTC \t\n")

    field = parsed.fields[0]
    assert_that((field.label, field.value, field.link)).is_equal_to(
        ("Started", "12:30:05 UTC", False),
    )


def test_crlf_and_lone_cr_are_line_breaks(fields: ModuleType) -> None:
    """CR, as GitHub renders it, ends a line; numbering follows."""
    parsed = fields.parse("A: 1\r\nB: 2\rbad\r\nC: 3")

    assert_that([f.label for f in parsed.fields]).is_equal_to(["A", "B", "C"])
    assert_that(parsed.notes[0].line).is_equal_to(3)


def test_field_limit_turns_extra_lines_into_notes(fields: ModuleType) -> None:
    """At most 20 fields; each later valid line gets the too-many note."""
    raw = "".join(f"F{i}: v{i}\n" for i in range(25))
    parsed = fields.parse(raw)

    assert_that(parsed.fields).is_length(20)
    assert_that([n.line for n in parsed.notes]).is_equal_to([21, 22, 23, 24, 25])
    assert_that({n.code for n in parsed.notes}).is_equal_to({"too-many"})


def test_limits_hold_at_the_boundary(fields: ModuleType) -> None:
    """64-character labels and 512-character values are accepted."""
    parsed = fields.parse("L" * 64 + ": " + "v" * 512)

    assert_that(parsed.notes).is_empty()
    assert_that(parsed.fields).is_length(1)


@pytest.mark.parametrize(
    ("raw", "problem", "message"),
    [
        ("A: " + "x" * 100_000, "too-large", "the input is larger than 8192 bytes"),
        ("A: b\n" * 10_000, "too-large", "the input is larger than 8192 bytes"),
        ("\n" * 10_000, "too-large", "the input is larger than 8192 bytes"),
        (b"A: \xff\xfe", "not-utf8", "the input is not valid UTF-8 text"),
    ],
)
def test_unreadable_input_is_one_note(
    fields: ModuleType,
    raw: str | bytes,
    problem: str,
    message: str,
) -> None:
    """An input over the limit or not UTF-8 gives one note and the run link."""
    parsed = fields.parse(raw)

    assert_that(parsed.problem).is_equal_to(problem)
    assert_that(_render(fields, raw)).is_equal_to(
        f"> ⚠️ `comment-fields` could not be read: {message} {RUN_LINK}",
    )
    log = fields.log_lines(parsed)
    assert_that([line for line in log if line.startswith("::warning")]).is_length(1)
    assert_that(log[-1]).contains(message)


def test_size_limit_is_in_bytes(fields: ModuleType) -> None:
    """Exactly 8192 bytes is read; one more byte is not."""
    fitting = "A: " + "é" * ((8192 - 3) // 2) + "x" * ((8192 - 3) % 2)
    assert_that(len(fitting.encode())).is_equal_to(8192)
    assert_that(fields.parse(fitting).problem).is_equal_to("")
    assert_that(fields.parse(fitting + "x").problem).is_equal_to("too-large")


# =============================================================================
# Rendering
# =============================================================================


def test_multi_environment_example_block(fields: ModuleType) -> None:
    """The classic block, as drawn in the #1678 mock-up."""
    assert_that(_render(fields, EXAMPLE)).is_equal_to(
        "> **Environment:** staging\n"
        "> **Environment URL:** [staging.example.com](https://staging.example.com)\n"
        "> **Region:** eu-west-1",
    )


def test_multi_environment_example_compact(fields: ModuleType) -> None:
    """The compact line keeps every label (none drops information)."""
    assert_that(_render(fields, EXAMPLE, "compact")).is_equal_to(
        "**Environment:** staging · "
        "**Environment URL:** [staging.example.com](https://staging.example.com) · "
        "**Region:** eu-west-1",
    )


def test_multi_environment_example_table(fields: ModuleType) -> None:
    """The table, labels as the header row."""
    assert_that(_render(fields, EXAMPLE, "table")).is_equal_to(
        "| Environment | Environment URL | Region |\n"
        "|---|---|---|\n"
        "| staging | [staging.example.com](https://staging.example.com) | eu-west-1 |",
    )


def test_notes_sit_in_place_of_the_bad_line_in_every_style(fields: ModuleType) -> None:
    """Each style shows the note where the field would have been."""
    raw = "Environment: staging\nbad line\nRegion: eu-west-1\n"
    note = f"⚠️ `comment-fields` line 2: no colon found {RUN_LINK}"

    assert_that(_render(fields, raw)).is_equal_to(
        f"> **Environment:** staging\n> {note}\n> **Region:** eu-west-1",
    )
    assert_that(_render(fields, raw, "compact")).is_equal_to(
        f"**Environment:** staging · {note} · **Region:** eu-west-1",
    )
    assert_that(_render(fields, raw, "table")).is_equal_to(
        "| Environment | ⚠️ `comment-fields` line 2 | Region |\n"
        "|---|---|---|\n"
        f"| staging | no colon found {RUN_LINK} | eu-west-1 |",
    )


def test_link_note_renders_the_scheme_inert(fields: ModuleType) -> None:
    """The not-https message shows https:// as text that GitHub does not link."""
    out = _render(fields, "URL: http://x.example")

    assert_that(out).is_equal_to(
        f"{NOTE} line 1: links must start with https&#8203;:// {RUN_LINK}",
    )


def test_notes_without_a_run_url_have_no_link(fields: ModuleType) -> None:
    """No run URL, or an unsafe one, leaves the note without a link."""
    for run_url in ("", "javascript:alert(1)", "http://x.example/runs/1"):
        out = fields.render(fields.parse("bad"), "block", run_url)
        assert_that(out).is_equal_to("> ⚠️ `comment-fields` line 1: no colon found")


def test_notes_beyond_the_cap_are_counted(fields: ModuleType) -> None:
    """Ten notes are shown in place; the rest are one closing note."""
    raw = "".join(f"bad {i}\n" for i in range(15))
    for style in STYLES:
        out = _render(fields, raw, style)
        assert_that(out.count("no colon found")).is_equal_to(10)
        assert_that(out).contains("5 more lines not shown")


@pytest.mark.parametrize("style", STYLES)
@pytest.mark.parametrize("value", HOSTILE)
def test_hostile_values_are_inert(fields: ModuleType, style: str, value: str) -> None:
    """A hostile value cannot mention, link, embed HTML or forge a marker."""
    out = _render(fields, f"Label: {value}\n", style)

    assert_that(out).is_not_empty()
    _assert_inert(out)
    newlines = {"block": 0, "compact": 0, "table": 2}[style]
    assert_that(out.count("\n")).is_equal_to(newlines)


@pytest.mark.parametrize("style", STYLES)
@pytest.mark.parametrize("label", HOSTILE)
def test_hostile_labels_are_inert(fields: ModuleType, style: str, label: str) -> None:
    """A hostile label is as inert as a value; it is split at its first colon."""
    out = _render(fields, f"{label}: value\n", style)

    _assert_inert(out)


@pytest.mark.parametrize("style", STYLES)
def test_hidden_characters_never_reach_the_comment(
    fields: ModuleType,
    style: str,
) -> None:
    """CR splits lines; NUL, bidi and zero-width lines become notes."""
    raw = "A: x\rB: y\x00z\nC: \u202eevil\nD: a\u200bb\nE: \u2066x\u2069\n"
    out = _render(fields, raw, style)

    _assert_inert(out)
    assert_that(out.count("control or invisible character")).is_equal_to(4)


def test_rendering_is_deterministic_and_idempotent(fields: ModuleType) -> None:
    """The same input renders the same; rendered text fed back stays inert."""
    raw = EXAMPLE + "".join(f"H{i}: {value}\n" for i, value in enumerate(HOSTILE))
    for style in STYLES:
        first = _render(fields, raw, style)
        assert_that(_render(fields, raw, style)).is_equal_to(first)
        fed_back = "".join(f"R: {line}\n" for line in first.splitlines())
        again = _render(fields, fed_back, style)
        _assert_inert(again)


# =============================================================================
# Log lines
# =============================================================================


def test_log_names_lines_reasons_and_examples_only(fields: ModuleType) -> None:
    """Each problem is logged with its line and an example; one warning; no input."""
    secret = "::error::pwned"
    raw = f"Environment: staging\n{secret}\nURL: http://x\nRegion: eu-west-1\n"
    lines = fields.log_lines(fields.parse(raw))

    assert_that(lines[0]).is_equal_to("comment-fields: 2 fields shown.")
    assert_that(lines).contains(
        "comment-fields: line 2: nothing before the colon. "
        'A correct line looks like "Environment: staging".',
        "comment-fields: line 3: links must start with https://. "
        "A correct line looks like "
        '"Environment URL: https://staging.example.com".',
    )
    warnings = [line for line in lines if line.startswith("::")]
    assert_that(warnings).is_equal_to(
        [
            "::warning title=comment-fields::2 comment-fields lines not shown "
            "(lines 2, 3); "
            "the job log lists each reason",
        ],
    )
    assert_that("\n".join(lines)).does_not_contain("pwned", "x.example", "staging\n")


def test_log_is_capped(fields: ModuleType) -> None:
    """At most 50 problems are listed; the warning lists ten line numbers."""
    lines = fields.log_lines(fields.parse("bad\n" * 60))

    assert_that([line for line in lines if "no colon found" in line]).is_length(50)
    assert_that(lines).contains("comment-fields: 10 more lines not listed.")
    assert_that(lines[-1]).contains("(lines 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, …)")


def test_clean_input_logs_one_line_and_no_warning(fields: ModuleType) -> None:
    """Valid input logs the count only."""
    assert_that(fields.log_lines(fields.parse(EXAMPLE))).is_equal_to(
        ["comment-fields: 3 fields shown."],
    )


# =============================================================================
# History stamp
# =============================================================================


def test_history_stamp_round_trips(fields: ModuleType) -> None:
    """The stamp is base64 of the fields; a link keeps only its host."""
    parsed = fields.parse(EXAMPLE + "bad\n")
    stamp = fields.history_stamp(parsed)

    assert_that(re.fullmatch(r"[A-Za-z0-9+/=]+", stamp)).is_not_none()
    assert_that(fields.history_text(stamp)).is_equal_to(
        "Environment: staging · Environment URL: staging.example.com · "
        "Region: eu-west-1 · ⚠️ 1 field line not shown",
    )


def test_history_stamp_of_unreadable_input(fields: ModuleType) -> None:
    """An unreadable input is remembered as such."""
    stamp = fields.history_stamp(fields.parse("x" * 9000))

    assert_that(fields.history_text(stamp)).is_equal_to("⚠️ fields unreadable")


def test_history_line_is_cut_and_sanitised(fields: ModuleType) -> None:
    """Long values are cut; hostile ones are as inert as in the comment."""
    hostile = "".join(f"H{i}: {v}\n" for i, v in enumerate(HOSTILE))
    raw = "Long: " + "v" * 200 + "\n" + hostile
    text = fields.history_text(fields.history_stamp(fields.parse(raw)))

    assert_that(text).contains("Long: " + "v" * 59 + "…")
    _assert_inert_html(text)
    assert_that(text).does_not_contain("\n")


@pytest.mark.parametrize(
    "stamp",
    [
        "",
        "not base64!",
        base64.b64encode(b"not json").decode(),
        base64.b64encode(b'{"v":2,"f":[],"n":0,"u":0}').decode(),
        base64.b64encode(b'{"v":1,"f":[["a"]],"n":0,"u":0}').decode(),
        base64.b64encode(b'{"v":1,"f":[["a",1]],"n":0,"u":0}').decode(),
        base64.b64encode(b'{"v":1,"f":[],"n":"x","u":0}').decode(),
        base64.b64encode(b"[]").decode(),
    ],
)
def test_history_text_ignores_foreign_stamps(fields: ModuleType, stamp: str) -> None:
    """A stamp this module did not write renders nothing."""
    assert_that(fields.history_text(stamp)).is_equal_to("")


def test_history_text_resanitises_a_tampered_stamp(fields: ModuleType) -> None:
    """Decoded labels and values go through the sanitiser again."""
    pairs = [["@org", "<!-- lgtm-ci:x --> https://e.example"]]
    data = {"v": 1, "f": pairs, "n": 0, "u": 0}
    stamp = base64.b64encode(json.dumps(data).encode()).decode()

    _assert_inert_html(fields.history_text(stamp))


# =============================================================================
# Command line
# =============================================================================


def _cli(
    *args: str, env: dict[str, str] | None = None, stdin: bytes = b""
) -> subprocess.CompletedProcess[bytes]:
    """Run the module as ``python3 -I -S``."""
    return subprocess.run(
        [sys.executable, "-I", "-S", str(SCRIPT), *args],
        input=stdin,
        env={"PATH": os.environ.get("PATH", ""), **(env or {})},
        capture_output=True,
        check=False,
    )


def test_cli_render_writes_block_stamp_and_log(tmp_path: Path) -> None:
    """render: block and stamp to files, log on stdout, exit 0 on bad input."""
    out, stamp = tmp_path / "block", tmp_path / "stamp"
    result = _cli(
        "render",
        "--env",
        "F",
        "--style",
        "block",
        "--out",
        str(out),
        "--stamp",
        str(stamp),
        env={"F": EXAMPLE + "oops\n", "COMMENT_FIELDS_RUN_URL": RUN_URL},
    )

    assert_that(result.returncode).is_equal_to(0)
    assert_that(out.read_text(encoding="utf-8")).ends_with(
        f"> ⚠️ `comment-fields` line 4: no colon found {RUN_LINK}",
    )
    assert_that(stamp.read_text(encoding="ascii")).is_not_empty()
    log = result.stdout.decode()
    assert_that(log).contains("comment-fields: line 4: no colon found.")
    assert_that(log.count("::warning")).is_equal_to(1)


def test_cli_render_reads_stdin_and_writes_stdout() -> None:
    """Without --env and --out the input is stdin and the block is stdout."""
    result = _cli("render", "--style", "compact", stdin=b"A: 1\nB: 2\n")

    assert_that(result.returncode).is_equal_to(0)
    assert_that(result.stdout.decode()).is_equal_to("**A:** 1 · **B:** 2")
    assert_that(result.stderr.decode()).contains("2 fields shown")


def test_cli_empty_input_writes_nothing(tmp_path: Path) -> None:
    """An unset variable writes an empty block and stamp and logs nothing."""
    out, stamp = tmp_path / "block", tmp_path / "stamp"
    result = _cli("render", "--env", "UNSET", "--out", str(out), "--stamp", str(stamp))

    assert_that(result.returncode).is_equal_to(0)
    assert_that(out.read_bytes()).is_equal_to(b"")
    assert_that(stamp.read_bytes()).is_equal_to(b"")
    assert_that(result.stdout).is_equal_to(b"")


def test_cli_history_prints_the_line(fields: ModuleType) -> None:
    """history: the compact line, no trailing newline."""
    stamp = fields.history_stamp(fields.parse("Region: eu-west-1"))
    result = _cli("history", "--env", "S", env={"S": stamp})

    assert_that(result.stdout.decode()).is_equal_to("Region: eu-west-1")


@pytest.mark.parametrize(
    "args",
    [
        [],
        ["parse"],
        ["render", "--style", "fancy"],
        ["render", "--env"],
        ["render", "--env", "A", "--env", "B"],
        ["history", "--style", "block"],
        ["render", "--max", "3"],
    ],
)
def test_cli_usage_errors_exit_2(args: list[str]) -> None:
    """A bad command line exits 2 with the usage."""
    result = _cli(*args)

    assert_that(result.returncode).is_equal_to(2)
    assert_that(result.stderr.decode()).starts_with("usage:")
