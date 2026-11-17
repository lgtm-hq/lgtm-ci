# SPDX-License-Identifier: MIT
"""Line-editing tests for ``scripts/ci/security/remove_stale_suppressions.py``.

These call ``remove_stale_ignored_vulns`` and its helpers directly: which
lines a removed block owns, which comments survive or are reported, header
forms, multi-line strings, the end of the file, and the ``tomllib`` check
that refuses an edit meaning anything else. Command-line behaviour is in
``test_remove_stale_suppressions.py``.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from datetime import date
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/security/remove_stale_suppressions.py"
HEADER = "[[IgnoredVulns]]\n"
SECTION = "\n# ---- Go toolchain ----\n# (Go advisories)\n\n\n"


@pytest.fixture(name="remover", scope="module")
def fixture_remover(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the remover once per module."""
    return load_script(SCRIPT)


def block(vuln_id: str, *extra: str) -> str:
    """Return an ``[[IgnoredVulns]]`` block for ``vuln_id`` and extra lines."""
    return HEADER + f'id = "{vuln_id}"\n' + "".join(f"{line}\n" for line in extra)


def remove(remover: ModuleType, content: str, *ids: str) -> str:
    """Return ``content`` with the blocks for ``ids`` removed."""
    result = remover.remove_stale_ignored_vulns(content, set(ids))
    assert_that(result.removed).is_equal_to(set(ids))
    return str(result.content)


def lost(remover: ModuleType, content: str, *ids: str) -> list[tuple[int, str]]:
    """Return the comment lines removing ``ids`` reports as deleted."""
    comments: list[tuple[int, str]] = remover.remove_stale_ignored_vulns(
        content,
        set(ids),
    ).comments
    return comments


# --- which entries go


def test_removes_every_block_with_a_listed_id(remover: ModuleType) -> None:
    """Duplicate blocks for one ID all go; the ID is reported once."""
    content = (
        block("DUP", 'reason = "one"')
        + "\n"
        + block("KEEP")
        + "\n"
        + block("DUP", 'reason = "two"')
    )

    assert_that(remove(remover, content, "DUP")).is_equal_to(block("KEEP"))


@pytest.mark.parametrize(
    "id_line",
    ['id = "X"', "id='X'", 'id   =   "X"  # trailing', '  id = "X"'],
)
def test_matches_id_spellings(remover: ModuleType, id_line: str) -> None:
    """Spacing, quote style, indentation and trailing comments do not matter."""
    content = f'{HEADER}{id_line}\nreason = "r"\n'

    assert_that(remove(remover, content, "X")).is_empty()


@pytest.mark.parametrize(
    ("content", "remove_ids", "names"),
    [
        ('[[IgnoredVulns]]\nreason = "no id"\n', {"X"}, "(X)"),
        (block("GHSA-1234-extra"), {"GHSA-1234"}, "(GHSA-1234)"),
        ("", {"X"}, "(X)"),
        ('IgnoredVulns = "X"\n', {"X"}, "(X)"),
        (block("A"), {"A", " A", "B\n"}, '(" A", "B\\n")'),
    ],
    ids=["no-id", "prefix", "empty-file", "not-an-array", "whitespace-twins"],
)
def test_a_listed_id_missing_from_the_file_is_refused(
    remover: ModuleType,
    content: str,
    remove_ids: set[str],
    names: str,
) -> None:
    """The list comes from the same file, so a miss means it is corrupted."""
    with pytest.raises(remover.RemovalError) as exc_info:
        remover.remove_stale_ignored_vulns(content, remove_ids)

    count = len(remove_ids - {"A"})
    assert_that(str(exc_info.value)).is_equal_to(
        f"REMOVE_IDS_JSON lists {count} ID(s) that are not in the file {names}; "
        "the list does not match the file",
    )


def test_an_empty_list_changes_nothing(remover: ModuleType) -> None:
    """With no IDs listed the content comes back as it was."""
    content = block("A")

    result = remover.remove_stale_ignored_vulns(content, set())

    assert_that(tuple(result)).is_equal_to((content, set(), []))


