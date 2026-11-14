# SPDX-License-Identifier: MIT
"""Every harden-runner step is followed by the generated agent check (#1203).

The pinned ``step-security/harden-runner`` exits 0 when its agent fails to
start, so each harden step must be immediately followed by a "Verify
harden-runner agent" step whose ``run:`` is the marked body of
``scripts/ci/bootstrap/verify-harden-runner-agent.sh``. ``sync_inline_blocks.py``
only keeps that body in sync; this test guards the rest of the step: its
position, ``if:``, ``shell:`` and its ``env``: the harden step's
``EGRESS_POLICY`` and the exact ``REPOSITORY_PRIVATE`` expression the
public-repository check reads on self-hosted runners (#1552). The verify
step carries no platform ``if:``: harden-runner is skipped on hosted macOS and
Windows, but the policy check must still reject audit there. It scans the
workflows and the caller-owned ``examples/``, and pins the owner decision that
audit mode is never requested.

Every job with the verify step also ends with a "Recheck harden-runner agent"
step, generated from ``scripts/ci/bootstrap/recheck-harden-runner-agent.sh``:
a second snapshot that fails the job when the agent stopped enforcing mid-job.
It keys off the verify step's fixed ``id``.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
import yaml
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
EXAMPLES = ROOT / "examples"
ACTIONS = ROOT / ".github" / "actions"
HARDEN = "step-security/harden-runner@"
NAME = "Verify harden-runner agent"
BLOCK = "verify-harden-runner-agent"
RUN = f"# lgtm-ci-inline:begin {BLOCK}\n"
VERIFY_ID = "verify-harden-runner"
RECHECK_NAME = "Recheck harden-runner agent"
RECHECK_RUN = "# lgtm-ci-inline:begin recheck-harden-runner-agent\n"
# Everything but the generated run: body. No continue-on-error: a stopped agent
# must fail the job.
RECHECK_STEP: dict[str, Any] = {
    "name": RECHECK_NAME,
    "if": f"${{{{ !cancelled() && steps.{VERIFY_ID}.outcome == 'success' }}}}",
    "timeout-minutes": 1,
    "working-directory": "${{ runner.temp }}",
    "shell": "bash",
}
# The harden step's platform gate. The verify step drops it so the policy
# check runs on every runner; the script itself skips the agent check where
# harden-runner does not run.
PLATFORM_IF = "runner.os == 'Linux' || runner.environment == 'self-hosted'"
# Repository visibility for the self-hosted public-repository failure (#1552).
# The github context has no visibility property; the event payload does, and a
# reusable workflow sees its caller's payload. Empty (no payload) is not public.
REPOSITORY_PRIVATE = "${{ github.event.repository.private }}"

Step = dict[str, Any]

# Jobs whose harden step is not followed by the check, with the reason. The
# Scorecard API rejects published results from a job with any step that lacks
# `uses:`, so the scorecards job cannot run the inline check. Its egress-policy
# input is still verified by the egress-preset job it needs, which fails first.
EXEMPT: dict[tuple[str, str], str] = {
    ("reusable-scorecards.yml", "scorecards"): "Scorecard publish: uses-only",
}


def _load(path: Path) -> dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def _jobs() -> Iterator[tuple[str, str, list[Step]]]:
    """Yield ``(workflow, job id, steps)`` for every workflow or example job."""
    paths = [*sorted(WORKFLOWS.glob("*.y*ml")), *sorted(EXAMPLES.glob("*.y*ml"))]
    for path in paths:
        for job_id, job in (_load(path).get("jobs") or {}).items():
            yield path.name, str(job_id), job.get("steps") or []


def _is_harden(step: Step) -> bool:
    return str(step.get("uses", "")).startswith(HARDEN)


def _harden_steps() -> list[tuple[str, str, list[Step], int]]:
    return [
        (workflow, job_id, steps, index)
        for workflow, job_id, steps in _jobs()
        for index, step in enumerate(steps)
        if _is_harden(step)
    ]


def expected_verify_step(harden: Step) -> Step:
    """Return the verify step that must follow one harden-runner step.

    Args:
        harden: The harden-runner step.

    Returns:
        The required step, minus the generated ``run:`` body. A non-platform
        ``if:`` (e.g. a merge_group skip) is mirrored; the platform gate is
        not, so audit is rejected on hosted macOS and Windows too.
    """
    step: Step = {
        "name": NAME,
        "id": VERIFY_ID,
        "shell": "bash",
        "env": {
            "EGRESS_POLICY": harden["with"]["egress-policy"],
            "REPOSITORY_PRIVATE": REPOSITORY_PRIVATE,
        },
    }
    if harden.get("if") not in (None, PLATFORM_IF):
        step["if"] = harden["if"]
    return step


def test_harden_steps_exist() -> None:
    """The scan sees the workflows' and examples' harden-runner steps at all."""
    assert_that(len(_harden_steps())).is_greater_than(100)
    examples = [w for w, _j, _s, _i in _harden_steps() if (EXAMPLES / w).is_file()]
    assert_that(examples).contains(
        "publish-npm-set.yml",
        "publish-python-release.yml",
    )


def test_harden_steps_share_one_pinned_ref() -> None:
    """Workflows and examples pin the same harden-runner commit."""
    refs = {str(steps[i]["uses"]) for _w, _j, steps, i in _harden_steps()}
    assert_that(refs).is_length(1)
    assert_that(refs.pop()).matches(r"^step-security/harden-runner@[0-9a-f]{40}$")


def test_verify_steps_have_no_platform_if() -> None:
    """No verify step is gated on the runner, which would skip the policy check."""
    gated = [
        f"{workflow} {job_id} step {index}: {step['if']}"
        for workflow, job_id, steps in _jobs()
        for index, step in enumerate(steps)
        if step.get("name") == NAME and "runner." in str(step.get("if", ""))
    ]
    assert_that(gated).is_empty()


def test_every_harden_step_is_followed_by_the_verify_step() -> None:
    """The next step is the verify step with the expected ``if:`` and policy."""
    problems: list[str] = []
    for workflow, job_id, steps, index in _harden_steps():
        where = f"{workflow} {job_id} step {index}"
        if (workflow, job_id) in EXEMPT:
            continue
        if index + 1 >= len(steps):
            problems.append(f"{where}: no step after harden-runner")
            continue
        verify = steps[index + 1]
        # Any extra key (continue-on-error, a second env var...) fails too.
        actual = {key: value for key, value in verify.items() if key != "run"}
        if actual != expected_verify_step(steps[index]):
            problems.append(f"{where}: {actual!r}")
        if not str(verify.get("run", "")).startswith(RUN):
            problems.append(f"{where}: run is not the generated {BLOCK} body")
    assert_that(problems).is_empty()


def _verified_jobs() -> list[tuple[str, str, list[Step]]]:
    return [
        (workflow, job_id, steps)
        for workflow, job_id, steps in _jobs()
        if any(step.get("name") == NAME for step in steps)
    ]


def test_every_verified_job_ends_with_the_recheck_step() -> None:
    """The last step is the generated recheck, with the pinned keys (#1203).

    Last, so it runs after every trailing ``if: always()`` upload or summary
    step too: the job only passes if the agent was still enforcing at its end.
    Any extra key, ``continue-on-error`` included, fails the comparison.
    """
    jobs = _verified_jobs()
    assert_that(len(jobs)).is_greater_than(100)
    problems: list[str] = []
    for workflow, job_id, steps in jobs:
        where = f"{workflow} {job_id}"
        last = steps[-1]
        actual = {key: value for key, value in last.items() if key != "run"}
        if actual != RECHECK_STEP:
            problems.append(f"{where}: last step is {actual!r}")
        elif not str(last.get("run", "")).startswith(RECHECK_RUN):
            problems.append(f"{where}: run is not the generated recheck body")
        verify = [step for step in steps if step.get("name") == NAME]
        if [step.get("id") for step in verify] != [VERIFY_ID]:
            problems.append(f"{where}: verify step id is not {VERIFY_ID!r}")
    assert_that(problems).is_empty()


def test_recheck_steps_only_end_verified_jobs() -> None:
    """One recheck per job, never in a job without the verify step."""
    verified = {(workflow, job_id) for workflow, job_id, _s in _verified_jobs()}
    stray = [
        f"{workflow} {job_id} step {index}"
        for workflow, job_id, steps in _jobs()
        for index, step in enumerate(steps)
        if step.get("name") == RECHECK_NAME
        and ((workflow, job_id) not in verified or index != len(steps) - 1)
    ]
    assert_that(stray).is_empty()


def test_exempt_jobs_are_uses_only_and_need_a_verified_job() -> None:
    """An exempt job has no run: step and needs a job that runs the check."""
    jobs = {(workflow, job_id): steps for workflow, job_id, steps in _jobs()}
    for workflow, job_id in EXEMPT:
        steps = jobs[(workflow, job_id)]
        assert_that([step for step in steps if "uses" not in step]).is_empty()
        needs = _load(WORKFLOWS / workflow)["jobs"][job_id].get("needs") or []
        needs = [needs] if isinstance(needs, str) else needs
        verified = [
            need
            for need in needs
            if any(step.get("name") == NAME for step in jobs[(workflow, need)])
        ]
        assert_that(verified).is_not_empty()


def test_verify_steps_only_follow_harden_steps() -> None:
    """No stray verify step: each one sits right after a harden-runner step."""
    stray = [
        f"{workflow} {job_id} step {index}"
        for workflow, job_id, steps in _jobs()
        for index, step in enumerate(steps)
        if step.get("name") == NAME and (index == 0 or not _is_harden(steps[index - 1]))
    ]
    assert_that(stray).is_empty()


def test_one_harden_step_per_job() -> None:
    """One per job keeps the inline-run ratchet keys unique."""
    counts: dict[tuple[str, str], int] = {}
    for workflow, job_id, _steps, _index in _harden_steps():
        counts[(workflow, job_id)] = counts.get((workflow, job_id), 0) + 1
    assert_that({key: n for key, n in counts.items() if n > 1}).is_empty()


def test_composite_actions_do_not_run_harden_runner() -> None:
    """A composite harden step would bypass this contract; keep them out."""
    offenders = [
        str(path.relative_to(ROOT))
        for path in sorted(ACTIONS.rglob("action.y*ml"))
        for step in ((_load(path).get("runs") or {}).get("steps") or [])
        if _is_harden(step)
    ]
    assert_that(offenders).is_empty()


def test_harden_steps_never_request_audit() -> None:
    """Every egress-policy is ``block`` or the workflow's input (#1203)."""
    allowed = {"block", "${{ inputs.egress-policy }}"}
    policies = {
        f"{workflow} {job_id}": steps[index]["with"]["egress-policy"]
        for workflow, job_id, steps, index in _harden_steps()
    }
    assert_that({k: v for k, v in policies.items() if v not in allowed}).is_empty()


def _egress_inputs() -> Iterator[tuple[str, dict[str, Any]]]:
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        # PyYAML 1.1 loads a bare `on:` key as the boolean True.
        document: dict[Any, Any] = _load(path)
        triggers = document.get("on") or document.get(True) or {}
        if not isinstance(triggers, dict):
            continue
        for trigger in ("workflow_call", "workflow_dispatch"):
            inputs = (triggers.get(trigger) or {}).get("inputs") or {}
            if "egress-policy" in inputs:
                yield f"{path.name} {trigger}", inputs["egress-policy"]


@pytest.mark.parametrize("field", ["default", "description"])
def test_egress_policy_inputs_default_to_block(field: str) -> None:
    """Inputs default to block and no longer advertise audit as an option."""
    inputs = dict(_egress_inputs())
    assert_that(inputs).is_not_empty()
    if field == "default":
        bad = {name: spec.get("default") for name, spec in inputs.items()}
        assert_that({k: v for k, v in bad.items() if v != "block"}).is_empty()
    else:
        bad = {
            name: spec.get("description", "")
            for name, spec in inputs.items()
            if "audit or block" in spec.get("description", "")
        }
        assert_that(bad).is_empty()


def test_expected_verify_step_drops_only_the_platform_if() -> None:
    """The platform gate is dropped; any other harden ``if:`` is mirrored."""
    harden = {"uses": f"{HARDEN}x", "with": {"egress-policy": "block"}}
    assert_that(expected_verify_step(harden)).does_not_contain_key("if")
    harden["if"] = PLATFORM_IF
    assert_that(expected_verify_step(harden)).does_not_contain_key("if")
    harden["if"] = "github.event_name != 'merge_group'"
    assert_that(expected_verify_step(harden)).contains_entry(
        {"if": "github.event_name != 'merge_group'"},
    )


def test_verify_steps_pass_the_repository_visibility() -> None:
    """Every verify step passes the exact ``REPOSITORY_PRIVATE`` expression (#1552)."""
    steps = [s for _w, _j, job in _jobs() for s in job if s.get("name") == NAME]
    assert_that(len(steps)).is_greater_than(100)
    values = {str((step.get("env") or {}).get("REPOSITORY_PRIVATE")) for step in steps}
    assert_that(values).is_equal_to({REPOSITORY_PRIVATE})
