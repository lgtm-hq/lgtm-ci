# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/release/ecosystems/read-rust-toolchain.py``.

``rust.sh`` asks this reader which toolchain a ``rust-toolchain.toml`` (or a
legacy one-line ``rust-toolchain``) file selects. Each documented exit status
is checked: 0 with the channel (possibly empty), 1 for usage or read errors,
3 for a ``[toolchain] path`` toolchain and 4 for a file it cannot understand.
"""

from __future__ import annotations

import runpy
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import NamedTuple

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/release/ecosystems/read-rust-toolchain.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]


class Outcome(NamedTuple):
    """Exit status and captured output of one ``main`` run."""

    status: int
    out: str
    err: str


Runner = Callable[..., Outcome]


@pytest.fixture(name="reader", scope="module")
def fixture_reader(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the reader once per module."""
    return load_script(SCRIPT)


@pytest.fixture(name="run")
def fixture_run(
    reader: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> Runner:
    """Return a runner: ``run(*args)`` calls ``main`` with ``args``."""

    def _run(*args: str) -> Outcome:
        monkeypatch.setattr(sys, "argv", ["read-rust-toolchain.py", *args])
        status = 0
        try:
            reader.main()
        except SystemExit as exc:
            status = int(exc.code or 0)
        captured = capsys.readouterr()
        return Outcome(status=status, out=captured.out, err=captured.err)

    return _run


def write(directory: Path, name: str, text: str) -> Path:
    """Write ``text`` to ``directory/name`` and return the path."""
    path = directory / name
    path.write_text(text, encoding="utf-8")
    return path


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ('[toolchain]\nchannel = "1.80.0"\n', "1.80.0"),
        ('[toolchain]\nchannel = "nightly-2024-05-01"\n', "nightly-2024-05-01"),
        ('[toolchain]\ncomponents = ["clippy"]\n', ""),
        ('[package]\nname = "x"\n', ""),
        ("", ""),
    ],
)
def test_prints_the_toml_channel(
    run: Runner,
    tmp_path: Path,
    text: str,
    expected: str,
) -> None:
    """The channel is printed, or an empty line when the file names none."""
    path = write(tmp_path, "rust-toolchain.toml", text)

    assert_that(run(str(path))).is_equal_to(Outcome(0, f"{expected}\n", ""))


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("stable\n", "stable"),
        ("1.79.0", "1.79.0"),
        ("\n  nightly-2024-01-01  \n\n", "nightly-2024-01-01"),
        ("\n\n", ""),
    ],
)
def test_reads_a_legacy_one_line_file(
    reader: ModuleType,
    tmp_path: Path,
    text: str,
    expected: str,
) -> None:
    """A legacy ``rust-toolchain`` file is one toolchain name, blanks aside."""
    path = write(tmp_path, "rust-toolchain", text)

    assert_that(reader.read_channel(path)).is_equal_to(expected)


def test_legacy_file_with_two_names_is_not_understood(
    run: Runner,
    tmp_path: Path,
) -> None:
    """More than one line in a legacy file exits 4, printing nothing."""
    path = write(tmp_path, "rust-toolchain", "stable\nnightly\n")

    outcome = run(str(path))

    assert_that(outcome.status).is_equal_to(4)
    assert_that(outcome.out).is_empty()
    assert_that(outcome.err).contains(f"ERROR: cannot parse {path}")


def test_one_line_non_toml_is_legacy_only_without_the_suffix(
    run: Runner,
    tmp_path: Path,
) -> None:
    """A ``.toml`` file must be TOML even when it holds a single name."""
    path = write(tmp_path, "rust-toolchain.toml", "stable\n")

    outcome = run(str(path))

    assert_that(outcome.status).is_equal_to(4)
    assert_that(outcome.err).contains("cannot parse")


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ('[toolchain\nchannel = "1.80.0"\n', "cannot parse"),
        ("[toolchain]\nchannel = 1.80\n", "channel is not a string"),
        ('[toolchain]\nchannel = ["stable"]\n', "channel is not a string"),
        ('toolchain = "stable"\n', "[toolchain] is not a table"),
    ],
)
def test_malformed_files_exit_4(
    run: Runner,
    tmp_path: Path,
    text: str,
    message: str,
) -> None:
    """Bad TOML, a non-string channel or a non-table toolchain exit 4."""
    path = write(tmp_path, "rust-toolchain.toml", text)

    outcome = run(str(path))

    assert_that(outcome.status).is_equal_to(4)
    assert_that(outcome.out).is_empty()
    assert_that(outcome.err).starts_with("ERROR: ").contains(message)


@pytest.mark.parametrize(
    "text",
    [
        '[toolchain]\npath = "/opt/rust"\n',
        '[toolchain]\nchannel = "stable"\npath = "toolchains/custom"\n',
    ],
)
def test_path_toolchain_exits_3(run: Runner, tmp_path: Path, text: str) -> None:
    """A toolchain from the checkout exits 3, even next to a channel."""
    path = write(tmp_path, "rust-toolchain.toml", text)

    outcome = run(str(path))

    assert_that(outcome.status).is_equal_to(3)
    assert_that(outcome.out).is_empty()
    assert_that(outcome.err).contains("sets [toolchain] path")


@pytest.mark.parametrize("args", [(), ("a", "b")])
def test_wrong_argument_count_is_a_usage_error(
    run: Runner,
    args: tuple[str, ...],
) -> None:
    """Anything but one argument prints usage and exits 1."""
    outcome = run(*args)

    assert_that(outcome.status).is_equal_to(1)
    assert_that(outcome.out).is_empty()
    assert_that(outcome.err).starts_with("Usage: ")


@pytest.mark.parametrize("name", ["missing.toml", ""])
def test_unreadable_path_exits_1(run: Runner, tmp_path: Path, name: str) -> None:
    """A missing file, or a directory, cannot be read: exit 1."""
    path = tmp_path / name

    outcome = run(str(path))

    assert_that(outcome.status).is_equal_to(1)
    assert_that(outcome.out).is_empty()
    assert_that(outcome.err).starts_with(f"ERROR: cannot read {path}")


def test_file_that_is_not_utf8_exits_1(run: Runner, tmp_path: Path) -> None:
    """Bytes that are not UTF-8 cannot be read: exit 1 with one error line."""
    path = tmp_path / "rust-toolchain.toml"
    path.write_bytes(b'[toolchain]\nchannel = "\xff\xfe"\n')

    outcome = run(str(path))

    assert_that(outcome.status).is_equal_to(1)
    assert_that(outcome.out).is_empty()
    assert_that(outcome.err).starts_with(f"ERROR: cannot read {path}")


def test_unicode_channel_is_printed_verbatim(
    reader: ModuleType,
    tmp_path: Path,
) -> None:
    """The reader does not validate the channel; ``rust.sh`` does."""
    path = write(tmp_path, "rust-toolchain.toml", '[toolchain]\nchannel = "ståble"\n')

    assert_that(reader.read_channel(path)).is_equal_to("ståble")


def test_runs_as_a_script(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Run as ``__main__``, the reader prints the channel and exits normally."""
    path = write(tmp_path, "rust-toolchain.toml", '[toolchain]\nchannel = "1.81"\n')
    monkeypatch.setattr(sys, "argv", ["read-rust-toolchain.py", str(path)])

    runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(capsys.readouterr().out).is_equal_to("1.81\n")
