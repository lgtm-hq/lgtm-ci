# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/actions/bats_durations_tap.py``: the static reader.

Covers reading a test file's names the way bats preprocesses it, the
heredoc tracker, the name skeleton and the name check. The fixtures are
described in ``test_bats_durations.py``; ``count/counts.json`` holds what
``bats --count`` printed for each ``count/`` file.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from bats_durations_support import SCRIPT_PATH, read_case, read_json, static_tests

# Files whose static reading is not what bats registers.
COUNT_DIFFERS = {"count/heredoc.bats.txt", "count/dynamic.bats.txt"}


@pytest.fixture(name="tap")
def fixture_tap(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Return the sibling module the script imports (bats_durations_tap)."""
    return sys.modules[load_script(SCRIPT_PATH).DurationsError.__module__]


@pytest.fixture(name="data")
def fixture_data(fixtures_dir: Path) -> Path:
    """Return the committed bats-durations fixture directory."""
    return fixtures_dir / "bats-durations"


def _bats_counts(data: Path) -> dict[str, int]:
    """Return what ``bats --count`` printed for each ``count/`` fixture."""
    counts: dict[str, int] = read_json(data / "count" / "counts.json")
    return counts


def _read(tap: ModuleType, tmp_path: Path, source: bytes) -> list[str | None]:
    """Write ``source`` to a test file and read its tests."""
    target = tmp_path / "t.bats"
    target.write_bytes(source)
    names: list[str | None] = tap.read_tests(target)
    return names


# --- read_tests: counts ------------------------------------------------------


def test_count_matches_bats_for_every_shape(tap: ModuleType, data: Path) -> None:
    """Indentation, comments, braces, quotes, comment form, no tests: as bats."""
    for path, expected in _bats_counts(data).items():
        if path in COUNT_DIFFERS:
            continue
        assert_that(tap.read_tests(data / path)).described_as(path).is_length(
            expected,
        )


def test_count_matches_bats_for_the_suite(tap: ModuleType, data: Path) -> None:
    """The edge suite's static counts are bats' counts."""
    expected = read_json(data / "edge.counts.json")

    tests = static_tests(tap, data, list(expected))

    assert_that({path: len(names) for path, names in tests.items()}).is_equal_to(
        expected,
    )


def test_read_tests_refuses_a_test_line_in_a_heredoc(
    tap: ModuleType,
    data: Path,
) -> None:
    """Bats counts 1 here; whether a heredoc test registers cannot be read."""
    assert_that(_bats_counts(data)["count/heredoc.bats.txt"]).is_equal_to(1)

    with pytest.raises(
        tap.DurationsError,
        match=r"heredoc\.bats\.txt:4: a test definition inside heredoc text",
    ):
        tap.read_tests(data / "count/heredoc.bats.txt")


def test_count_refuses_a_file_that_registers_tests_at_run_time(
    tap: ModuleType,
    data: Path,
) -> None:
    """bats_test_function in the file: no count, so no wrong attribution."""
    assert_that(_bats_counts(data)["count/dynamic.bats.txt"]).is_equal_to(4)

    with pytest.raises(tap.DurationsError, match="registers tests at run time"):
        tap.read_tests(data / "count/dynamic.bats.txt")


def test_count_ignores_crlf_line_endings(
    tap: ModuleType,
    data: Path,
    tmp_path: Path,
) -> None:
    """Bats strips every CR before matching; so does the count."""
    for path, expected in _bats_counts(data).items():
        if path in COUNT_DIFFERS:
            continue
        source = (data / path).read_bytes()
        crlf = tmp_path / Path(path).name
        crlf.write_bytes(source.replace(b"\n", b"\r\n"))
        assert_that(tap.read_tests(crlf)).described_as(path).is_length(expected)


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        pytest.param(b'@test "a" {\n}', 1, id="no-final-newline"),
        pytest.param(b'@test "a" {\x00\n}\n', 1, id="nul-dropped"),
        pytest.param(b'@test "a"{\n}\n', 0, id="no-blank-before-brace"),
        pytest.param(b'@test "a" {}\n', 1, id="empty-body"),
        pytest.param(b'  # @test "a" {\n', 0, id="indented-comment"),
        pytest.param(b"f() { #@test\n}\n", 1, id="comment-form-tight"),
        pytest.param(b"\xff\xfe@test x {\n", 0, id="bytes-before"),
        pytest.param(b"@test \xff {\n", 1, id="binary-name"),
    ],
)
def test_count_line_rules(
    tap: ModuleType,
    tmp_path: Path,
    source: bytes,
    expected: int,
) -> None:
    """The line rules of bats-preprocess, byte for byte."""
    assert_that(_read(tap, tmp_path, source)).is_length(expected)


def test_count_reads_a_binary_file(tap: ModuleType, tmp_path: Path) -> None:
    """Arbitrary bytes give a count (here none), never an exception."""
    assert_that(_read(tap, tmp_path, bytes(range(256)) * 64)).is_empty()


def test_count_refuses_missing_and_non_regular_files(
    tap: ModuleType,
    tmp_path: Path,
) -> None:
    """A deleted file or a directory is an error, not a zero."""
    with pytest.raises(tap.DurationsError, match="cannot read test file .*gone"):
        tap.read_tests(tmp_path / "gone.bats")
    with pytest.raises(tap.DurationsError, match="cannot read test file"):
        tap.read_tests(tmp_path)


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads any file")
def test_count_refuses_an_unreadable_file(tap: ModuleType, tmp_path: Path) -> None:
    """A file that cannot be opened is an error."""
    target = tmp_path / "locked.bats"
    target.write_text('@test "a" {\n}\n', encoding="utf-8")
    target.chmod(0)
    try:
        with pytest.raises(tap.DurationsError, match="cannot read"):
            tap.read_tests(target)
    finally:
        target.chmod(0o644)


# --- read_tests: names -------------------------------------------------------


def test_read_tests_names_as_bats_preprocess_takes_them(
    tap: ModuleType,
    data: Path,
) -> None:
    """One quote stripped at each end, escapes kept; comment form: the function."""
    assert_that(tap.read_tests(data / "count/names.bats.txt")).is_equal_to(
        [
            "name with {braces} inside",
            'name with \\"double\\" quotes',
            "single quoted name",
            "same-line body",
            "unquoted words",
            "trailing blanks",
        ],
    )
    assert_that(tap.read_tests(data / "count/comment-form.bats.txt")).is_equal_to(
        ["comment_form_test"],
    )


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        pytest.param(b'@test "uses $HOME" {\n}\n', None, id="dollar"),
        pytest.param(b'@test "runs `date`" {\n}\n', None, id="backtick"),
        pytest.param(b"@test 'says \"hi\"' {\n}\n", None, id="unescaped-quote"),
        pytest.param(b'@test "a \\\\" b" {\n}\n', None, id="quote-after-backslash"),
        pytest.param(b'@test "a \\"b\\"" {\n}\n', 'a \\"b\\"', id="escaped-quote"),
        pytest.param(b'@test "\xc3\xbcber # 1" {\n}\n', "über # 1", id="utf8"),
    ],
)
def test_read_tests_marks_names_bash_would_expand(
    tap: ModuleType,
    tmp_path: Path,
    source: bytes,
    expected: str | None,
) -> None:
    """A name bash would expand or re-split is None: it matches anything."""
    assert_that(_read(tap, tmp_path, source)).is_equal_to([expected])


# --- read_tests: heredoc tracker ---------------------------------------------

_INNER = b'@test "inner" {\n}\n'
_OUTER = b'@test "outer" {\n}\n'


@pytest.mark.parametrize(
    "opener",
    [
        pytest.param(b"cat <<EOT", id="bare"),
        pytest.param(b"cat << EOT", id="bare-spaced"),
        pytest.param(b"cat <<'EOT'", id="single-quoted"),
        pytest.param(b'cat << "EOT"', id="double-quoted"),
        pytest.param(b"cat <<\\EOT", id="backslash"),
        pytest.param(b"cat <<-EOT", id="dash"),
        pytest.param(b"x=$(cat <<EOT >/dev/null", id="in-substitution"),
    ],
)
def test_heredoc_every_delimiter_form_is_refused(
    tap: ModuleType,
    tmp_path: Path,
    opener: bytes,
) -> None:
    """A test line in the body of any heredoc form refuses the file."""
    source = _OUTER + opener + b"\n" + _INNER + b"EOT\n"

    with pytest.raises(tap.DurationsError, match=r"t\.bats:4: a test definition"):
        _read(tap, tmp_path, source)


def test_heredoc_dash_form_strips_leading_tabs(
    tap: ModuleType,
    tmp_path: Path,
) -> None:
    """``<<-`` ends at a tab-indented delimiter; the test after it counts."""
    source = b"cat <<-EOT\n\tbody\n\tEOT\n" + _OUTER

    assert_that(_read(tap, tmp_path, source)).is_equal_to(["outer"])


def test_heredoc_plain_form_does_not_strip_tabs(
    tap: ModuleType,
    tmp_path: Path,
) -> None:
    """Without ``-`` a tab-indented delimiter is body text, so is the test."""
    source = b"cat <<EOT\n\tEOT\n" + _INNER + b"EOT\n"

    with pytest.raises(tap.DurationsError, match=r"t\.bats:3: a test definition"):
        _read(tap, tmp_path, source)


def test_heredoc_two_on_one_line_are_read_in_order(
    tap: ModuleType,
    tmp_path: Path,
) -> None:
    """The second heredoc's body follows the first's delimiter."""
    clean = b"cat <<ONE <<'TWO'\nfirst\nONE\nsecond\nTWO\n" + _OUTER
    hidden = b"cat <<ONE <<'TWO'\nfirst\nONE\n" + _INNER + b"TWO\n"

    assert_that(_read(tap, tmp_path, clean)).is_equal_to(["outer"])
    with pytest.raises(tap.DurationsError, match=r"t\.bats:4: a test definition"):
        _read(tap, tmp_path, hidden)


@pytest.mark.parametrize(
    "line",
    [
        pytest.param(b"cat <<<EOT", id="here-string"),
        pytest.param(b'cat <<< "EOT"', id="here-string-quoted"),
        pytest.param(b"echo $(( 1 << 2 ))", id="shift"),
        pytest.param(b'echo "a <<WORD b"', id="in-quotes-unterminated"),
        pytest.param(b"cat <<NEVER", id="unterminated"),
    ],
)
def test_heredoc_what_is_not_one_is_not_refused(
    tap: ModuleType,
    tmp_path: Path,
    line: bytes,
) -> None:
    """A here-string, a shift or an unterminated ``<<`` opens nothing."""
    source = line + b"\n" + _INNER + b"EOT\n" + _OUTER

    assert_that(_read(tap, tmp_path, source)).is_equal_to(["inner", "outer"])


def test_heredoc_definition_after_the_close_counts(
    tap: ModuleType,
    tmp_path: Path,
) -> None:
    """Tests before and after a closed heredoc are read; its text is not."""
    source = _OUTER + b"cat <<'EOT'\nnot a test\nEOT\n" + _INNER

    assert_that(_read(tap, tmp_path, source)).is_equal_to(["outer", "inner"])


def test_heredoc_opener_inside_a_body_opens_nothing(
    tap: ModuleType,
    tmp_path: Path,
) -> None:
    """Body text is skipped whole: a ``<<`` in it is text."""
    source = b"cat <<A\ncat <<B\nA\n" + _INNER + b"B\n"

    assert_that(_read(tap, tmp_path, source)).is_equal_to(["inner"])


def test_heredoc_real_bats_fixtures_are_refused(
    tap: ModuleType,
    data: Path,
) -> None:
    """The real-bats heredoc fixtures are refused; ordinary files are not."""
    for name in ("a-heredoc", "a-heredoc-late"):
        with pytest.raises(tap.DurationsError, match="inside heredoc text"):
            tap.read_tests(data / f"names/{name}.bats.txt")
    assert_that(tap.read_tests(data / "names/a-dead.bats.txt")).is_length(2)


# --- skeleton / check_names --------------------------------------------------


def test_skeleton_keeps_ascii_letters_and_digits(tap: ModuleType) -> None:
    """Quoting, spacing, punctuation and non-ASCII text are dropped."""
    assert_that(tap.skeleton('Name \\"With\\" #1 → x_y')).is_equal_to(
        "namewith1xy",
    )


def test_check_names_accepts_real_bats_for_every_name_shape(
    tap: ModuleType,
    data: Path,
) -> None:
    """Quotes, braces, tabs, the comment form: bats' descriptions match."""
    report, files = read_case(data, "shapes")

    durations, missing = tap.attribute(
        files,
        static_tests(tap, data, files),
        tap.parse_tap(report),
    )

    assert_that(sorted(durations)).is_equal_to(sorted(f for f in files if f))
    assert_that(missing).is_empty()


def test_check_names_names_the_first_difference(tap: ModuleType) -> None:
    """The position, the file expected there and both names."""
    timings = tap.parse_tap(
        "1..3\nok 1 a # in 1 ms\nok 2 x # in 1 ms\nok 3 c # in 1 ms\n",
    )

    with pytest.raises(
        tap.DurationsError,
        match="test 2 should be 'b' of two.bats, the report says 'x'",
    ):
        tap.check_names(
            ["one.bats", "two.bats"],
            {"one.bats": ["a"], "two.bats": ["b", "c"]},
            timings,
        )


def test_check_names_lets_an_unpredictable_name_match(tap: ModuleType) -> None:
    """None (a name bash expands) matches; untimed numbers are not compared."""
    timings = tap.parse_tap(
        "1..2\nok 1 home is /root # in 1 ms\nnot ok 2 setup_file failed\n",
    )

    tap.check_names(["a.bats"], {"a.bats": [None, "never reported"]}, timings)


def test_count_mismatch_names_the_file_when_a_name_differs(tap: ModuleType) -> None:
    """A count mismatch reports the first differing name and its file."""
    timings = tap.parse_tap("1..2\nok 1 a # in 1 ms\nok 2 b # in 1 ms\n")

    with pytest.raises(
        tap.DurationsError,
        match="test 2 should be 'phantom' of a.bats, the report says 'b'",
    ):
        tap.attribute(
            ["a.bats", "b.bats"],
            {"a.bats": ["a", "phantom"], "b.bats": ["b"]},
            timings,
        )


def test_count_mismatch_falls_back_to_totals_when_names_agree(
    tap: ModuleType,
) -> None:
    """Every compared name matches: the message gives the two totals."""
    timings = tap.parse_tap("1..3\nok 1 a # in 1 ms\nok 2 b # in 1 ms\n")

    with pytest.raises(
        tap.DurationsError,
        match="test counts add up to 2, the TAP plan says 3",
    ):
        tap.attribute(["a.bats"], {"a.bats": ["a", "b"]}, timings)
