# SPDX-License-Identifier: MIT
"""Review fixes for ``comment-fields`` (#1677, pull request #1703).

The rendered block stays within its size budget in every style; links to
GitHub hosts are shown as inert code, never as links; every character that
renders as nothing or as a space other than U+0020 is refused; labels that
look the same once displayed are duplicates; a value starting with ``//`` is
plain text while a line that is only a URL is not; history lines are written
for raw HTML; and an internal error never fails the step.
"""

from __future__ import annotations

import base64
import html
import io
import json
import re
import sys
import unicodedata
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

RUN_URL = "https://github.com/o/r/actions/runs/42"
STYLES = ("block", "compact", "table")
INVISIBLE = "the line contains a control or invisible character"
#: Opus's worst case: 20 fields whose escaping is 4-5 times the input.
OPUS = "".join(f"L{i:02d}" + "<" * 57 + ": " + "#1" * 170 + "\n" for i in range(20))
#: Sol's case: 15 fields of 512 ``<``.
SOL = "\n".join(f"F{i}: " + "<" * 512 for i in range(15))
#: Harmless text that still adds up.
PLAIN = "".join(f"F{i}: " + "v" * 380 + "\n" for i in range(20))


@pytest.fixture(name="fields", scope="module")
def fixture_fields(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the renderer module by path."""
    return load_script("scripts/ci/lib/comment_fields.py")


def _render(fields: ModuleType, raw: str, style: str = "block") -> str:
    """Parse and render ``raw`` with the run link."""
    return str(fields.render(fields.parse(raw), style, RUN_URL))


# =============================================================================
# Size budget
# =============================================================================


@pytest.mark.parametrize("style", STYLES)
@pytest.mark.parametrize("raw", [OPUS, SOL, PLAIN], ids=["opus", "sol", "plain"])
def test_block_stays_within_budget(fields: ModuleType, style: str, raw: str) -> None:
    """However the input escapes, the block is at most BLOCK_BUDGET characters."""
    out = _render(fields, raw, style)

    assert_that(len(out)).is_less_than_or_equal_to(fields.BLOCK_BUDGET)
    assert_that(out).contains("more fields not shown (size limit)")
    assert_that(out).contains("L00" if raw is OPUS else "F0")


def test_budget_note_counts_what_was_left_out(fields: ModuleType) -> None:
    """The closing note counts every field the budget left out."""
    out = _render(fields, PLAIN)

    shown = out.count("> **F")
    assert_that(out.splitlines()[-1]).is_equal_to(
        f"> ⚠️ `comment-fields`: {20 - shown} more fields not shown (size limit) "
        f"([job log]({RUN_URL}))",
    )


def test_ordinary_input_is_not_cut(fields: ModuleType) -> None:
    """Twenty short fields fit with room to spare."""
    raw = "".join(f"Field {i}: value {i}\n" for i in range(20))

    assert_that(_render(fields, raw)).does_not_contain("size limit")


def test_stamp_is_bounded_and_counts_dropped_fields(fields: ModuleType) -> None:
    """The fields= stamp stays under its cap; dropped fields show as +N more."""
    wide = [chr(0x4E00 + i) for i in range(20)]
    raw = "".join(f"{char * 30}: {char * 60}\n" for char in wide)
    stamp = fields.history_stamp(fields.parse(raw))

    assert_that(len(stamp)).is_less_than_or_equal_to(1024)
    assert_that(fields.history_text(stamp)).matches(r"\+[0-9]+ more")


# =============================================================================
# GitHub hosts
# =============================================================================


@pytest.mark.parametrize(
    "value",
    [
        "https://github.com/o/r/issues/1",
        "https://github.com/o/r/pull/2",
        "https://github.com/o/r/discussions/3",
        "https://github.com/o/r/commit/0123456789abcdef",
        "https://gist.github.com/o/1",
        "https://o.github.io/r/",
    ],
)
@pytest.mark.parametrize("style", STYLES)
def test_github_links_are_inert_code(
    fields: ModuleType,
    style: str,
    value: str,
) -> None:
    """A link to a GitHub host is shown as code: readable, never a link."""
    parsed = fields.parse(f"Ticket: {value}")
    out = fields.render(parsed, style, "")

    assert_that(parsed.notes).is_empty()
    assert_that(out).contains(f"`{value}`")
    assert_that(out).does_not_contain("](")


def test_github_links_are_named_in_the_log(fields: ModuleType) -> None:
    """The job log says why the value is not a link; no warning is raised."""
    lines = fields.log_lines(fields.parse("A: x\nTicket: https://github.com/o/r/issues/1"))

    assert_that(lines).contains(
        "comment-fields: line 2: a link to GitHub is shown as text, not as a link, "
        "so it creates no cross-reference.",
    )
    assert_that([line for line in lines if line.startswith("::")]).is_empty()


def test_github_path_in_plain_text_is_broken(fields: ModuleType) -> None:
    """A GitHub path without https:// cannot become a reference either."""
    out = _render(fields, "See: github.com/o/r/issues/12 and o/r/pull/3")

    assert_that(out).contains("/issues/&#8203;12", "/pull/&#8203;3")


def test_link_text_keeps_a_non_default_port(fields: ModuleType) -> None:
    """The visible host of a link shows a port other than 443."""
    out = _render(fields, "Preview: https://staging.example.com:8443/app")

    assert_that(out).is_equal_to(
        "> **Preview:** [staging.example.com:8443](https://staging.example.com:8443/app)",
    )


# =============================================================================
# Invisible and look-alike characters
# =============================================================================

INVISIBLE_POINTS = [
    0x034F,  # combining grapheme joiner
    0xFE0F,  # variation selector 16
    0xE0100,  # variation selector 17
    0xE0041,  # tag latin capital A
    0x180B,  # Mongolian free variation selector
    0x00A0,  # no-break space
    0x2002,  # en space
    0x2009,  # thin space
    0x202F,  # narrow no-break space
    0x205F,  # medium mathematical space
    0x3000,  # ideographic space
    0x2800,  # braille blank
    0x115F,  # Hangul choseong filler
    0x1160,  # Hangul jungseong filler
    0x3164,  # Hangul filler
    0xFFA0,  # halfwidth Hangul filler
    0x0378,  # unassigned
    0xE000,  # private use
    0x2028,  # line separator
    0x200B,  # zero-width space
]


POINT_IDS = [f"U+{point:04X}" for point in INVISIBLE_POINTS]


@pytest.mark.parametrize("point", INVISIBLE_POINTS, ids=POINT_IDS)
@pytest.mark.parametrize("where", ["label", "value"])
def test_invisible_characters_are_refused(
    fields: ModuleType,
    point: int,
    where: str,
) -> None:
    """Anything that renders as nothing or a blank gets the invisible-character note."""
    line = f"Env{chr(point)}: x" if where == "label" else f"Env: a{chr(point)}b"
    parsed = fields.parse(f"Region: eu\n{line}")

    assert_that([n.reason for n in parsed.notes]).is_equal_to([INVISIBLE])
    assert_that(parsed.fields).is_length(1)


def test_unpaired_surrogate_is_unreadable(fields: ModuleType) -> None:
    """Text holding an unpaired surrogate is not UTF-8."""
    parsed = fields.parse("A: " + chr(0xD800))

    assert_that(parsed.problem).is_equal_to("not-utf8")


def test_a_tab_inside_is_still_allowed(fields: ModuleType) -> None:
    """A tab is shown as a space; it is not an invisible character."""
    parsed = fields.parse("Build\tTarget: x")

    assert_that(parsed.notes).is_empty()


@pytest.mark.parametrize(
    "pair",
    [
        (unicodedata.normalize("NFC", "Cafe" + chr(0x301)), "Cafe" + chr(0x301)),
        ("Environment Name", "Environment\tName"),
        ("Environment Name", "Environment   Name"),
        ("Env", chr(0xFF25) + "nv"),
        ("REGION", "region"),
    ],
    ids=["nfc-nfd", "tab", "spaces", "fullwidth", "case"],
)
def test_labels_that_look_alike_are_duplicates(
    fields: ModuleType,
    pair: tuple[str, str],
) -> None:
    """Labels are compared as displayed: spaces collapsed, NFKC, case folded."""
    parsed = fields.parse(f"{pair[0]}: a\n{pair[1]}: b")

    assert_that(parsed.fields).is_length(1)
    reason = parsed.notes[0].reason
    assert_that(reason).is_equal_to("this label is already used on line 1")


# =============================================================================
# Values starting with //, lines that are only a URL
# =============================================================================


@pytest.mark.parametrize("line", ["Target: //app:test", "Path: //server/share"])
def test_double_slash_values_are_text(fields: ModuleType, line: str) -> None:
    """A labelled value that starts with // is an ordinary value."""
    parsed = fields.parse(line)

    assert_that(parsed.notes).is_empty()
    assert_that(parsed.fields[0].value).starts_with("//")


@pytest.mark.parametrize("line", ["https://x", "http://x", "ftp://x"])
def test_a_line_that_is_only_a_url_needs_a_label(fields: ModuleType, line: str) -> None:
    """A whole line that is a URL gets the no-label note, whatever its scheme."""
    parsed = fields.parse(line)

    assert_that([n.reason for n in parsed.notes]).is_equal_to(
        ["a link needs a label before it"],
    )


# =============================================================================
# History lines are raw HTML
# =============================================================================


def test_history_line_has_no_markdown_escapes(fields: ModuleType) -> None:
    """Inside <summary> nothing is backslash-escaped, and nothing is live."""
    stamp = fields.history_stamp(fields.parse("Build: a*b_c\nIssue: #12\nOwner: @me"))
    text = fields.history_text(stamp)

    assert_that(text).is_equal_to(
        "Build: a*b_c · Issue: #&#8203;12 · Owner: @&#8203;me",
    )
    assert_that(html.unescape(text)).does_not_contain("\\")


def test_deeply_nested_stamp_has_no_fields(fields: ModuleType) -> None:
    """Deeply nested or oversized stamps are treated as no fields."""
    deep = '{"v":1,"f":' + "[" * 1400 + "]" * 1400 + ',"n":0,"u":0}'
    stamp = base64.b64encode(deep.encode()).decode()
    assert_that(len(stamp)).is_less_than_or_equal_to(4096)
    too_long = base64.b64encode(json.dumps({"v": 1, "pad": "x" * 4000}).encode())

    assert_that(fields.history_text(stamp)).is_equal_to("")
    assert_that(fields.history_text(too_long.decode())).is_equal_to("")


def test_recursion_error_is_caught(
    fields: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A RecursionError while decoding gives no fields, not a crash."""
    history = sys.modules["comment_fields_history"]

    def explode(_: str) -> object:
        """Stand in for json.loads on a stamp nested too deep."""
        raise RecursionError

    monkeypatch.setattr(history.json, "loads", explode)
    stamp = base64.b64encode(b'{"v":1}').decode()

    assert_that(fields.history_text(stamp)).is_equal_to("")


# =============================================================================
# Internal errors never fail the step
# =============================================================================


def _boom(_: object) -> object:
    """Stand in for a parser that crashes."""
    raise RuntimeError("boom")


def _capture(monkeypatch: pytest.MonkeyPatch) -> tuple[io.BytesIO, io.BytesIO]:
    """Swap stdout and stderr for byte buffers; return them."""
    out, err = io.BytesIO(), io.BytesIO()
    monkeypatch.setattr(sys, "stdout", io.TextIOWrapper(out))
    monkeypatch.setattr(sys, "stderr", io.TextIOWrapper(err))
    return out, err


def test_parser_crash_writes_the_internal_note(
    fields: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """A crash still exits 0 with the fixed note, an unreadable stamp and a warning."""
    monkeypatch.setattr(fields, "parse", _boom)
    monkeypatch.setenv("F", "A: b")
    monkeypatch.setenv("COMMENT_FIELDS_RUN_URL", RUN_URL)
    out, _ = _capture(monkeypatch)
    block, stamp = tmp_path / "block", tmp_path / "stamp"

    args = ["render", "--env", "F", "--out", str(block), "--stamp", str(stamp)]
    status = fields.main(args)
    sys.stdout.flush()

    assert_that(status).is_equal_to(0)
    assert_that(block.read_text(encoding="utf-8")).is_equal_to(
        "> ⚠️ `comment-fields` could not be read: internal error, see the job log "
        f"([job log]({RUN_URL}))",
    )
    history = fields.history_text(stamp.read_text())
    assert_that(history).is_equal_to("⚠️ fields unreadable")
    log = out.getvalue().decode()
    assert_that(re.findall(r"^::warning", log, re.M)).is_length(1)


def test_unwritable_output_still_exits_zero(
    fields: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """When even the note cannot be written, the warning goes to stderr; exit 0."""
    monkeypatch.setenv("F", "A: b")
    _, err = _capture(monkeypatch)

    status = fields.main(["render", "--env", "F", "--out", str(tmp_path)])
    sys.stderr.flush()

    assert_that(status).is_equal_to(0)
    assert_that(err.getvalue().decode()).contains("::warning title=comment-fields::")


def test_history_crash_prints_nothing(
    fields: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The history command fails soft too: no line, exit 0."""
    monkeypatch.setattr(fields, "history_text", _boom)
    monkeypatch.setenv("S", "eyJ2IjoxfQ==")
    out, _ = _capture(monkeypatch)

    status = fields.main(["history", "--env", "S"])
    sys.stdout.flush()

    assert_that(status).is_equal_to(0)
    assert_that(out.getvalue()).is_equal_to(b"")