def test_block_ends_at_the_next_table_header(remover: ModuleType) -> None:
    """Removing the last suppression keeps a following table intact."""
    content = block("X") + '\n[[PackageOverrides]]\nname = "ünïcode-pkg"\n'

    assert_that(remove(remover, content, "X")).is_equal_to(
        '[[PackageOverrides]]\nname = "ünïcode-pkg"\n',
    )


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        (block("KEEP") + block("X").rstrip("\n"), block("KEEP").rstrip("\n")),
        (block("KEEP") + "\n" + block("X").rstrip("\n"), block("KEEP").rstrip("\n")),
        (
            '[[IgnoredVulns]]\r\nid = "KEEP"\r\n\r\n[[IgnoredVulns]]\r\nid = "X"',
            '[[IgnoredVulns]]\r\nid = "KEEP"',
        ),
        (block("X") + block("KEEP").rstrip("\n"), block("KEEP").rstrip("\n")),
    ],
)
def test_keeps_a_missing_final_newline_missing(
    remover: ModuleType,
    content: str,
    expected: str,
) -> None:
    """A file without a final newline still has none after the rewrite."""
    assert_that(remove(remover, content, "X")).is_equal_to(expected)


def test_trims_many_trailing_blank_lines_in_linear_time(remover: ModuleType) -> None:
    """Blank lines left at the end are cut in one step, not one at a time.

    Trimming them one by one, rescanning the end each time, took minutes here.
    """
    content = block("KEEP") + "\n" * 50_000 + block("X")
    started = time.perf_counter()

    rewritten = remove(remover, content, "X")

    assert_that(rewritten).is_equal_to(block("KEEP"))
    assert_that(time.perf_counter() - started).is_less_than(5)


# --- comment ownership and blank lines


def test_comment_directly_above_the_next_header_survives(
    remover: ModuleType,
) -> None:
    """A comment touching the next header belongs to the next block."""
    content = block("X") + "\n# Why Y is ignored\n" + block("Y")

    assert_that(remove(remover, content, "X")).is_equal_to(
        "# Why Y is ignored\n" + block("Y"),
    )
    assert_that(lost(remover, content, "X")).is_empty()


def test_comment_directly_above_a_removed_header_is_removed_and_reported(
    remover: ModuleType,
) -> None:
    """A comment touching the removed header goes with it and is listed.

    A note about ``KEEP`` written there would go too: the rule cannot tell
    what a comment is about, which is why every removed comment is reported.
    """
    content = block("KEEP") + "\n# Why X is ignored\n# (two lines)\n" + block("X")

    assert_that(remove(remover, content, "X")).is_equal_to(block("KEEP"))
    assert_that(lost(remover, content, "X")).is_equal_to(
        [(4, "# Why X is ignored"), (5, "# (two lines)")],
    )


@pytest.mark.parametrize(
    ("remove_id", "expected", "removed_comments"),
    [
        ("X", "# loose note\n\n" + block("KEEP"), [(3, "# inside X")]),
        ("KEEP", block("X", "# inside X", "", "# loose note"), []),
    ],
)
def test_comments_inside_a_block_and_section_comments(
    remover: ModuleType,
    remove_id: str,
    expected: str,
    removed_comments: list[tuple[int, str]],
) -> None:
    """A comment inside a removed block goes; one set off by blanks stays.

    ``# loose note`` has a blank line on both sides, so it survives removing
    ``X`` even if it was about ``X``.
    """
    content = block("X", "# inside X", "", "# loose note", "") + block("KEEP")

    assert_that(remove(remover, content, remove_id)).is_equal_to(expected)
    assert_that(lost(remover, content, remove_id)).is_equal_to(removed_comments)


