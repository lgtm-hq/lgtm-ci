"""Keep the additive gate scheduled alongside every PR-triggered check."""

from pathlib import Path

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


REF_KEYED_CALLERS = (
    "validate-action-pinning.yml",
    "validate-lintro-version.yml",
    "npm-set-self-test.yml",
    "ai-review.yml",
    "dependency-review.yml",
)


def test_ref_keyed_callers_only_cancel_pull_request_runs() -> None:
    """Push and merge_group runs keyed on github.ref must run to completion."""
    for name in REF_KEYED_CALLERS:
        workflow = yaml.safe_load((WORKFLOWS / name).read_text())
        concurrency = workflow["concurrency"]
        assert "github.ref" in concurrency["group"], name
        assert (
            concurrency["cancel-in-progress"]
            == "${{ github.event_name == 'pull_request' }}"
        ), name
