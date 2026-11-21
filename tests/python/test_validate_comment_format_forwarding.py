# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/workflows/validate_comment_format_forwarding.py`` (#1678).

``reusable-publish-test-summary.yml`` must declare ``comment-format`` and set
``COMMENT_FORMAT`` on the steps that check and render it; a workflow that
calls a workflow declaring the input must declare it and forward it. Each
miss is one line naming the file (and the job or step line); the run exits 1.
"""

from __future__ import annotations

import contextlib
import io
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/workflows/validate_comment_format_forwarding.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
DECLARES_LINES = (
    "on:",
    "  workflow_call:",
    "    inputs:",
    "      comment-format:",
    "        type: string",
)
DECLARES = "".join(line + "\n" for line in DECLARES_LINES)
MISS = "step does not set COMMENT_FORMAT"
CALL_MISS = "call to reusable-publish-test-summary.yml does not forward comment-format"
ACTIONS = "        run: bash .lgtm-ci-tooling/scripts/ci/actions/"
PUBLISHER = "reusable-publish-test-summary.yml"
NO_FORWARD = f"no reusable workflow forwards comment-format to {PUBLISHER}"
ENV = "          COMMENT_FORMAT: ${{ inputs.comment-format }}\n"


@pytest.fixture(name="validator", scope="module")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator once per module."""
    return load_script(SCRIPT)


def renderer(
    declares: str = DECLARES,
    check_env: str = ENV,
    render_env: str = ENV,
) -> str:
    """The test summary publisher: a check step and a render step."""
    return (
        declares
        + "jobs:\n  publish:\n    steps:\n"
        + "      - name: Check\n        env:\n"
        + check_env
        + f"{ACTIONS}check-comment-format.sh\n"
        + "      - name: Render\n        env:\n"
        + render_env
        + "          X: y\n"
        + f"{ACTIONS}render-test-summary.sh\n"
    )


def caller(declares: str = DECLARES, forward: bool = True) -> str:
    """A workflow calling the publisher as a job."""
    text = declares + "jobs:\n  publish:\n"
    text += "    uses: ./.github/workflows/reusable-publish-test-summary.yml\n"
    text += "    with:\n      comment-marker: m\n"
    if forward:
        text += "      comment-format: ${{ inputs.comment-format }}  # forwarded\n"
    return text


def check(validator: ModuleType, root: Path, files: dict[str, str]) -> tuple[int, str]:
    """Write ``files`` as the workflows of a new repository and validate it."""
    github = root / ".github"
    (github / "actions").mkdir(parents=True)
    (github / "workflows").mkdir()
    for name, text in files.items():
        (github / "workflows" / name).write_text(text, encoding="utf-8")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = validator.main(root)
    return code, out.getvalue()


def test_conforming_repository_passes(validator: ModuleType, tmp_path: Path) -> None:
    """A renderer that sets the variable and a caller that forwards it pass."""
    files = {PUBLISHER: renderer(), "reusable-test.yml": caller()}

    assert_that(check(validator, tmp_path, files)).is_equal_to((0, ""))


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        pytest.param(
            {"reusable-test.yml": caller()},
            [f"{PUBLISHER}: not found", NO_FORWARD],
            id="renderer-missing",
        ),
        pytest.param(
            {PUBLISHER: renderer(declares="on: workflow_call\n")},
            ["reusable-publish-test-summary.yml: does not declare comment-format"],
            id="renderer-without-input",
        ),
        pytest.param(
            {
                "reusable-publish-test-summary.yml": renderer(render_env=""),
                "reusable-test.yml": caller(),
            },
            [f"{PUBLISHER}:13: render-test-summary.sh {MISS}"],
            id="render-step-without-env",
        ),
        pytest.param(
            {
                "reusable-publish-test-summary.yml": renderer(check_env=""),
                "reusable-test.yml": caller(),
            },
            [f"{PUBLISHER}:9: check-comment-format.sh {MISS}"],
            id="check-step-without-env",
        ),
        pytest.param(
            {
                "reusable-publish-test-summary.yml": renderer(),
                "reusable-test.yml": caller(forward=False),
            },
            [
                f"reusable-test.yml:7: {CALL_MISS}",
            ],
            id="call-without-forward",
        ),
        pytest.param(
            {
                "reusable-publish-test-summary.yml": renderer(),
                "reusable-test.yml": caller(declares="on: workflow_call\n"),
            },
            ["reusable-test.yml: does not declare comment-format"],
            id="caller-without-input",
        ),
    ],
)
def test_violations_are_reported(
    validator: ModuleType,
    tmp_path: Path,
    files: dict[str, str],
    expected: list[str],
) -> None:
    """Each miss is reported by file and line, and the run fails."""
    code, out = check(validator, tmp_path, files)

    assert_that(code).is_equal_to(1)
    assert_that(out.splitlines()).contains(*expected)


def test_repository_conforms() -> None:
    """This repository's workflows declare and forward comment-format."""
    done = subprocess.run(
        [sys.executable, str(PROJECT_ROOT / SCRIPT), str(PROJECT_ROOT)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert_that(done.stdout).is_empty()
    assert_that(done.returncode).is_equal_to(0)