def test_a_section_comment_survives_between_kept_blocks(remover: ModuleType) -> None:
    """``# ---- Go toolchain ----`` stays, with the blank lines after it."""
    content = block("KEEP") + "\n" + block("X") + SECTION + block("GO-1")

    assert_that(remove(remover, content, "X")).is_equal_to(
        block("KEEP") + SECTION + block("GO-1"),
    )


@pytest.mark.parametrize(
    ("tail", "line"),
    [("\n# last note\n", 4), ("\n# last note", 4), ("# right after X\n\n", 3)],
)
def test_a_comment_without_a_blank_line_after_it_goes(
    remover: ModuleType,
    tail: str,
    line: int,
) -> None:
    """At the end of the file a comment needs a blank line after it to stay."""
    content = block("X") + tail

    assert_that(remove(remover, content, "X")).is_empty()
    assert_that(lost(remover, content, "X")).is_equal_to(
        [(line, tail.strip())],
    )


@pytest.mark.parametrize(
    ("header", "expected"),
    [
        ("# File header\n\n", "# File header\n\n"),
        ("# File header\n# touching X\n", "# File header\n# touching X\n"),
    ],
    ids=["separated", "touching"],
)
def test_file_header_comment_is_never_removed(
    remover: ModuleType,
    header: str,
    expected: str,
) -> None:
    """A comment run on the first line stays, even touching a removed header."""
    content = header + block("X") + "\n" + block("KEEP")

    assert_that(remove(remover, content, "X")).is_equal_to(expected + block("KEEP"))
    assert_that(lost(remover, content, "X")).is_empty()


def test_consecutive_first_and_last_blocks(remover: ModuleType) -> None:
    """One separator is left between kept blocks, none after the last one."""
    content = "".join(block(vuln_id) + "\n" for vuln_id in "ABCDEF")

    assert_that(remove(remover, content, "A", "C", "D", "F")).is_equal_to(
        block("B") + "\n" + block("E") + "\n",
    )


def test_other_tables_are_never_moved_or_removed(remover: ModuleType) -> None:
    """``[[PackageOverrides]]`` and its comment stay between removed blocks."""
    overrides = '# Why the override\n[[PackageOverrides]]\nname = "pkg"\n\n'
    license_table = '[PackageOverrides.license]\noverride = ["MIT"]\n'
    content = block("X") + "\n" + overrides + block("Y") + "\n" + license_table

    assert_that(remove(remover, content, "X", "Y")).is_equal_to(
        overrides + license_table,
    )


# --- header forms and multi-line strings


@pytest.mark.parametrize(
    "header",
    [
        "[[IgnoredVulns]] # stale since 2026-01",
        "[[IgnoredVulns]]   ",
        "[[IgnoredVulns]]\t",
        "[[ IgnoredVulns ]]",
        "  [[IgnoredVulns]]",
        '[["IgnoredVulns"]]',
        "[[ 'IgnoredVulns' ]]\t# note",
    ],
)
def test_recognises_header_forms(remover: ModuleType, header: str) -> None:
    """Spacing, quoting and a trailing comment still mark a removable block."""
    content = block("KEEP") + f'\n{header}\nid = "X"\nreason = "r"\n'

    assert_that(remove(remover, content, "X")).is_equal_to(block("KEEP"))


@pytest.mark.parametrize("quotes", ['"""', "'''"])
def test_header_inside_a_multiline_string_is_text(
    remover: ModuleType,
    quotes: str,
) -> None:
    """A header-looking line inside a multi-line string is not a block start."""
    reason = f"reason = {quotes}\n# not a comment\n[[IgnoredVulns]]\n{quotes}\n"
    content = block("X") + reason + "\n" + block("KEEP") + reason

    assert_that(remove(remover, content, "X")).is_equal_to(block("KEEP") + reason)
    assert_that(lost(remover, content, "X")).is_empty()


