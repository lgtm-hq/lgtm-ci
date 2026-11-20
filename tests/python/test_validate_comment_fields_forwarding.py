# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/workflows/validate_comment_fields_forwarding.py`` (#1677).

A reusable workflow that posts through the ``post-pr-comment`` action or
``post-pr-comment.sh`` (``STEP: post``), or calls a workflow that declares
``comment-fields``, must declare the input and pass it on at every such step
or call; the action must declare it and set ``COMMENT_FIELDS``. Each miss is
one line naming the file (and the step or job line); the run exits 1.
"""

from __future__ import annotations

import runpy
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/workflows/validate_comment_fields_forwarding.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
ACTION = (
    "inputs:\n"
    "  comment-fields:\n"
    "    default: ''\n"
    "runs:\n"
    "  steps:\n"
    "    - name: Post comment\n"
    "      env:\n"
    "        COMMENT_FIELDS: ${{ inputs.comment-fields }}\n"
)
DECLARES_LINES = (
    "on:",
    "  workflow_call:",
    "    inputs:",
    "      comment-fields:",
    "        type: string",
)
DECLARES = "".join(line + "\n" for line in DECLARES_LINES)
SCRIPT_MISS = "post-pr-comment.sh post step does not set COMMENT_FIELDS"
CALL_MISS = "call to reusable-publish-a.yml does not forward comment-fields"
STEP_MISS = "post-pr-comment step does not pass comment-fields"
FORWARD_WITH = "          comment-fields: ${{ inputs.comment-fields }}\n"
FORWARD_ENV = "          COMMENT_FIELDS: ${{ inputs.comment-fields }}\n"


@pytest.fixture(name="validator", scope="module")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator once per module."""
    return load_script(SCRIPT)


def action_publisher(declares: str = DECLARES, forward: str = FORWARD_WITH) -> str:
    """A publisher posting through the action."""
    return (
        declares
        + "jobs:\n  publish:\n    steps:\n"
        + "      - name: Post\n"
        + "        uses: ./.lgtm-ci-tooling/.github/actions/post-pr-comment\n"
        + "        with:\n          marker: m\n"
        + forward
    )


def script_publisher(declares: str = DECLARES, forward: str = FORWARD_ENV) -> str:
    """A publisher running the poster script: pr-number, then post."""
    return (
        declares
        + "jobs:\n  publish:\n    steps:\n"
        + "      - name: Detect\n        env:\n          STEP: pr-number\n"
        + "        run: bash .lgtm-ci-tooling/scripts/ci/actions/post-pr-comment.sh\n"
        + "      - name: Post\n        env:\n          STEP: post\n"
        + forward
        + "        run: bash .lgtm-ci-tooling/scripts/ci/actions/post-pr-comment.sh\n"
    )


def wrapper(callee: str, declares: str = DECLARES, forward: bool = True) -> str:
    """A wrapper calling ``callee`` as a job."""
    text = declares + "jobs:\n  publish:\n"
    text += f"    uses: ./.github/workflows/{callee}\n"
    text += "    with:\n      comment-marker: m\n"
    if forward:
        text += "      comment-fields: ${{ inputs.comment-fields }}\n"
    return text


def make_repo(tmp_path: Path, files: dict[str, str], action: str = ACTION) -> Path:
    """Write the action and workflow files into a fresh repository root."""
    action_dir = tmp_path / ".github" / "actions" / "post-pr-comment"
    action_dir.mkdir(parents=True)
    (action_dir / "action.yml").write_text(action, encoding="utf-8")
    workflows = tmp_path / ".github" / "workflows"
    workflows.mkdir(parents=True)
    for name, text in files.items():
        (workflows / name).write_text(text, encoding="utf-8")
    return tmp_path


