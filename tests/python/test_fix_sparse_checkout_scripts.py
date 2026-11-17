# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/actions/fix-sparse-checkout-scripts.py``.

The fixer adds ``scripts/ci/`` to the tooling sparse checkout of every
reusable-workflow job that runs ``.lgtm-ci-tooling/scripts``, after the
``.github/actions/`` line, and leaves the release workflows' bootstrap
checkout alone.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/actions/fix-sparse-checkout-scripts.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUNS_SCRIPTS = "        run: bash .lgtm-ci-tooling/scripts/ci/actions/x.sh\n"


@pytest.fixture(name="fixer", scope="module")
def fixture_fixer(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the fixer once per module."""
    return load_script(SCRIPT)


def checkout_step(name: str, paths: list[str]) -> str:
    """Render a tooling checkout step with a sparse-checkout block.

    Args:
        name: The step name.
        paths: Sparse-checkout paths, one per line.

    Returns:
        The step YAML, indented as a job step.
    """
    lines = [
        f"      - name: {name}\n",
        "        uses: actions/checkout@0000000000000000000000000000000000000000\n",
        "        with:\n",
        "          path: .lgtm-ci-tooling\n",
        "          sparse-checkout: |\n",
        *(f"            {path}\n" for path in paths),
    ]
    return "".join(lines)


def job(name: str, *steps: str) -> str:
    """Render a job under ``jobs:`` with the given steps."""
    return f"  {name}:\n    runs-on: ubuntu-latest\n    steps:\n" + "".join(steps)


def workflow(*jobs: str) -> str:
    """Render a reusable workflow holding the given jobs."""
    head = "name: Reusable\non:\n  workflow_call:\n    inputs: {}\njobs:\n"
    return head + "".join(jobs)


TOOLING = checkout_step("Checkout lgtm-ci tooling", [".github/actions/", "README.md"])
FIXED = checkout_step(
    "Checkout lgtm-ci tooling",
    [".github/actions/", "scripts/ci/", "README.md"],
)


def test_adds_scripts_after_the_actions_path(fixer: ModuleType) -> None:
    """A job that runs tooling scripts gains ``scripts/ci/`` in place."""
    text = workflow(job("test", TOOLING, RUNS_SCRIPTS))

    assert_that(fixer.fix_workflow(text)).is_equal_to(
        workflow(job("test", FIXED, RUNS_SCRIPTS)),
    )


def test_fixes_only_jobs_that_run_tooling_scripts(fixer: ModuleType) -> None:
    """Jobs without a ``.lgtm-ci-tooling/scripts`` reference are untouched."""
    plain = job("lint", TOOLING, "        run: echo hi\n")
    text = workflow(plain, job("test", TOOLING, RUNS_SCRIPTS))

    assert_that(fixer.fix_workflow(text)).is_equal_to(
        workflow(plain, job("test", FIXED, RUNS_SCRIPTS)),
    )


@pytest.mark.parametrize(
    "paths",
    [
        [".github/actions/", "scripts/ci/"],
        [".github/actions/", "scripts/ci/actions/"],
        ["README.md"],
    ],
)
def test_leaves_blocks_that_need_no_change(
    fixer: ModuleType,
    paths: list[str],
) -> None:
    """Present scripts paths, or no ``.github/actions/`` anchor: no change."""
    text = workflow(
        job("test", checkout_step("Checkout lgtm-ci tooling", paths), RUNS_SCRIPTS),
    )

    assert_that(fixer.fix_workflow(text)).is_equal_to(text)


def test_skips_the_bootstrap_checkout_but_fixes_the_next_one(
    fixer: ModuleType,
) -> None:
    """The release bootstrap sparse checkout stays as written."""
    bootstrap = checkout_step(
        "Checkout lgtm-ci bootstrap tooling",
        [".github/actions/"],
    )
    text = workflow(job("release", bootstrap, TOOLING, RUNS_SCRIPTS))

    assert_that(fixer.fix_workflow(text)).is_equal_to(
        workflow(job("release", bootstrap, FIXED, RUNS_SCRIPTS)),
    )


def test_fixes_every_tooling_job(fixer: ModuleType) -> None:
    """Each matching job is fixed, not only the first."""
    text = workflow(
        job("one", TOOLING, RUNS_SCRIPTS),
        job("two-b", TOOLING, RUNS_SCRIPTS),
    )

    assert_that(fixer.fix_workflow(text)).is_equal_to(
        workflow(job("one", FIXED, RUNS_SCRIPTS), job("two-b", FIXED, RUNS_SCRIPTS)),
    )


@pytest.mark.parametrize(
    "text",
    [
        "",
        "  permissions:\n    contents: read\n",
        "  test:\n    steps: []\n  concurrency:\n    group: x\n",
        "jobs: {}\n# ünïcode comment\n",
    ],
)
def test_round_trips_text_it_does_not_fix(fixer: ModuleType, text: str) -> None:
    """Text without a fixable job comes back byte for byte."""
    assert_that(fixer.fix_workflow(text)).is_equal_to(text)


def test_fix_job_keeps_lines_after_the_block(fixer: ModuleType) -> None:
    """The sparse block ends at the first line indented less than its paths."""
    body = job("test", TOOLING, "          fetch-depth: 1\n", RUNS_SCRIPTS)

    fixed = fixer.fix_job(body)

    assert_that(fixed).is_equal_to(
        job("test", FIXED, "          fetch-depth: 1\n", RUNS_SCRIPTS),
    )


def test_fix_job_inserts_once(fixer: ModuleType) -> None:
    """Running the fixer on its own output changes nothing."""
    body = job("test", TOOLING, RUNS_SCRIPTS)

    once = fixer.fix_job(body)

    assert_that(fixer.fix_job(once)).is_equal_to(once)


@pytest.fixture(name="workflows")
def fixture_workflows(
    fixer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> Path:
    """Point the fixer at an empty workflows directory and return it."""
    monkeypatch.setattr(fixer, "WORKFLOWS", tmp_path)
    return tmp_path


def test_main_rewrites_only_reusable_workflows_that_need_it(
    fixer: ModuleType,
    workflows: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``main`` writes the files it changes and names them."""
    broken = workflow(job("test", TOOLING, RUNS_SCRIPTS))
    fine = workflow(job("test", FIXED, RUNS_SCRIPTS))
    no_tooling = workflow(job("test", TOOLING))
    files = {
        "reusable-a.yml": broken,
        "reusable-b.yml": fine,
        "reusable-c.yml": no_tooling,
        "ci.yml": broken,
    }
    for name, text in files.items():
        (workflows / name).write_text(text, encoding="utf-8")

    status = fixer.main()

    assert_that(status).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_equal_to(
        "reusable-a.yml\nupdated 1 workflow files\n",
    )
    assert_that((workflows / "reusable-a.yml").read_text(encoding="utf-8")).is_equal_to(
        fine,
    )
    for name in ("reusable-b.yml", "reusable-c.yml", "ci.yml"):
        assert_that((workflows / name).read_text(encoding="utf-8")).is_equal_to(
            files[name],
        )


def test_main_reports_zero_on_an_empty_directory(
    fixer: ModuleType,
    workflows: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """No reusable workflows: nothing written, a zero count printed."""
    assert_that(list(workflows.iterdir())).is_empty()

    assert_that(fixer.main()).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_equal_to("updated 0 workflow files\n")


def test_the_repository_workflows_are_already_fixed(fixer: ModuleType) -> None:
    """Every committed reusable workflow is a fixed point of the fixer."""
    paths = sorted((PROJECT_ROOT / ".github" / "workflows").glob("reusable-*.yml"))
    assert_that(paths).is_not_empty()
    for path in paths:
        text = path.read_text(encoding="utf-8")
        assert_that(fixer.fix_workflow(text)).described_as(path.name).is_equal_to(text)
