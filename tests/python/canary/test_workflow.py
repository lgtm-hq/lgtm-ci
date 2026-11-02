# SPDX-License-Identifier: MIT
"""Behavioral contracts for canary supersession and cancellation cleanup."""

import re
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = PROJECT_ROOT / ".github/workflows/external-consumer-canary.yml"


def _group(evaluator: ModuleType, context: dict[str, Any]) -> str:
    """Render the actual workflow concurrency key for an event context.

    Args:
        evaluator: Repository GitHub expression evaluator.
        context: Flat GitHub event bindings.

    Returns:
        Rendered concurrency group.
    """
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return re.sub(
        pattern=r"\$\{\{(.*?)\}\}",
        repl=lambda match: str(
            evaluator.Parser(
                tokens=evaluator.tokenize(match[1].strip()),
                context=context,
            ).parse(),
        ),
        string=workflow["concurrency"]["group"],
    )


@pytest.mark.parametrize(
    ("changes", "supersedes"),
    [
        ({"github.event.pull_request.head.sha": "new-head"}, True),
        ({"github.event.pull_request.number": 43}, False),
        (
            {
                "github.event.action": "labeled",
                "github.event.label.name": "unrelated-label",
            },
            False,
        ),
        (
            {
                "github.event.action": "labeled",
                "github.event.label.name": "needs-external-canary",
            },
            True,
        ),
        (
            {
                "github.event.action": "labeled",
                "github.event.label.name": "canary-informational",
            },
            True,
        ),
    ],
    ids=["new-head", "different-pr", "unrelated-label", "force", "override"],
)
def test_canary_supersession(
    load_script: Callable[[str], ModuleType],
    changes: dict[str, Any],
    supersedes: bool,
) -> None:
    """Cancel older PR heads while preserving unrelated-label fast skips."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    original = {
        "github.event.pull_request.number": 42,
        "github.event.pull_request.head.sha": "old-head",
        "github.event.action": "synchronize",
        "github.run_id": "100",
    }
    current = original | changes | {"github.run_id": "101"}
    assert_that(
        _group(evaluator=evaluator, context=original)
        == _group(evaluator=evaluator, context=current),
    ).is_equal_to(supersedes)


@pytest.mark.parametrize("status", ["success", "failure", "cancelled"])
@pytest.mark.parametrize("token", ["fixture-token", ""])
def test_cleanup_runs_after_cancellation(
    load_script: Callable[[str], ModuleType],
    status: str,
    token: str,
) -> None:
    """Run cleanup even after cancellation when the fixture token is present."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    cleanup = next(
        step
        for step in workflow["jobs"]["canary"]["steps"]
        if step.get("run", "").endswith(" --cleanup")
    )
    evaluator = load_script("tests/helpers/gha_expr.py")
    assert_that(
        evaluator.evaluate(
            expression=cleanup["if"],
            context={
                "job.status": status,
                "steps.fixture-token.outputs.token": token,
            },
        ),
    ).is_equal_to(bool(token))
