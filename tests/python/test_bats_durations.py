# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/actions/bats-durations.py``: TAP, attribution, ``shard``.

The fixtures under ``tests/fixtures/bats-durations`` come from bats 1.14.0.
``*.report.tap`` are real ``--tap --timing --report-formatter tap`` reports
of the sources next to them (``suite/`` and ``count/``, named ``*.bats.txt``
so no tool treats them as this repository's tests), ``*.files.txt`` the
run-ordered file lists, and ``*counts.json`` what ``bats --count`` printed
for each file. ``repo-slice`` is a report of three files of this
repository. ``names/`` holds the name-check cases: files whose static
tests differ from what bats registers (a heredoc, dead code, a helper or a
library that registers a test; run with ``BATS_LIB_PATH=<names>/lib``) and
a passing test whose name contains ``# skip``. The static reader has its
own tests in ``test_bats_durations_tap.py``. Paths in the lists are
relative to the fixture directory.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from bats_durations_support import (
    SCRIPT_PATH,
    read_case,
    read_json,
    static_tests,
)

OUTPUT = "out/bats-durations-shard.json"
EDGE_DURATIONS = {
    "suite/pass.bats.txt": 0.218,
    "suite/teardown-fails.bats.txt": 0.111,
    "suite/mixed.bats.txt": 0.004,
    "suite/last.bats.txt": 0.003,
}
SLICE_DURATIONS = {
    "tests/bats/unit/actions/test_harden_runner_platform.bats": 0.007,
    "tests/bats/unit/actions/docker/test_merge_manifests.bats": 1.048,
    "tests/bats/unit/lib/release/test_release_assets.bats": 0.108,
}


@pytest.fixture(name="mod")
def fixture_mod(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the hyphenated script as a module."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="tap")
def fixture_tap(mod: ModuleType) -> ModuleType:
    """Return the sibling module the script imports (bats_durations_tap)."""
    return sys.modules[mod.DurationsError.__module__]


@pytest.fixture(name="data")
def fixture_data(fixtures_dir: Path) -> Path:
    """Return the committed bats-durations fixture directory."""
    return fixtures_dir / "bats-durations"


def _unnamed(counts: dict[str, int]) -> dict[str, list[str | None]]:
    """Turn test counts into name lists that match any description."""
    return {path: [None] * count for path, count in counts.items()}


# --- regular files only ------------------------------------------------------


def test_read_regular_refuses_a_fifo_without_blocking(
    tap: ModuleType,
    tmp_path: Path,
) -> None:
    """A FIFO is refused before it is opened for reading."""
    fifo = tmp_path / "pipe"
    os.mkfifo(fifo)

    with pytest.raises(tap.DurationsError, match="not a regular file"):
        tap.read_regular(fifo, 1024, "TAP report")


@pytest.mark.parametrize(
    "fifo_name",
    [
        "case.report.tap",
        "case.files.txt",
        "a.bats",
        "bats-duration-ms.txt",
        "bats-version.txt",
    ],
)
def test_shard_command_never_reads_a_fifo(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    fifo_name: str,
) -> None:
    """A FIFO in place of any input: no blocking; a warning or a null field."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "a.bats").write_text(_ONE_TEST, encoding="utf-8")
    _write_case(tmp_path, "1..1\nok 1 a # in 3 ms\n", "a.bats\n")
    _run_files(tmp_path)
    (tmp_path / fifo_name).unlink()
    os.mkfifo(tmp_path / fifo_name)

    assert_that(mod.main(_shard_argv(tmp_path, "case"))).is_equal_to(0)

    if fifo_name.startswith("bats-"):
        document = read_json(tmp_path / OUTPUT)
        field = "wall_seconds" if "duration" in fifo_name else "bats_version"
        assert_that(document[field]).is_none()
    else:
        assert_that(capsys.readouterr().out).contains("is not a regular file")
        assert_that((tmp_path / OUTPUT).exists()).is_false()


# --- parse_tap / attribute -------------------------------------------------


def test_parse_tap_reads_plan_times_and_skips(mod: ModuleType, data: Path) -> None:
    """Timed lines per number; skips apart; untimed setup/teardown lines ignored."""
    report, _files = read_case(data, "edge")

    timings = mod.parse_tap(report)

    assert_that(timings.plan).is_equal_to(10)
    assert_that(timings.timed_ms).is_equal_to(
        {1: 215, 2: 3, 3: 111, 6: 2, 7: 2, 10: 3},
    )
    assert_that(timings.skipped).is_equal_to({4, 5})


def test_parse_tap_never_reads_a_time_from_a_skip_reason(
    mod: ModuleType,
    data: Path,
) -> None:
    """Real bats output: the reason "# in 999999 ms" of test 5 is not a time."""
    report, _files = read_case(data, "edge")
    line = next(row for row in report.splitlines() if row.startswith("ok 5 "))

    timings = mod.parse_tap(report)

    assert_that(line).ends_with("# skip diagnostic # in 999999 ms")
    assert_that(timings.timed_ms).does_not_contain_key(5)
    assert_that(sum(timings.timed_ms.values())).is_equal_to(336)


@pytest.mark.parametrize(
    ("tap", "message"),
    [
        pytest.param(None, "more than one plan line", id="concatenated"),
        pytest.param(
            "1..2\nok 1 a # in 3 ms\nok 1 a # in 3 ms\n",
            "test 1 has more than one result",
            id="timed-twice",
        ),
        pytest.param(
            "1..2\nok 1 a # skip\nok 1 a # in 3 ms\n",
            "test 1 has more than one result",
            id="skip-then-timed",
        ),
        pytest.param(
            "1..2\nok 1 a # in 3 ms\nok 1 a # skip\n",
            "test 1 has more than one result",
            id="timed-then-skip",
        ),
    ],
)
def test_parse_tap_rejects_two_reports_in_one(
    mod: ModuleType,
    data: Path,
    tap: str | None,
    message: str,
) -> None:
    """A report appended to itself would double the durations."""
    text = tap if tap is not None else read_case(data, "edge")[0] * 2

    with pytest.raises(mod.DurationsError, match=message):
        mod.parse_tap(text)


def test_parse_tap_reads_a_timed_out_test(mod: ModuleType) -> None:
    """A test stopped by BATS_TEST_TIMEOUT still carries its time."""
    tap = "1..1\nnot ok 1 slow # in 3001 ms # timeout after 3 s\n"

    timings = mod.parse_tap(tap)

    assert_that(timings.timed_ms).is_equal_to({1: 3001})


@pytest.mark.parametrize(
    "line",
    [
        pytest.param("ok 1 parser handles # skip directive in 221ms", id="pass"),
        pytest.param("ok 1 parser handles # skip in 5ms", id="name-ends-in-skip"),
        pytest.param("ok 1 parser handles # skip reason in 5ms", id="skip-reason"),
    ],
)
def test_parse_tap_never_reads_zero_from_an_ambiguous_skip(
    mod: ModuleType,
    line: str,
) -> None:
    """A skip-looking line with an " in Nms" end is neither timed nor skipped."""
    timings = mod.parse_tap(f"1..1\n{line}\n")

    assert_that(timings.timed_ms).is_empty()
    assert_that(timings.skipped).is_empty()
    assert_that(timings.ambiguous).is_equal_to({1})


def test_shard_command_lists_a_test_named_like_a_skip_as_missing(
    mod: ModuleType,
    data: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Real bats: "ok 1 ... # skip directive in 215ms" gives no value, never 0."""
    monkeypatch.chdir(data)
    report, _files = read_case(data, "skip-name")

    assert_that(mod.main(_shard_argv(tmp_path, "skip-name"))).is_equal_to(0)

    assert_that(report.splitlines()[1]).matches(
        r"^ok 1 parser handles # skip directive in \d+ms$",
    )
    document = read_json(tmp_path / OUTPUT)
    assert_that(document["durations"]).is_equal_to(
        {"sub/names/last.bats.txt": 0.002},
    )
    assert_that(document["missing"]).is_equal_to(["sub/names/skip-name.bats.txt"])


def test_attribute_repo_slice(mod: ModuleType, data: Path) -> None:
    """Real output of this repository's tests: every file gets its sum."""
    report, files = read_case(data, "repo-slice")
    tests = _unnamed(read_json(data / "repo-slice.counts.json"))

    durations, missing = mod.attribute(files, tests, mod.parse_tap(report))

    assert_that(durations).is_equal_to(SLICE_DURATIONS)
    assert_that(missing).is_empty()


def test_attribute_edge_cases(mod: ModuleType, tap: ModuleType, data: Path) -> None:
    """A failed setup_file leaves its file missing; skips add nothing."""
    report, files = read_case(data, "edge")
    tests = static_tests(tap, data, files)

    durations, missing = mod.attribute(files, tests, mod.parse_tap(report))

    assert_that(durations).is_equal_to(EDGE_DURATIONS)
    assert_that(missing).is_equal_to(["suite/setup-fails.bats.txt"])


def test_attribute_truncated_run_keeps_only_finished_files(
    mod: ModuleType,
    data: Path,
) -> None:
    """A run cut short after test 4 times the first file only."""
    report, files = read_case(data, "repo-slice")
    tests = _unnamed(read_json(data / "repo-slice.counts.json"))
    truncated = "\n".join(report.splitlines()[:5])

    durations, missing = mod.attribute(files, tests, mod.parse_tap(truncated))

    assert_that(durations).is_equal_to(
        {"tests/bats/unit/actions/test_harden_runner_platform.bats": 0.007},
    )
    assert_that(missing).is_equal_to(files[1:])


@pytest.mark.parametrize(
    ("tap", "tests", "message"),
    [
        pytest.param("", {"a.bats": ["a"]}, "no 1..N plan", id="empty"),
        pytest.param(
            "ok 1 a # in 3 ms\n",
            {"a.bats": ["a"]},
            "no 1..N plan",
            id="no-plan",
        ),
        pytest.param(
            "1..2\nok 1 a # in 3 ms\nok 2 b # in 3 ms\n",
            {"a.bats": ["a"]},
            "add up to 1, the TAP plan says 2",
            id="count-mismatch",
        ),
        pytest.param(
            "1..1\nok 1 a\n",
            {"a.bats": ["a"]},
            "without --timing",
            id="untimed",
        ),
        pytest.param(
            "1..1\nok 1 b # in 3 ms\n",
            {"a.bats": ["a"]},
            "test 1 should be 'a' of a.bats, the report says 'b'",
            id="name-mismatch",
        ),
        pytest.param(
            "1..1\nok 1 a # in 3 ms\n",
            {},
            "no test count for a.bats",
            id="uncounted",
        ),
    ],
)
def test_attribute_refuses_what_it_cannot_tie_to_files(
    mod: ModuleType,
    tap: str,
    tests: dict[str, list[str]],
    message: str,
) -> None:
    """Without a plan, counts, times or matching names, nothing is attributed."""
    with pytest.raises(mod.DurationsError, match=message):
        mod.attribute(["a.bats"], tests, mod.parse_tap(tap))


def test_attribute_all_skipped_file_is_zero(mod: ModuleType) -> None:
    """A skipped test carries no time in the report: it adds zero."""
    tap = "1..2\nok 1 skipped # skip no\nok 2 b # in 7 ms\n"

    durations, missing = mod.attribute(
        ["a.bats", "b.bats"],
        {"a.bats": ["skipped"], "b.bats": ["b"]},
        mod.parse_tap(tap),
    )

    assert_that(durations).is_equal_to({"a.bats": 0.0, "b.bats": 0.007})
    assert_that(missing).is_empty()


@pytest.mark.parametrize(
    ("path", "prefix", "expected"),
    [
        pytest.param("tests/a.bats", ".", "tests/a.bats", id="dot"),
        pytest.param("./tests/a.bats", "", "tests/a.bats", id="empty-prefix"),
        pytest.param("tests/a.bats", "sub/", "sub/tests/a.bats", id="prefixed"),
        pytest.param("/abs/a.bats", "sub", "/abs/a.bats", id="absolute"),
    ],
)
def test_repo_path(mod: ModuleType, path: str, prefix: str, expected: str) -> None:
    """Paths are made repo-relative and normalized."""
    assert_that(mod.repo_path(path, prefix)).is_equal_to(expected)


# --- shard command ----------------------------------------------------------


def _shard_argv(run_dir: Path, case: str, *extra: str) -> list[str]:
    """Build a ``shard`` command line for shard 1 of 2 of run 42, attempt 3.

    Args:
        run_dir: Where the run's side files (wall time, version, marker)
            and the output live.
        case: Fixture case name; its report and list are read from the
            current directory.
        *extra: More arguments.

    Returns:
        The argument vector.
    """
    return [
        "shard",
        "--tap",
        f"{case}.report.tap",
        "--files",
        f"{case}.files.txt",
        "--output",
        str(run_dir / OUTPUT),
        "--filter-marker",
        str(run_dir / "bats-filter-used.txt"),
        "--wall-ms-file",
        str(run_dir / "bats-duration-ms.txt"),
        "--bats-version-file",
        str(run_dir / "bats-version.txt"),
        "--shard-index",
        "1",
        "--shard-total",
        "2",
        "--sha",
        "abc123",
        "--run-id",
        "42",
        "--run-attempt",
        "3",
        "--path-prefix",
        "sub",
        *extra,
    ]


def _run_files(run_dir: Path) -> None:
    """Write the wall time and version files run-coverage leaves behind."""
    (run_dir / "bats-duration-ms.txt").write_text("2000\n", encoding="utf-8")
    (run_dir / "bats-version.txt").write_text("1.14.0\n", encoding="utf-8")


def test_shard_command_writes_the_document(
    mod: ModuleType,
    data: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The edge run gives four durations, one missing file and the run stamp."""
    monkeypatch.chdir(data)
    _run_files(tmp_path)

    assert_that(mod.main(_shard_argv(tmp_path, "edge"))).is_equal_to(0)

    edge_counts = read_json(data / "edge.counts.json")
    document = read_json(tmp_path / OUTPUT)
    assert_that(document).is_equal_to(
        {
            "schema_version": 1,
            "sha": "abc123",
            "run_id": 42,
            "run_attempt": 3,
            "shard_index": 1,
            "shard_total": 2,
            "bats_version": "1.14.0",
            "wall_seconds": 2.0,
            "test_counts": {f"sub/{k}": v for k, v in edge_counts.items()},
            "durations": {f"sub/{k}": v for k, v in EDGE_DURATIONS.items()},
            "missing": ["sub/suite/setup-fails.bats.txt"],
        },
    )
    assert_that(list(document["durations"])).is_sorted()
    assert_that(capsys.readouterr().out).contains(
        "::warning::bats-durations: shard 1/2: no complete results for "
        "sub/suite/setup-fails.bats.txt",
    )
    assert_that([p.name for p in (tmp_path / "out").iterdir()]).is_equal_to(
        ["bats-durations-shard.json"],
    )


def test_shard_command_without_side_files_records_nulls(
    mod: ModuleType,
    data: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No wall time or version file, or a malformed one: null, not a guess."""
    monkeypatch.chdir(data)
    (tmp_path / "bats-duration-ms.txt").write_text("12.5\n", encoding="utf-8")
    (tmp_path / "bats-version.txt").write_bytes(b"\xff\xfe")

    mod.main(_shard_argv(tmp_path, "edge"))

    document = read_json(tmp_path / OUTPUT)
    assert_that(document["wall_seconds"]).is_none()
    assert_that(document["bats_version"]).is_none()


def test_shard_command_empty_shard_writes_empty_durations(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An empty shard (empty file list, no report needed) records no files."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "empty.files.txt").write_text("", encoding="utf-8")
    (tmp_path / "bats-duration-ms.txt").write_text("0\n", encoding="utf-8")

    assert_that(mod.main(_shard_argv(tmp_path, "empty"))).is_equal_to(0)

    document = read_json(tmp_path / OUTPUT)
    assert_that(document["test_counts"]).is_empty()
    assert_that(document["durations"]).is_empty()
    assert_that(document["missing"]).is_empty()
    assert_that(document["wall_seconds"]).is_equal_to(0.0)


def test_shard_command_skips_a_filtered_run(
    mod: ModuleType,
    data: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The run-coverage filter marker: a notice, and no file (not even an old one)."""
    monkeypatch.chdir(data)
    (tmp_path / "bats-filter-used.txt").write_text("test-filter\n", encoding="utf-8")
    stale = tmp_path / OUTPUT
    stale.parent.mkdir()
    stale.write_text("{}", encoding="utf-8")

    assert_that(mod.main(_shard_argv(tmp_path, "edge"))).is_equal_to(0)

    assert_that(stale.exists()).is_false()
    assert_that(capsys.readouterr().out).is_equal_to(
        "::notice::bats-durations: shard 1/2: the run used a test filter; "
        "durations not recorded\n",
    )


def _write_case(run_dir: Path, tap: str | bytes | None, files: str | None) -> None:
    """Write a ``case`` report and file list into ``run_dir``."""
    if isinstance(tap, bytes):
        (run_dir / "case.report.tap").write_bytes(tap)
    elif tap is not None:
        (run_dir / "case.report.tap").write_text(tap, encoding="utf-8")
    if files is not None:
        (run_dir / "case.files.txt").write_text(files, encoding="utf-8")


_ONE_TEST = '@test "a" {\n  true\n}\n'


@pytest.mark.parametrize(
    ("report", "files", "warning"),
    [
        pytest.param(None, "a.bats\n", "case.report.tap; no durations", id="no-tap"),
        pytest.param("1..1\nok 1 a # in 3 ms\n", None, "did not start", id="no-list"),
        pytest.param("", "a.bats\n", "no 1..N plan", id="tap-empty"),
        pytest.param("\x00\x7f garbage", "a.bats\n", "no 1..N plan", id="tap-garbage"),
        pytest.param(
            "1..3\nok 1 a # in 3 ms\n",
            "a.bats\n",
            "TAP plan says 3",
            id="tap-truncated",
        ),
        pytest.param(
            "1..1\nok 1 a # in 3 ms\n1..1\nok 1 a # in 3 ms\n",
            "a.bats\n",
            "more than one plan line",
            id="tap-concatenated",
        ),
        pytest.param(
            "1..1\nok 1 a # in 3 ms\n",
            "gone.bats\n",
            "test file gone.bats not found",
            id="listed-file-gone",
        ),
        pytest.param(
            "1..1\nok 1 a # in 3 ms\n",
            "binary.bats\n",
            "add up to 0, the TAP plan says 1",
            id="binary-file",
        ),
        pytest.param(
            "1..1\nok 1 a # in 3 ms\n",
            "huge.bats\n",
            "too large to read",
            id="huge-file",
        ),
    ],
)
def test_shard_command_never_fails(  # pylint: disable=too-many-arguments
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    *,
    tap: ModuleType,
    report: str | None,
    files: str | None,
    warning: str,
) -> None:
    """Missing, empty, malformed or doubled input: warning, exit 0, no file."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(tap, "MAX_TEST_FILE_BYTES", 4096)
    (tmp_path / "a.bats").write_text(_ONE_TEST, encoding="utf-8")
    (tmp_path / "binary.bats").write_bytes(bytes(range(256)) * 4)
    (tmp_path / "huge.bats").write_text(_ONE_TEST * 1000, encoding="utf-8")
    _write_case(tmp_path, report, files)
    stale = tmp_path / OUTPUT
    stale.parent.mkdir()
    stale.write_text('{"stale": true}', encoding="utf-8")

    code = mod.main(_shard_argv(tmp_path, "case"))

    assert_that(code).is_equal_to(0)
    output = capsys.readouterr().out
    assert_that(output).starts_with("::warning::bats-durations: ").contains(warning)
    assert_that(list((tmp_path / "out").iterdir())).is_empty()


@pytest.mark.parametrize(
    ("case", "warning"),
    [
        pytest.param("dynamic", "registers tests at run time", id="dynamic"),
        pytest.param(
            "heredoc",
            "count/heredoc.bats.txt:4: a test definition inside heredoc text",
            id="heredoc",
        ),
        pytest.param(
            "heredoc-load",
            "names/a-heredoc.bats.txt:4: a test definition inside heredoc text",
            id="heredoc-and-load",
        ),
        pytest.param(
            "heredoc-library",
            "names/a-heredoc.bats.txt:4: a test definition inside heredoc text",
            id="heredoc-and-bats-load-library",
        ),
        pytest.param(
            "heredoc-aligned",
            "names/a-heredoc-late.bats.txt:8: a test definition inside heredoc text",
            id="heredoc-names-line-up-with-a-helper-test",
        ),
        pytest.param(
            "dead-load",
            "test 1 should be 'phantom in dead code' of names/a-dead.bats.txt, "
            "the report says 'a real test'",
            id="dead-code-and-load",
        ),
    ],
)
# pylint: disable-next=too-many-arguments
def test_shard_command_records_nothing_when_counts_differ_from_bats(
    mod: ModuleType,
    data: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    *,
    case: str,
    warning: str,
) -> None:
    """Real runs of files bats counts differently: no data, never wrong data.

    ``heredoc-aligned`` is the case the count and name checks cannot catch:
    the heredoc test of the first file has the name of the test a helper
    loaded by the second file registers, so static counts 2 + 1 and real
    counts 1 + 2 add up alike and every name lines up.
    """
    monkeypatch.chdir(data)

    assert_that(mod.main(_shard_argv(tmp_path, case))).is_equal_to(0)

    assert_that(capsys.readouterr().out).contains(warning)
    assert_that((tmp_path / OUTPUT).exists()).is_false()


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads any file")
def test_shard_command_survives_an_unreadable_test_file(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A test file that cannot be read: warning, exit 0, no file."""
    monkeypatch.chdir(tmp_path)
    locked = tmp_path / "a.bats"
    locked.write_text(_ONE_TEST, encoding="utf-8")
    _write_case(tmp_path, "1..1\nok 1 a # in 3 ms\n", "a.bats\n")
    locked.chmod(0)
    try:
        assert_that(mod.main(_shard_argv(tmp_path, "case"))).is_equal_to(0)
    finally:
        locked.chmod(0o644)

    assert_that(capsys.readouterr().out).contains("cannot read test file a.bats")
    assert_that((tmp_path / OUTPUT).exists()).is_false()


def test_shard_command_reads_undecodable_bytes(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Invalid UTF-8 in the TAP (test output) does not stop the parse."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "a.bats").write_text(_ONE_TEST, encoding="utf-8")
    _write_case(tmp_path, b"1..1\n# \xff\xfe\nok 1 a # in 3 ms\n", "a.bats\n")

    assert_that(mod.main(_shard_argv(tmp_path, "case"))).is_equal_to(0)

    assert_that(read_json(tmp_path / OUTPUT)["durations"]).is_equal_to(
        {"sub/a.bats": 0.003},
    )


def test_shard_command_survives_an_unexpected_error(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Even a bug in the script ends in a warning and exit 0."""

    def boom(_text: str) -> None:
        raise RuntimeError("unexpected")

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(mod, "parse_tap", boom)
    (tmp_path / "a.bats").write_text(_ONE_TEST, encoding="utf-8")
    _write_case(tmp_path, "1..1\n", "a.bats\n")

    assert_that(mod.main(_shard_argv(tmp_path, "case"))).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains("shard failed: unexpected")


def test_write_json_replaces_atomically(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A failed rename leaves neither a partial file nor a temporary one."""
    target = tmp_path / "out.json"

    def fail(_source: str, _target: Path) -> None:
        raise OSError("disk full")

    monkeypatch.setattr(mod.os, "replace", fail)
    with pytest.raises(OSError, match="disk full"):
        mod.write_json(target, {"a": 1})

    assert_that(list(tmp_path.iterdir())).is_empty()


def test_write_json_output_is_canonical(mod: ModuleType, tmp_path: Path) -> None:
    """Sorted keys, two-space indent, final newline, readable by everyone."""
    target = tmp_path / "out.json"

    mod.write_json(target, {"b": 1, "a": [2]})

    assert_that(target.read_text(encoding="utf-8")).is_equal_to(
        '{\n  "a": [\n    2\n  ],\n  "b": 1\n}\n',
    )
    assert_that(target.stat().st_mode & 0o777).is_equal_to(0o644)


@pytest.mark.parametrize(
    "argv",
    [
        pytest.param(["--shard-index", "-1"], id="negative-index"),
        pytest.param(["--shard-total", "0"], id="zero-total"),
        pytest.param(["--shard-total", "x"], id="text-total"),
        pytest.param(["--run-id", "local"], id="text-run-id"),
        pytest.param(["--run-attempt", "0"], id="zero-attempt"),
        pytest.param(["--sha", " "], id="blank-sha"),
    ],
)
def test_shard_command_rejects_bad_arguments(
    mod: ModuleType,
    tmp_path: Path,
    argv: list[str],
) -> None:
    """Bad coordinates are a usage error (exit 2), caught by continue-on-error."""
    with pytest.raises(SystemExit) as exit_info:
        mod.main(_shard_argv(tmp_path, "case", *argv))

    assert_that(exit_info.value.code).is_equal_to(2)