@pytest.mark.parametrize(
    ("lines", "expected"),
    [
        (['a = "say \\"hi\\" # not a comment"\n'], [True]),
        (["b = 'x' # ''' in a comment\n"], [True]),
        (['c = """open \\""" still open\n', 'closed """"" # five\n'], [True, False]),
        (["d = '''one-line''' + '\n"], [True]),
        # Each case below fails when one step of the scanner is removed.
        (['a = ["\\"", """x"""]\n'], [True]),  # the escape skip in "..."
        (['a = ["""x"""", """\n', 'y"""]\n'], [True, False]),  # extra quotes
        (['a = \'x """\'\n'], [True]),  # the one-line literal string
    ],
    ids=["escapes", "comment", "multi-line", "unclosed", "esc", "quotes", "literal"],
)
def test_string_scanner(
    remover: ModuleType,
    lines: list[str],
    expected: list[bool],
) -> None:
    """Only lines that start inside a multi-line string are flagged."""
    assert_that(remover.lines_outside_strings([*lines, HEADER])).is_equal_to(
        [*expected, True],
    )


def test_comment_climb_stops_at_a_multiline_string(remover: ModuleType) -> None:
    """A comment-looking last line of a string is not claimed by the header."""
    kept = block("KEEP", "reason = '''", "# text'''")
    content = block("X") + "\n" + kept + block("Y")

    assert_that(remove(remover, content, "X", "Y")).is_equal_to(kept)


def test_split_lines_only_splits_on_newline(remover: ModuleType) -> None:
    """A U+2028 inside a value does not cut the line in two."""
    assert_that(remover.split_lines('a = "x y"\nb = 1')).is_equal_to(
        ['a = "x y"\n', "b = 1"],
    )


@pytest.mark.parametrize(
    ("vuln_id", "expected"),
    [
        ("GHSA-abcd-1234", "GHSA-abcd-1234"),
        ("PYSEC-2024.1:x_y", "PYSEC-2024.1:x_y"),
        (" A", '" A"'),
        ("a\tb\nc", '"a\\tb\\nc"'),
        ("a`|%b", "a`|%b"),
        ("é", '"\\u00e9"'),
        ("", '""'),
    ],
)
def test_printable_id_makes_any_id_one_safe_line(
    remover: ModuleType,
    vuln_id: str,
    expected: str,
) -> None:
    """Printable ASCII IDs print as is; anything else is JSON-quoted."""
    assert_that(remover.printable_id(vuln_id)).is_equal_to(expected)


# --- the tomllib check


@pytest.mark.parametrize(
    ("rewritten", "expected"),
    [
        ("x = []\n", {"x": {}}),
        ("x = {}\n", {"x": []}),
        ("x = 1\n", {"x": "1"}),
        ("x = 1\n", {"x": 1.0}),
        ("x = 1\n", {"x": True}),
        ('x = "1"\n', {"x": 1}),
        ("x = 2026-01-01\n", {"x": "2026-01-01"}),
        ("x = [1, 2]\n", {"x": [2, 1]}),
        ("x = [[1], [2]]\n", {"x": [[2], [1]]}),
    ],
)
def test_verification_tells_types_and_order_apart(
    remover: ModuleType,
    rewritten: str,
    expected: dict[str, Any],
) -> None:
    """Tables, arrays, value types and array order must all match."""
    with pytest.raises(remover.RemovalError) as exc_info:
        remover.verify_rewrite(rewritten, expected)

    assert_that(str(exc_info.value)).contains("would change more than")


@pytest.mark.parametrize(
    ("rewritten", "expected"),
    [
        ("b = 1\na = 2\n", {"a": 2, "b": 1}),
        ("x = [1, 2]\n", {"x": [1, 2]}),
        ("x = nan\n", {"x": float("nan")}),
        ("x = 2026-01-01\n", {"x": date(2026, 1, 1)}),
    ],
)
def test_verification_accepts_the_same_document(
    remover: ModuleType,
    rewritten: str,
    expected: dict[str, Any],
) -> None:
    """Key order is free; equal values pass, ``nan`` included."""
    remover.verify_rewrite(rewritten, expected)
