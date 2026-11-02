"""The privileged gate refresh must stay narrow and execute trusted code only."""

from pathlib import Path

import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def test_rerun_names_cover_pr_workflows_without_self_loop() -> None:
    """Explicit names must follow additions and renames of PR workflows."""
    handler = yaml.safe_load((WORKFLOWS / "all-checks-gate-rerun.yml").read_text())
    trigger = handler["on"]["workflow_run"]
    expected = set()
    for path in WORKFLOWS.glob("*.yml"):
        workflow = yaml.safe_load(path.read_text())
        triggers = workflow.get("on", workflow.get(True, {}))
        pr_triggered = "pull_request" in triggers or "pull_request_target" in triggers
        if pr_triggered and workflow["name"] != "All Checks Gate":
            expected.add(workflow["name"])
    assert set(trigger["workflows"]) == expected
    assert trigger["types"] == ["completed"]
    assert handler["permissions"] == {}
    assert handler["concurrency"]["cancel-in-progress"] is False
    assert "github.event.workflow_run.head_sha" in handler["concurrency"]["group"]


def test_rerun_executes_only_default_branch_code_with_minimal_permissions() -> None:
    """Never give a PR checkout the handler's write token."""
    handler = yaml.safe_load((WORKFLOWS / "all-checks-gate-rerun.yml").read_text())
    job = handler["jobs"]["refresh"]
    assert job["permissions"] == {"actions": "write", "contents": "read"}
    assert "run_attempt > 1" in job["if"]
    assert "conclusion == 'success'" in job["if"]
    prefix = "actions/checkout@"
    steps = job["steps"]
    checkouts = [s for s in steps if s.get("uses", "").startswith(prefix)]
    checkout = checkouts[0]
    assert checkout["with"]["ref"] == "${{ github.sha }}"
    assert checkout["with"]["persist-credentials"] is False
    harden = job["steps"][0]
    assert harden["uses"].startswith("step-security/harden-runner@")
    assert harden["with"]["egress-policy"] == "block"
