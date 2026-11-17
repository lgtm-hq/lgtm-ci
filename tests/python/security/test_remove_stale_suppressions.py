# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/security/remove_stale_suppressions.py``.

The remover drops the ``[[IgnoredVulns]]`` blocks whose ``id`` is listed in
``REMOVE_IDS_JSON`` and keeps every other line of ``.osv-scanner.toml`` as
written, including other sections and comments inside retained blocks.
Comment lines directly above a header belong to that header's block. Bad
input, or an edit that ``tomllib`` cannot confirm, ends in one ``ERROR:``
line and exit 1, and the file is left untouched.

Fixtures ``workspace`` and ``install_fixture`` come from
``tests/python/conftest.py``.
"""

from __future__ import annotations

import json
import os
import runpy
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/security/remove_stale_suppressions.py"
PROJECT_ROOT = Path(__file__).resolve().parents[3]
TOML = ".osv-scanner.toml"

Installer = Callable[[str, str], Path]


@pytest.fixture(name="remover", scope="module")
def fixture_remover(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the remover once per module."""
    return load_script(SCRIPT)


def run_main(
    remover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    path: Path,
    remove_ids: list[str],
) -> None:
    """Run ``main`` on ``path`` with ``remove_ids`` in the environment.

    Args:
        remover: The loaded script module.
        monkeypatch: Fixture used to set ``sys.argv`` and the environment.
        path: The suppression TOML to rewrite.
        remove_ids: IDs passed through ``REMOVE_IDS_JSON``.
    """
    monkeypatch.setenv("REMOVE_IDS_JSON", json.dumps(remove_ids))
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])
    remover.main()


# --- main: ported from tests/bats/unit/security/test_remove_stale_suppressions.bats


