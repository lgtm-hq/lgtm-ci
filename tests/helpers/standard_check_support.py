# SPDX-License-Identifier: MIT
"""Shared helpers for the tests of the test-standard check (#1625).

The tests build a throwaway repository under ``tmp_path``, write test files
into it and read back what ``validate_test_standard.py`` reports.
"""

from __future__ import annotations

from pathlib import Path
from types import ModuleType

from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/quality/validate_test_standard.py"


def source(*lines: str) -> str:
    """Join source lines into a file's text, with a final newline."""
    return "\n".join(lines) + "\n"


def empty_repo(root: Path) -> None:
    """Give a repository root an empty ``tests/`` directory."""
    (root / "tests").mkdir()


def write(repo: Path, relative: str, text: str) -> None:
    """Write one file into the repository, creating its directories."""
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def rendered(check: ModuleType, repo: Path) -> list[str]:
    """Return every offence in the repository as ``file:line: [rule] what``."""
    offences, errors = check.check(repo)
    assert_that(errors).is_empty()
    return [offence.render() for offence in offences]