def test_conforming_repository_passes(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Both publisher kinds and a wrapper that declare and pass the input pass."""
    root = make_repo(
        tmp_path,
        {
            "reusable-publish-a.yml": action_publisher(),
            "reusable-publish-b.yml": script_publisher(),
            "reusable-test.yml": wrapper("reusable-publish-a.yml"),
        },
    )

    assert_that(validator.main(root)).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_empty()


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        pytest.param(
            {"reusable-publish-a.yml": action_publisher(forward="")},
            [
                " ".join(("reusable-publish-a.yml:9:", STEP_MISS)),
            ],
            id="action-step-without-forward",
        ),
        pytest.param(
            {
                "reusable-publish-a.yml": action_publisher(
                    declares="on: workflow_call\n",
                ),
            },
            ["reusable-publish-a.yml: does not declare comment-fields"],
            id="action-publisher-without-input",
        ),
        pytest.param(
            {"reusable-publish-b.yml": script_publisher(forward="")},
            [
                " ".join(("reusable-publish-b.yml:13:", SCRIPT_MISS)),
            ],
            id="script-post-step-without-env",
        ),
        pytest.param(
            {
                "reusable-publish-a.yml": action_publisher(),
                "reusable-test.yml": wrapper("reusable-publish-a.yml", forward=False),
            },
            [
                " ".join(("reusable-test.yml:7:", CALL_MISS)),
            ],
            id="wrapper-without-forward",
        ),
        pytest.param(
            {
                "reusable-publish-a.yml": action_publisher(),
                "reusable-test.yml": wrapper(
                    "reusable-publish-a.yml",
                    declares="on: workflow_call\n",
                ),
            },
            ["reusable-test.yml: does not declare comment-fields"],
            id="wrapper-without-input",
        ),
    ],
)
def test_each_miss_is_named(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    files: dict[str, str],
    expected: list[str],
) -> None:
    """A step, call or declaration that is missing is one line, and exit 1."""
    root = make_repo(tmp_path, files)

    assert_that(validator.main(root)).is_equal_to(1)
    assert_that(capsys.readouterr().out.splitlines()).is_equal_to(expected)


def test_pr_number_and_read_steps_need_no_forward(
    validator: ModuleType,
    tmp_path: Path,
) -> None:
    """Only the post step of the script carries the fields."""
    root = make_repo(tmp_path, {"reusable-publish-b.yml": script_publisher()})

    assert_that(validator.main(root)).is_equal_to(0)


def test_calls_to_workflows_without_the_input_are_ignored(
    validator: ModuleType,
    tmp_path: Path,
) -> None:
    """Calls to workflows that do not post, and callers, are not checked."""
    root = make_repo(
        tmp_path,
        {
            "reusable-publish-a.yml": action_publisher(),
            "reusable-other.yml": "on: workflow_call\njobs: {}\n",
            "reusable-calls-other.yml": wrapper(
                "reusable-other.yml",
                declares="on: workflow_call\n",
                forward=False,
            ),
            "ci.yml": wrapper(
                "reusable-publish-a.yml",
                declares="on: push\n",
                forward=False,
            ),
        },
    )

    assert_that(validator.main(root)).is_equal_to(0)


@pytest.mark.parametrize(
    ("action", "expected"),
    [
        (
            ACTION.replace("  comment-fields:\n", "  other:\n"),
            "action.yml: does not declare comment-fields",
        ),
        (
            ACTION.replace("COMMENT_FIELDS", "FIELDS"),
            "does not pass comment-fields to its post step as COMMENT_FIELDS",
        ),
    ],
)
def test_the_action_must_take_and_pass_the_input(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    action: str,
    expected: str,
) -> None:
    """The action declares the input and sets COMMENT_FIELDS for the poster."""
    root = make_repo(
        tmp_path,
        {"reusable-publish-a.yml": action_publisher()},
        action=action,
    )

    assert_that(validator.main(root)).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains(expected)


def test_no_poster_is_an_error(
    validator: ModuleType,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Without any posting workflow the check would be vacuous."""
    root = make_repo(tmp_path, {"reusable-x.yml": "on: workflow_call\n"})

    assert_that(validator.main(root)).is_equal_to(1)
    out = capsys.readouterr().out
    assert_that(out).contains("no reusable workflow posts a comment")


def test_the_repository_conforms(validator: ModuleType) -> None:
    """Every poster and wrapper in this repository takes and passes the input."""
    assert_that(validator.main(PROJECT_ROOT)).is_equal_to(0)


def test_runs_as_a_script(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Run as ``__main__``, the validator exits with ``main``'s status."""
    root = make_repo(tmp_path, {"reusable-publish-a.yml": action_publisher(forward="")})
    monkeypatch.setattr(sys, "argv", ["validate.py", str(root)])

    with pytest.raises(SystemExit) as exc_info:
        runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(capsys.readouterr().out).contains("does not pass comment-fields")