def test_preserves_non_ignored_vulns_sections(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``[PackageOverrides]`` and the leading comment survive the rewrite."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)

    run_main(remover, monkeypatch, path, ["GHSA-stale-1111"])

    assert_that(capsys.readouterr().err).is_equal_to("Removed: GHSA-stale-1111\n")
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(
        "# Suppression config\n"
        "[PackageOverrides]\n"
        'path = "vendor/"\n'
        "\n"
        "[[IgnoredVulns]]\n"
        'id = "GHSA-active-2222"\n'
        "ignoreUntil = 2099-12-31\n"
        'reason = "still present"\n',
    )


def test_keeps_comments_inside_retained_blocks(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A comment inside a kept block stays with it."""
    path = install_fixture("security/osv-scanner-with-block-comments.toml", TOML)

    run_main(remover, monkeypatch, path, ["GHSA-stale-3333"])

    kept = [
        "[[IgnoredVulns]]",
        "# still relevant",
        'id = "GHSA-active-4444"',
        'reason = "active"',
    ]
    assert_that(path.read_text(encoding="utf-8").splitlines()).is_equal_to(kept)


def test_handles_a_single_quoted_id(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A literal-string ``id`` matches like a basic string."""
    path = install_fixture("security/osv-scanner-single-quoted-id.toml", TOML)

    run_main(remover, monkeypatch, path, ["GHSA-stale-XXXX"])

    assert_that(capsys.readouterr().err).contains("Removed: GHSA-stale-XXXX")
    text = path.read_text(encoding="utf-8")
    assert_that(text).does_not_contain("GHSA-stale-XXXX")
    assert_that(text).contains("GHSA-active-5555")


# --- main: beyond the bats suite


def test_reports_removed_ids_sorted(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Each removed ID is reported once, sorted; an unknown ID gets a note."""
    path = workspace / TOML
    path.write_text(
        "".join(f'[[IgnoredVulns]]\nid = "{vuln_id}"\n' for vuln_id in "BAC"),
        encoding="utf-8",
    )

    run_main(remover, monkeypatch, path, ["C", "A", "NOT-THERE"])

    assert_that(capsys.readouterr().err).is_equal_to(
        f"Removed: A\nRemoved: C\nNot in {path}, nothing to remove: NOT-THERE\n",
    )
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(
        '[[IgnoredVulns]]\nid = "B"\n',
    )


@pytest.mark.parametrize("remove_ids", [[], ["NOT-THERE"]])
def test_leaves_the_file_unwritten_when_nothing_matches(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    remove_ids: list[str],
) -> None:
    """With nothing to remove the file is not rewritten at all."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)
    original = path.read_text(encoding="utf-8")
    os.utime(path, ns=(1_000_000_000, 1_000_000_000))

    run_main(remover, monkeypatch, path, remove_ids)

    notes = [f"Not in {path}, nothing to remove: {item}\n" for item in remove_ids]
    assert_that(capsys.readouterr().err).is_equal_to("".join(notes))
    assert_that(path.read_text(encoding="utf-8")).is_equal_to(original)
    assert_that(path.stat().st_mtime_ns).is_equal_to(1_000_000_000)


@pytest.mark.parametrize("argv", [[], ["a.toml", "b.toml"]])
def test_wrong_argument_count_is_a_usage_error(
    remover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    argv: list[str],
) -> None:
    """Anything but one path prints usage and exits 1."""
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", *argv])

    with pytest.raises(SystemExit) as exc_info:
        remover.main()

    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(capsys.readouterr().err).starts_with("Usage: ")


def assert_clean_failure(
    capsys: pytest.CaptureFixture[str],
    exc_info: pytest.ExceptionInfo[SystemExit],
    *messages: str,
) -> None:
    """Assert exit 1 and exactly one ``ERROR:`` line holding ``messages``."""
    err = capsys.readouterr().err
    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(err.splitlines()).is_length(1)
    assert_that(err).starts_with("ERROR: ").contains(*messages)
    assert_that(err).ends_with("; the file was left unchanged\n")


@pytest.mark.parametrize(
    ("ids_json", "message"),
    [
        (None, "REMOVE_IDS_JSON is not set"),
        ("[not json", "REMOVE_IDS_JSON is not valid JSON"),
        ("", "REMOVE_IDS_JSON is not valid JSON"),
        ('{"A": 1}', "REMOVE_IDS_JSON must be a JSON array of strings"),
        ('"A"', "REMOVE_IDS_JSON must be a JSON array of strings"),
        ('["A", 1]', "REMOVE_IDS_JSON must be a JSON array of strings"),
        ("[null]", "REMOVE_IDS_JSON must be a JSON array of strings"),
    ],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_missing_or_malformed_ids_fail_without_writing(
    remover: ModuleType,
    install_fixture: Installer,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    ids_json: str | None,
    message: str,
) -> None:
    """A missing or malformed ``REMOVE_IDS_JSON`` exits 1 with one error line."""
    path = install_fixture("security/osv-scanner-with-package-overrides.toml", TOML)
    original = path.read_bytes()
    if ids_json is None:
        monkeypatch.delenv("REMOVE_IDS_JSON", raising=False)
    else:
        monkeypatch.setenv("REMOVE_IDS_JSON", ids_json)
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])

    with pytest.raises(SystemExit) as exc_info:
        remover.main()

    assert_clean_failure(capsys, exc_info, message)
    assert_that(path.read_bytes()).is_equal_to(original)


def test_missing_file_fails(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A path that does not exist is an error, and nothing is created."""
    path = workspace / TOML

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["A"])

    assert_clean_failure(capsys, exc_info, f"ERROR: {path} does not exist;")
    assert_that(path.exists()).is_false()


def test_unreadable_path_fails(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A path that cannot be read as a file is a clean error."""
    path = workspace / TOML
    path.mkdir()

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["A"])

    assert_clean_failure(capsys, exc_info, f"ERROR: cannot read {path} (")
    assert_that(path.is_dir()).is_true()


@pytest.mark.parametrize(
    ("content", "message"),
    [
        (b"[[IgnoredVulns]\nid = 'A'\n", ": not valid TOML ("),
        (b'[[IgnoredVulns]]\nid = "A"\nreason = "\xff"\n', " is not UTF-8 ("),
        (
            b'IgnoredVulns = [{id = "A"}]\n',
            ": found 0 [[IgnoredVulns]] header lines but tomllib reads 1 entries",
        ),
        (
            b'[[IgnoredVulns]]\nid = "KEEP"\n\n'
            b'[[IgnoredVulns]]\nid = "A"\nextra = [\n  ["a"]\n]\n',
            ": the edited file would not be valid TOML (",
        ),
        (
            b'[[IgnoredVulns]]\nid = "KEEP"\n\n'
            b'[[IgnoredVulns]]\nid = "A"\n[IgnoredVulns.note]\ntext = "x"\n',
            ": the edited file would change more than the listed suppressions",
        ),
    ],
    ids=["bad-toml", "not-utf8", "inline-array", "invalid-result", "changed-result"],
)
# pylint: disable-next=too-many-arguments,too-many-positional-arguments
def test_unusable_or_unverifiable_file_is_not_written(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    content: bytes,
    message: str,
) -> None:
    """Bad input, or an edit ``tomllib`` does not confirm, writes nothing.

    In the last two cases the line editor and ``tomllib`` disagree: a nested
    array line looks like a ``["a"]`` table header, and ``[IgnoredVulns.note]``
    is a sub-table of the entry above it, not a separate block. Removing the
    block by line would break the file or move the note onto ``KEEP``.
    """
    path = workspace / TOML
    path.write_bytes(content)

    with pytest.raises(SystemExit) as exc_info:
        run_main(remover, monkeypatch, path, ["A"])

    assert_clean_failure(capsys, exc_info, f"ERROR: {path}{message}")
    assert_that(path.read_bytes()).is_equal_to(content)


def test_runs_as_a_script(
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Run as ``__main__``, the remover rewrites the file it is given."""
    path = workspace / TOML
    path.write_text('[[IgnoredVulns]]\nid = "A"\n', encoding="utf-8")
    monkeypatch.setenv("REMOVE_IDS_JSON", '["A"]')
    monkeypatch.setattr(sys, "argv", ["remove_stale_suppressions.py", str(path)])

    runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(capsys.readouterr().err).is_equal_to("Removed: A\n")
    assert_that(path.read_text(encoding="utf-8")).is_empty()


# --- remove_stale_ignored_vulns


def test_removes_every_block_with_a_listed_id(remover: ModuleType) -> None:
    """Duplicate blocks for one ID all go; the ID is reported once."""
    content = (
        '[[IgnoredVulns]]\nid = "DUP"\nreason = "one"\n\n'
        '[[IgnoredVulns]]\nid = "KEEP"\n\n'
        '[[IgnoredVulns]]\nid = "DUP"\nreason = "two"\n'
    )

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"DUP"})

    assert_that(rewritten).is_equal_to('[[IgnoredVulns]]\nid = "KEEP"\n')
    assert_that(removed).is_equal_to({"DUP"})


@pytest.mark.parametrize(
    "id_line",
    ['id = "X"', "id='X'", 'id   =   "X"  # trailing', '  id = "X"'],
)
def test_matches_id_spellings(remover: ModuleType, id_line: str) -> None:
    """Spacing, quote style, indentation and trailing comments do not matter."""
    content = f'[[IgnoredVulns]]\n{id_line}\nreason = "r"\n'

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_empty()
    assert_that(removed).is_equal_to({"X"})


def test_keeps_a_block_without_an_id(remover: ModuleType) -> None:
    """A block with no ``id`` line cannot match and is kept."""
    content = '[[IgnoredVulns]]\nreason = "no id"\n'

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_equal_to(content)
    assert_that(removed).is_empty()


def test_does_not_match_an_id_by_prefix(remover: ModuleType) -> None:
    """Only the exact ID matches, not one that starts with it."""
    content = '[[IgnoredVulns]]\nid = "GHSA-1234-extra"\n'

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"GHSA-1234"})

    assert_that(rewritten).is_equal_to(content)
    assert_that(removed).is_empty()


def test_block_ends_at_the_next_table_header(remover: ModuleType) -> None:
    """Removing the last suppression keeps a following table intact."""
    content = (
        '[[IgnoredVulns]]\nid = "X"\n\n'
        '[[PackageOverrides]]\nname = "ünïcode-pkg"\nignore = true\n'
    )

    rewritten, removed = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_equal_to(
        '[[PackageOverrides]]\nname = "ünïcode-pkg"\nignore = true\n',
    )
    assert_that(removed).is_equal_to({"X"})


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        (
            '[[IgnoredVulns]]\nid = "KEEP"\n[[IgnoredVulns]]\nid = "X"',
            '[[IgnoredVulns]]\nid = "KEEP"',
        ),
        (
            '[[IgnoredVulns]]\nid = "KEEP"\n\n[[IgnoredVulns]]\nid = "X"',
            '[[IgnoredVulns]]\nid = "KEEP"',
        ),
        (
            '[[IgnoredVulns]]\r\nid = "KEEP"\r\n\r\n[[IgnoredVulns]]\r\nid = "X"',
            '[[IgnoredVulns]]\r\nid = "KEEP"',
        ),
        (
            '[[IgnoredVulns]]\nid = "X"\n[[IgnoredVulns]]\nid = "KEEP"',
            '[[IgnoredVulns]]\nid = "KEEP"',
        ),
    ],
)
def test_keeps_a_missing_final_newline_missing(
    remover: ModuleType,
    content: str,
    expected: str,
) -> None:
    """A file without a final newline still has none after the rewrite."""
    rewritten, _ = remover.remove_stale_ignored_vulns(content, {"X"})

    assert_that(rewritten).is_equal_to(expected)


def test_empty_content(remover: ModuleType) -> None:
    """An empty file stays empty and removes nothing."""
    assert_that(remover.remove_stale_ignored_vulns("", {"X"})).is_equal_to(
        ("", set()),
    )


def test_ignores_a_non_array_ignored_vulns(remover: ModuleType) -> None:
    """``IgnoredVulns`` that is not an array of tables has nothing to remove."""
    content = 'IgnoredVulns = "X"\n'

    assert_that(remover.remove_stale_ignored_vulns(content, {"X"})).is_equal_to(
        (content, set()),
    )


# --- comment ownership and blank lines


def remove(remover: ModuleType, content: str, *ids: str) -> str:
    """Return ``content`` with the blocks for ``ids`` removed."""
    rewritten, removed = remover.remove_stale_ignored_vulns(content, set(ids))
    assert_that(removed).is_equal_to(set(ids))
    return str(rewritten)


def test_comment_directly_above_the_next_header_survives(
    remover: ModuleType,
) -> None:
    """A comment touching the next header belongs to the next block."""
    content = "".join(
        [
            '[[IgnoredVulns]]\nid = "X"\n\n',
            '# Why Y is ignored\n[[IgnoredVulns]]\nid = "Y"\n',
        ],
    )

    assert_that(remove(remover, content, "X")).is_equal_to(
        '# Why Y is ignored\n[[IgnoredVulns]]\nid = "Y"\n',
    )


def test_comment_directly_above_a_removed_header_goes_with_it(
    remover: ModuleType,
) -> None:
    """A comment touching the removed header is removed with its block."""
    content = (
        '[[IgnoredVulns]]\nid = "KEEP"\n\n'
        '# Why X is ignored\n# (two lines)\n[[IgnoredVulns]]\nid = "X"\n'
    )

    assert_that(remove(remover, content, "X")).is_equal_to(
        '[[IgnoredVulns]]\nid = "KEEP"\n',
    )


@pytest.mark.parametrize(
    ("remove_id", "expected"),
    [
        ("X", '[[IgnoredVulns]]\nid = "KEEP"\n'),
        (
            "KEEP",
            '[[IgnoredVulns]]\nid = "X"\n# inside X\n\n# loose note\n',
        ),
    ],
)
def test_comment_followed_by_a_blank_line_stays_with_the_block_above(
    remover: ModuleType,
    remove_id: str,
    expected: str,
) -> None:
    """Trailing and loose comments belong to the block above them."""
    content = (
        '[[IgnoredVulns]]\nid = "X"\n# inside X\n\n# loose note\n\n'
        '[[IgnoredVulns]]\nid = "KEEP"\n'
    )

    assert_that(remove(remover, content, remove_id)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        (
            "".join(
                [
                    '# File header\n\n[[IgnoredVulns]]\nid = "X"\n\n',
                    '[[IgnoredVulns]]\nid = "KEEP"\n',
                ],
            ),
            '# File header\n\n[[IgnoredVulns]]\nid = "KEEP"\n',
        ),
        (
            '# File header, touching X\n[[IgnoredVulns]]\nid = "X"\n\n'
            '[[IgnoredVulns]]\nid = "KEEP"\n',
            '[[IgnoredVulns]]\nid = "KEEP"\n',
        ),
    ],
    ids=["separated", "touching"],
)
def test_file_header_comment(
    remover: ModuleType,
    content: str,
    expected: str,
) -> None:
    """A file header survives unless it touches the removed first header."""
    assert_that(remove(remover, content, "X")).is_equal_to(expected)


def test_consecutive_first_and_last_blocks(remover: ModuleType) -> None:
    """One separator is left between kept blocks, none after the last one."""
    content = "".join(f'[[IgnoredVulns]]\nid = "{vuln_id}"\n\n' for vuln_id in "ABCDEF")

    assert_that(remove(remover, content, "A", "C", "D", "F")).is_equal_to(
        '[[IgnoredVulns]]\nid = "B"\n\n[[IgnoredVulns]]\nid = "E"\n\n',
    )


def test_other_tables_are_never_moved_or_removed(remover: ModuleType) -> None:
    """``[[PackageOverrides]]`` and its comment stay between removed blocks."""
    content = (
        '[[IgnoredVulns]]\nid = "X"\n\n'
        "# Why the override\n[[PackageOverrides]]\n"
        'name = "pkg"\nignore = true\n\n'
        '[[IgnoredVulns]]\nid = "Y"\n\n'
        '[PackageOverrides.license]\noverride = ["MIT"]\n'
    )

    assert_that(remove(remover, content, "X", "Y")).is_equal_to(
        "# Why the override\n[[PackageOverrides]]\n"
        'name = "pkg"\nignore = true\n\n'
        '[PackageOverrides.license]\noverride = ["MIT"]\n',
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
    content = f'[[IgnoredVulns]]\nid = "KEEP"\n\n{header}\nid = "X"\nreason = "r"\n'

    assert_that(remove(remover, content, "X")).is_equal_to(
        '[[IgnoredVulns]]\nid = "KEEP"\n',
    )


@pytest.mark.parametrize("quotes", ['"""', "'''"])
def test_header_inside_a_multiline_string_is_text(
    remover: ModuleType,
    quotes: str,
) -> None:
    """A header-looking line inside a multi-line string is not a block start."""
    reason = f"reason = {quotes}\n# not a comment\n[[IgnoredVulns]]\n{quotes}\n"
    content = "".join(
        [
            f'[[IgnoredVulns]]\nid = "X"\n{reason}\n',
            f'[[IgnoredVulns]]\nid = "KEEP"\n{reason}',
        ],
    )

    assert_that(remove(remover, content, "X")).is_equal_to(
        f'[[IgnoredVulns]]\nid = "KEEP"\n{reason}',
    )


def test_string_scanner_follows_quotes_escapes_and_comments(
    remover: ModuleType,
) -> None:
    """Only lines that start inside a multi-line string are flagged."""
    lines = [
        'a = "say \\"hi\\" # not a comment"\n',
        "b = 'x' # ''' in a comment\n",
        'c = """open \\""" still open\n',
        'closed """"" # five quotes: two belong to the string\n',
        "d = '''one-line''' + '\n",
        "[[IgnoredVulns]]\n",
    ]

    assert_that(remover.lines_outside_strings(lines)).is_equal_to(
        [True, True, True, False, True, True],
    )


def test_comment_climb_stops_at_a_multiline_string(remover: ModuleType) -> None:
    """A comment-looking last line of a string is not claimed by the header."""
    content = (
        '[[IgnoredVulns]]\nid = "X"\n\n'
        "[[IgnoredVulns]]\nid = \"KEEP\"\nreason = '''\n# text'''\n"
        '[[IgnoredVulns]]\nid = "Y"\n'
    )

    assert_that(remove(remover, content, "X", "Y")).is_equal_to(
        "[[IgnoredVulns]]\nid = \"KEEP\"\nreason = '''\n# text'''\n",
    )


def test_keeps_crlf_line_endings(
    remover: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CRLF endings are written back byte for byte."""
    path = workspace / TOML
    path.write_bytes(
        b"".join(
            [
                b'[[IgnoredVulns]]\r\nid = "X"\r\n\r\n',
                b'# keep\r\n[[IgnoredVulns]]\r\nid = "KEEP"\r\n',
            ],
        ),
    )

    run_main(remover, monkeypatch, path, ["X"])

    assert_that(path.read_bytes()).is_equal_to(
        b'# keep\r\n[[IgnoredVulns]]\r\nid = "KEEP"\r\n',
    )


def test_split_lines_only_splits_on_newline(remover: ModuleType) -> None:
    """A U+2028 inside a value does not cut the line in two."""
    assert_that(remover.split_lines('a = "x y"\nb = 1')).is_equal_to(
        ['a = "x y"\n', "b = 1"],
    )
