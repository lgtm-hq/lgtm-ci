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
