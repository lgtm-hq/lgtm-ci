# SPDX-License-Identifier: MIT
"""Shared helpers of the ``bats-durations.py`` tests (fixture reading)."""

from __future__ import annotations

import json
from pathlib import Path
from types import ModuleType
from typing import Any

__all__ = ["SCRIPT_PATH", "read_case", "read_json", "static_tests"]

SCRIPT_PATH = "scripts/ci/actions/bats-durations.py"


def read_json(path: Path) -> dict[str, Any]:
    """Read a JSON object fixture.

    Args:
        path: The JSON file.

    Returns:
        The decoded object.
    """
    document: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return document


def read_case(data: Path, name: str) -> tuple[str, list[str]]:
    """Read one fixture case: report TAP and run-ordered file list.

    Args:
        data: The bats-durations fixture directory.
        name: The case name.

    Returns:
        The report text and the file list.
    """
    tap = (data / f"{name}.report.tap").read_text(encoding="utf-8")
    files = (data / f"{name}.files.txt").read_text(encoding="utf-8").split()
    return tap, files


def static_tests(
    tap: ModuleType,
    data: Path,
    files: list[str],
) -> dict[str, list[str | None]]:
    """Read each fixture file's test names statically.

    Args:
        tap: The ``bats_durations_tap`` module.
        data: The bats-durations fixture directory.
        files: Fixture-relative test file paths.

    Returns:
        Each path's static test names.
    """
    return {path: tap.read_tests(data / path) for path in files}
