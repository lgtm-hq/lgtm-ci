"""Keep the additive gate scheduled alongside every PR-triggered check."""

from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def test_gate_covers_other_workflows_pull_request_events() -> None:
    """A later label/title event must invalidate the previous gate result."""
    gate = yaml.safe_load((WORKFLOWS / "all-checks-gate.yml").read_text())
    gate_events = set(gate["on"]["pull_request"]["types"])
    for path in WORKFLOWS.glob("*.yml"):
        workflow = yaml.safe_load(path.read_text())
        triggers = workflow.get("on", workflow.get(True, {}))
        if not isinstance(triggers, dict) or "pull_request" not in triggers:
            continue
        config = triggers["pull_request"] or {}
        events = set(config.get("types", ["opened", "synchronize", "reopened"]))
        assert events <= gate_events, f"{path.name}: missing {events - gate_events}"


def test_gate_is_dedicated_read_only_and_fail_closed() -> None:
    """Dogfood the current local reusable without hiding checks or empty heads."""
    gate = yaml.safe_load((WORKFLOWS / "all-checks-gate.yml").read_text())
    assert set(gate["jobs"]) == {"gate"}
    job = gate["jobs"]["gate"]
    assert job["uses"] == "./.github/workflows/reusable-all-checks-gate.yml"
    assert gate["permissions"] == {}
    assert job["permissions"] == dict.fromkeys(
        ("actions", "checks", "contents", "statuses"), "read"
    )
    assert job["with"] == {
        "allow-empty": False,
        "fail-on-draft": True,
        "egress-policy": "block",
        "egress-preset": "github-results",
        "timeout-minutes": 90,
    }
    callers = []
    for path in WORKFLOWS.glob("*.yml"):
        workflow = yaml.safe_load(path.read_text())
        for candidate in workflow.get("jobs", {}).values():
            if "reusable-all-checks-gate.yml" in candidate.get("uses", ""):
                callers.append(path.name)
    assert callers == ["all-checks-gate.yml"]


def test_gate_covers_merge_queue_and_isolates_concurrency() -> None:
    """PR and merge-queue only; label/title refreshes must not cancel each other."""
    gate = yaml.safe_load((WORKFLOWS / "all-checks-gate.yml").read_text())
    # A push run on main gates nothing and only turns main red (#1289).
    assert "push" not in gate["on"]
    assert "merge_group" in gate["on"]
    assert set(gate["on"]["pull_request"]["types"]) >= {"edited", "labeled"}
    assert gate["concurrency"]["cancel-in-progress"] is False
    group = gate["concurrency"]["group"]
    assert "github.workflow" in group
    assert "github.event_name" in group
    assert "github.event.pull_request.head.sha || github.sha" in group


PR_CANCELLING_CALLERS = (
    "validate-action-pinning.yml",
    "validate-lintro-version.yml",
    "npm-set-self-test.yml",
    "ai-review.yml",
    "dependency-review.yml",
)

NON_PR_EVENTS = (
    ("push", "refs/heads/main"),
    ("merge_group", "refs/heads/gh-readonly-queue/main/pr-1289-head"),
    ("workflow_dispatch", "refs/heads/main"),
)


def _identity(
    evaluator: ModuleType,
    name: str,
    context: dict[str, Any],
) -> tuple[str, Any]:
    """Return a caller's (group, cancel-in-progress) for one execution.

    Args:
        evaluator: Repository GitHub expression evaluator.
        name: Workflow file name under .github/workflows.
        context: Flat GitHub context bindings.

    Returns:
        Case-folded group (GitHub compares groups case-insensitively) and the
        evaluated cancel-in-progress value.
    """
    policy = yaml.safe_load((WORKFLOWS / name).read_text())["concurrency"]
    group = evaluator.render(policy["group"], context)
    assert "${{" not in group and group.strip(), (name, group)
    return group.casefold(), evaluator.render(policy["cancel-in-progress"], context)


def _context(name: str, **overrides: Any) -> dict[str, Any]:
    """Build a pull_request execution context, with overrides applied.

    Args:
        name: Workflow file name, used for github.workflow_ref.
        **overrides: Dotted context paths to replace.

    Returns:
        Flat GitHub context bindings.
    """
    ref = overrides.get("github.ref", "refs/pull/1289/merge")
    return {
        "github.workflow_ref": f"lgtm-hq/lgtm-ci/.github/workflows/{name}@{ref}",
        "github.event_name": "pull_request",
        "github.event.pull_request.number": 1289,
        "github.ref": ref,
        "github.sha": "old-head",
        "github.run_id": "1001",
        "github.run_attempt": 1,
    } | overrides


def test_callers_replace_superseded_pull_request_runs(
    load_script: Callable[[str], ModuleType],
) -> None:
    """A new PR head shares the PR's group and cancels the superseded run."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    for name in PR_CANCELLING_CALLERS:
        first = _identity(evaluator, name, _context(name))
        assert first[1] is True, name
        newer = _context(
            name,
            **{"github.sha": "new-head", "github.run_id": "1002"},
        )
        assert _identity(evaluator, name, newer) == first, name
        other_pr = _context(name, **{"github.event.pull_request.number": 1290})
        assert _identity(evaluator, name, other_pr)[0] != first[0], name


def test_callers_never_cancel_or_replace_non_pull_request_runs(
    load_script: Callable[[str], ModuleType],
) -> None:
    """Every non-PR run/attempt owns a group, so none is cancelled or replaced.

    cancel-in-progress: false alone is not enough: GitHub keeps one pending
    run per group and a newer queued run replaces it (#1289).
    """
    evaluator = load_script("tests/helpers/gha_expr.py")
    for name in PR_CANCELLING_CALLERS:
        pr_group = _identity(evaluator, name, _context(name))[0]
        for event, ref in NON_PR_EVENTS:
            groups = set()
            for run_id in ("1001", "1002", "1003"):
                for attempt in (1, 2):
                    execution = _context(
                        name,
                        **{
                            "github.event_name": event,
                            "github.ref": ref,
                            "github.event.pull_request.number": None,
                            "github.run_id": run_id,
                            "github.run_attempt": attempt,
                        },
                    )
                    group, cancel = _identity(evaluator, name, execution)
                    assert cancel is False, (name, event)
                    assert group not in groups, (name, event, group)
                    assert group != pr_group, (name, event)
                    groups.add(group)


def test_ai_review_caller_group_differs_from_reusable_group(
    load_script: Callable[[str], ModuleType],
) -> None:
    """Sharing the reusable's cancelling group would cancel the caller itself."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    reusable = yaml.safe_load((WORKFLOWS / "reusable-ai-review.yml").read_text())
    context = _context("ai-review.yml") | {"github.repository": "lgtm-hq/lgtm-ci"}
    callee = evaluator.render(reusable["concurrency"]["group"], context)
    caller = _identity(evaluator, "ai-review.yml", context)[0]
    assert caller != callee.strip().casefold()
