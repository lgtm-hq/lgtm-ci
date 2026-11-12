# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/lib/playwright_deps.py`` (#1432).

Fixtures in ``tests/fixtures/playwright-deps`` follow the two dry-run formats
in the ``playwright-core`` npm sources:

- ``dry-run-1.63.0-missing.txt``: ``reportMissingDependenciesLinux`` of
  1.63.0 (the version locked in the consumer fixture's ``playwright/bun.lock``),
  with the ``ubuntu26.04-x64`` ``tools`` and ``chromium`` package lists of
  that version all missing. A real run lists what ``apt-get install -s``
  reports, so it can also name transitive dependencies; the format is the
  same.
- ``dry-run-1.63.0-all-installed.txt``: the same function with nothing
  missing.
- ``dry-run-1.56.0-command.txt``: ``installDependenciesLinux`` of 1.56.0 (the
  command format, used up to 1.59), as a non-root user with sudo, for the
  ``ubuntu24.04-x64`` lists.
"""

from __future__ import annotations

import io
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/lib/playwright_deps.py"
LEGACY = 'sudo -- sh -c "apt-get update&& apt-get install -y --no-install-recommends'
INSTALL = "apt-get update&& apt-get install -y --no-install-recommends"


@pytest.fixture(name="deps")
def fixture_deps(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the parser without running it."""
    return load_script(SCRIPT_PATH)


def _fixture(fixtures_dir: Path, name: str) -> str:
    """Return one dry-run fixture."""
    return (fixtures_dir / "playwright-deps" / name).read_text("utf-8")


def test_missing_format_of_1_63(deps: ModuleType, fixtures_dir: Path) -> None:
    """1.60+ prints the missing packages and exits 1."""
    packages = deps.parse(_fixture(fixtures_dir, "dry-run-1.63.0-missing.txt"), 1)

    assert_that(packages).is_length(33)
    assert_that(packages).contains("libnss3", "xvfb", "fonts-noto-color-emoji")
    assert_that(packages).is_equal_to(sorted(packages))


def test_all_installed_format_of_1_63(deps: ModuleType, fixtures_dir: Path) -> None:
    """Nothing missing: an empty list, which installs nothing."""
    text = _fixture(fixtures_dir, "dry-run-1.63.0-all-installed.txt")

    assert_that(deps.parse(text, 0)).is_empty()


def test_command_format_of_1_56(deps: ModuleType, fixtures_dir: Path) -> None:
    """Up to 1.59 the dry run prints the apt command and exits 0."""
    packages = deps.parse(_fixture(fixtures_dir, "dry-run-1.56.0-command.txt"), 0)

    assert_that(packages).is_length(33)
    assert_that(packages[0]).is_equal_to("libasound2t64")
    assert_that(packages).contains("libatk-bridge2.0-0t64", "xvfb")


@pytest.mark.parametrize(
    "prefix",
    ["sh -c ", "su root -c "],
)
def test_command_format_as_root_or_su(deps: ModuleType, prefix: str) -> None:
    """The root and ``su`` forms of the command are read the same way."""
    line = f'{prefix}"{INSTALL} a1 b2"'

    assert_that(deps.parse(line, 0)).is_equal_to(["a1", "b2"])


def test_warning_lines_around_the_result_are_ignored(deps: ModuleType) -> None:
    """Playwright's own warnings (stderr, merged) do not hide the result."""
    text = (
        "BEWARE: your OS is not officially supported by Playwright;"
        " installing dependencies for ubuntu24.04-x64 as a fallback.\n"
        "Missing system dependencies (1):\n"
        "  libnss3\n"
    )

    assert_that(deps.parse(text, 1)).is_equal_to(["libnss3"])


@pytest.mark.parametrize(
    ("text", "code"),
    [
        ("", 0),
        ("Error: 'apt-get install -s' exited with code 100:\nE: no lists\n", 1),
        ("Missing system dependencies (2):\n  libnss3\n", 1),
        ("Missing system dependencies (1):\n  libnss3\n", 0),
        ("Missing system dependencies (1):\n  -oDPkg::Pre-Invoke=x\n", 1),
        ("Missing system dependencies (1):\n  Libnss3\n", 1),
        ("Missing system dependencies (1):\n  curl-\n", 1),
        ("Missing system dependencies (1):\n  foo=1.0\n", 1),
        ("Missing system dependencies (1):\n  foo/resolute\n", 1),
        ("Missing system dependencies (1):\n  foo:amd64\n", 1),
        ("All system dependencies are installed.\n", 1),
        ("Cannot install dependencies for ubuntu99-x64 with Playwright 1.63.0!\n", 0),
        (f'{LEGACY} "', 0),
        (f'{LEGACY} a;b"', 0),
        (f'{LEGACY} ab"', 2),
        (
            "All system dependencies are installed.\n"
            "Missing system dependencies (1):\n  libnss3\n",
            1,
        ),
    ],
)
def test_unrecognised_output_is_rejected(
    deps: ModuleType,
    text: str,
    code: int,
) -> None:
    """Anything but one well-formed result with the right exit code is refused."""
    with pytest.raises(deps.Unrecognised):
        deps.parse(text, code)


def test_cli_prints_one_package_per_line(
    deps: ModuleType,
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The CLI reads stdin and prints the packages."""
    text = _fixture(fixtures_dir, "dry-run-1.63.0-missing.txt")
    monkeypatch.setattr("sys.stdin", io.StringIO(text))

    code = deps.main(["--exit-code", "1"])

    assert_that(code).is_equal_to(0)
    assert_that(capsys.readouterr().out.split()).is_length(33)


def test_cli_exits_1_on_unrecognised_output(
    deps: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Unrecognised output prints nothing on stdout and exits 1."""
    monkeypatch.setattr("sys.stdin", io.StringIO("something else\n"))

    code = deps.main(["--exit-code", "0"])

    captured = capsys.readouterr()
    assert_that(code).is_equal_to(1)
    assert_that(captured.out).is_empty()
    assert_that(captured.err).contains("unrecognised dry-run output")


def test_trailing_plus_is_a_valid_package_name(deps: ModuleType) -> None:
    """``g++`` ends in ``+``, which apt reads as install, not remove."""
    text = "Missing system dependencies (2):\n  g++\n  libnss3\n"

    assert_that(deps.parse(text, 1)).is_equal_to(["g++", "libnss3"])
