# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/workflows/validate_comment_history_facades.py``.

A facade is a ``reusable-*.yml`` that calls a ``reusable-publish-*.yml``
declaring ``comment-history``. The validator exits 1 and names each facade
that does not declare and forward both ``comment-history`` and
``comment-history-limit`` (#1365), and exits 1 when no publisher declares
the input at all.
"""

from __future__ import annotations

import runpy
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/workflows/validate_comment_history_facades.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
PUBLISHER = "reusable-publish-comment.yml"
PUBLISHER_TEXT = (
    "on:\n  workflow_call:\n    inputs:\n"
    "      comment-history:\n        type: boolean\n"
    "      comment-history-limit:\n        type: number\n"
)
DECLARES = (
    "on:\n  workflow_call:\n    inputs:\n"
    "      comment-history:\n        type: boolean\n"
    "      comment-history-limit:\n        type: number\n"
)
FORWARDS = (
    "      comment-history: ${{ inputs.comment-history }}\n"
    "      comment-history-limit: ${{ inputs.comment-history-limit }}\n"
)


@pytest.fixture(name="validator", scope="module")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator once per module."""
    return load_script(SCRIPT)


def facade(declares: str = DECLARES, forwards: str = FORWARDS) -> str:
    """Render a facade calling the publisher with the given blocks."""
    return (
        declares
        + "jobs:\n  publish:\n"
        + f"    uses: ./.github/workflows/{PUBLISHER}\n"
        + "    with:\n"
        + forwards
    )


def make_workflows(tmp_path: Path, files: dict[str, str]) -> Path:
    """Write workflow files into a fresh directory and return it."""
    for name, text in files.items():
        (tmp_path / name).write_text(text, encoding="utf-8")
    return tmp_path


def test_conforming_facade_passes(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A facade that declares and forwards both inputs is accepted."""
    workflows = make_workflows(
        tmp_path,
        {PUBLISHER: PUBLISHER_TEXT, "reusable-test.yml": facade()},
    )

    assert_that(validator.main(workflows)).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_empty()


@pytest.mark.parametrize(
    ("text", "problems"),
    [
        (
            facade(declares="on:\n  workflow_call:\n"),
            [
                "does not declare comment-history",
                "does not declare comment-history-limit",
            ],
        ),
        (
            facade(forwards=""),
            [
                "does not forward comment-history",
                "does not forward comment-history-limit",
            ],
        ),
        (
            facade(
                forwards="      comment-history: ${{ inputs.comment-history }}\n"
                "      comment-history-limit: 5\n",
            ),
            ["does not forward comment-history-limit"],
        ),
        (
            facade(
                declares="      comment-history: true\n",
                forwards="",
            ),
            [
                "does not declare comment-history",
                "does not forward comment-history",
                "does not declare comment-history-limit",
                "does not forward comment-history-limit",
            ],
        ),
    ],
)
def test_facade_problems_are_named(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    text: str,
    problems: list[str],
) -> None:
    """Each missing declaration or forward is one line naming the facade."""
    workflows = make_workflows(
        tmp_path,
        {PUBLISHER: PUBLISHER_TEXT, "reusable-test.yml": text},
    )

    assert_that(validator.main(workflows)).is_equal_to(1)
    expected = "".join(f"reusable-test.yml: {problem}\n" for problem in problems)
    assert_that(capsys.readouterr().out).is_equal_to(expected)


def test_every_failing_facade_is_reported_in_name_order(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Problems from several facades are all printed, sorted by file."""
    broken = facade(forwards="")
    workflows = make_workflows(
        tmp_path,
        {
            PUBLISHER: PUBLISHER_TEXT,
            "reusable-z.yml": broken,
            "reusable-a.yml": broken,
            "reusable-ok.yml": facade(),
        },
    )

    assert_that(validator.main(workflows)).is_equal_to(1)
    names = [line.split(":")[0] for line in capsys.readouterr().out.splitlines()]
    assert_that(names).is_equal_to(["reusable-a.yml"] * 2 + ["reusable-z.yml"] * 2)


def test_workflows_not_calling_a_history_publisher_are_ignored(
    validator: ModuleType,
    tmp_path: Path,
) -> None:
    """Callers of other publishers, and non-reusable files, are not facades."""
    other_publisher = "on:\n  workflow_call:\n    inputs:\n      title:\n"
    calls_other = "jobs:\n  p:\n    uses: ./.github/workflows/reusable-publish-x.yml\n"
    workflows = make_workflows(
        tmp_path,
        {
            PUBLISHER: PUBLISHER_TEXT,
            "reusable-publish-x.yml": other_publisher,
            "reusable-calls-other.yml": calls_other,
            "ci.yml": facade(forwards=""),
        },
    )

    assert_that(validator.main(workflows)).is_equal_to(0)


@pytest.mark.parametrize(
    "files",
    [
        {},
        {"reusable-publish-x.yml": "on:\n  workflow_call:\n"},
        {"reusable-publish-x.yml": "    comment-history:\n"},
    ],
)
def test_no_history_publisher_is_an_error(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    files: dict[str, str],
) -> None:
    """Without a publisher declaring the input the check would be vacuous."""
    workflows = make_workflows(tmp_path, files)

    assert_that(validator.main(workflows)).is_equal_to(1)
    assert_that(capsys.readouterr().out).is_equal_to(
        "no publisher declares comment-history\n",
    )


def test_the_repository_facades_conform(validator: ModuleType) -> None:
    """Ported from tests/bats/integration/test_reusable_pr_comment_split.bats."""
    assert_that(validator.main(PROJECT_ROOT / ".github" / "workflows")).is_equal_to(0)


def test_runs_as_a_script(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Run as ``__main__``, the validator exits with ``main``'s status."""
    workflows = make_workflows(tmp_path, {"reusable-a.yml": "on: push\n"})
    monkeypatch.setattr(sys, "argv", ["validate.py", str(workflows)])

    with pytest.raises(SystemExit) as exc_info:
        runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("no publisher declares")
