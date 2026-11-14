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

The end check runs after any publish in the job, so each irreversible publish,
push, release or attestation step listed in :data:`PRE_PUBLISH` is also
immediately preceded by a "Recheck harden-runner agent before <step>" copy of
the same generated body (#1551). Its ``if:`` is the publish step's own
condition plus the verify step's success, so it runs exactly when the publish
would, and a failure skips the publish. A publish step whose ``if:`` has a
status function must also name the recheck's outcome. ``PRE_PUBLISH``,
``ALLOWED_UNGUARDED`` and the detector that keeps them complete live in
``tests/helpers/harden_runner_publishers.py``; its tests are in
``test_harden_runner_publishers.py``.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from assertpy import assert_that
from expr_scan import unquoted
from harden_runner_publishers import (
    ACTIONS,
    EXAMPLES,
    NAME,
    PRE_PUBLISH,
    PRE_PUBLISH_PREFIX,
    RECHECK_NAME,
    VERIFY_ID,
    WORKFLOWS,
    Step,
    load,
    workflow_paths,
)

ROOT = Path(__file__).resolve().parents[2]
HARDEN = "step-security/harden-runner@"
BLOCK = "verify-harden-runner-agent"
RUN = f"# lgtm-ci-inline:begin {BLOCK}\n"
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


# Jobs whose harden step is not followed by the check, with the reason. The
# Scorecard API rejects published results from a job with any step that lacks
# `uses:`, so the scorecards job cannot run the inline check. Its egress-policy
# input is still verified by the egress-preset job it needs, which fails first.
EXEMPT: dict[tuple[str, str], str] = {
    ("reusable-scorecards.yml", "scorecards"): "Scorecard publish: uses-only",
}
# Status functions in a publish step's if:. With one, a failed recheck does not
# skip the publish (and with cancelled() the recheck never runs), so the
# publish must name the recheck's outcome itself (_pre_publish_problems).
STATUS_FUNCTION = re.compile(r"\b(?:always|cancelled|failure|success)\(\)")


def _jobs() -> Iterator[tuple[str, str, list[Step]]]:
    """Yield ``(workflow, job id, steps)`` for every workflow or example job."""
    for path in workflow_paths():
        for job_id, job in (load(path).get("jobs") or {}).items():
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


def _normalize(expression: str) -> str:
    """Collapse whitespace and drop one ``${{ }}`` wrapper."""
    text = " ".join(expression.split())
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    return text


def _conjuncts(condition: str) -> list[str]:
    """Return the top-level ``&&`` operands of a normalized condition.

    Args:
        condition: A normalized expression.

    Returns:
        Each operand that must hold for the condition to hold. A top-level
        ``||`` makes no operand required, so the whole condition is returned.
    """
    parts: list[str] = []
    start, either = 0, False
    for index, depth in unquoted(condition):
        if depth == 0 and condition.startswith("||", index):
            either = True
        elif depth == 0 and condition.startswith("&&", index):
            parts.append(condition[start:index])
            start = index + 2
    parts.append(condition[start:])
    if either:
        return [condition] if condition else []
    return [part.strip() for part in parts if part.strip()]


def _recheck_clause(recheck_id: str) -> str:
    return f"steps.{recheck_id}.outcome == 'success'"


def pre_publish_if(publish: Step, recheck_id: str | None = None) -> str:
    """Return the normalized ``if:`` the pre-publish recheck must carry.

    Args:
        publish: The publish step the recheck precedes.
        recheck_id: The recheck's ``id``, if it has one. The publish step's
            ``steps.<id>.outcome == 'success'`` operand is left out: the
            recheck cannot wait on its own outcome.

    Returns:
        The verify step's success plus the publish step's own condition. A
        condition without a status function implies ``success()``, so the
        recheck says so; one with a status function gets ``!cancelled()``.
    """
    verified = f"steps.{VERIFY_ID}.outcome == 'success'"
    condition = _normalize(str(publish["if"])) if "if" in publish else ""
    if recheck_id is not None:
        clause = _recheck_clause(recheck_id)
        condition = " && ".join(c for c in _conjuncts(condition) if c != clause)
    if not condition:
        return f"success() && {verified}"
    status = "!cancelled()" if STATUS_FUNCTION.search(condition) else "success()"
    return f"{status} && {verified} && ({condition})"


def expected_pre_publish_step(publish: Step, recheck_id: str | None = None) -> Step:
    """Return the recheck that must precede one publish step, minus ``run:``.

    Args:
        publish: The publish step.
        recheck_id: The recheck's ``id``, if it has one.

    Returns:
        The required keys, ``if:`` normalized. No continue-on-error: a stopped
        agent must fail the step and so skip the publish.
    """
    step: Step = {
        **RECHECK_STEP,
        "name": f"{PRE_PUBLISH_PREFIX}{publish['name']}",
        "if": pre_publish_if(publish, recheck_id),
    }
    if recheck_id is not None:
        step["id"] = recheck_id
    return step


def pre_publish_problems(steps: list[Step], name: str) -> list[str]:
    """Return what is wrong with the recheck guarding one publish step.

    Args:
        steps: The job's steps.
        name: The publish step's name.

    Returns:
        Problems; empty when the step right before is the pinned recheck and a
        failed recheck skips the publish.
    """
    index = next((i for i, s in enumerate(steps) if s.get("name") == name), None)
    # None: the step is missing. 0: it is the job's first step, so nothing
    # precedes it, and a publish step needs the recheck before it: fail both.
    if not index:
        return ["missing, or first step"]
    publish, before = steps[index], steps[index - 1]
    actual = {key: value for key, value in before.items() if key != "run"}
    if "if" in actual:
        actual["if"] = _normalize(str(actual["if"]))
    recheck_id = str(actual["id"]) if "id" in actual else None
    problems: list[str] = []
    condition = _normalize(str(publish.get("if", "")))
    # A status function lets the publish run after a failed recheck, and with
    # cancelled() the recheck (!cancelled()) never runs at all: the publish
    # must then require the recheck's success itself, as a top-level operand.
    if STATUS_FUNCTION.search(condition) and (
        recheck_id is None or _recheck_clause(recheck_id) not in _conjuncts(condition)
    ):
        problems.append(
            "if: has a status function but does not require "
            "steps.<recheck id>.outcome == 'success' (give the recheck an id)",
        )
    if actual != expected_pre_publish_step(publish, recheck_id):
        problems.append(f"preceded by {actual!r}")
    elif not str(before.get("run", "")).startswith(RECHECK_RUN):
        problems.append("run is not the generated recheck body")
    return problems


def _job_steps() -> dict[tuple[str, str], list[Step]]:
    return {(workflow, job_id): steps for workflow, job_id, steps in _jobs()}


def test_pre_publish_list_names_one_step_per_entry() -> None:
    """Each listed step exists exactly once in a verified job; no duplicates."""
    assert_that(len(set(PRE_PUBLISH))).is_equal_to(len(PRE_PUBLISH))
    jobs = _job_steps()
    verified = {(workflow, job_id) for workflow, job_id, _s in _verified_jobs()}
    problems = [
        f"{workflow} {job_id} {name!r}"
        for workflow, job_id, name in PRE_PUBLISH
        if (workflow, job_id) not in verified
        or [s.get("name") for s in jobs[(workflow, job_id)]].count(name) != 1
    ]
    assert_that(problems).is_empty()


def test_every_publish_step_is_preceded_by_the_recheck() -> None:
    """The step right before each listed publish is the pinned recheck (#1551)."""
    jobs = _job_steps()
    problems = [
        f"{workflow} {job_id} {name!r}: {problem}"
        for workflow, job_id, name in PRE_PUBLISH
        for problem in pre_publish_problems(jobs.get((workflow, job_id), []), name)
    ]
    assert_that(problems).is_empty()


def test_pre_publish_rechecks_only_precede_listed_steps() -> None:
    """A pre-publish recheck sits right before the listed step it names."""
    listed = set(PRE_PUBLISH)
    stray: list[str] = []
    for workflow, job_id, steps in _jobs():
        for index, step in enumerate(steps):
            name = str(step.get("name", ""))
            if not name.startswith(PRE_PUBLISH_PREFIX):
                continue
            target = name.removeprefix(PRE_PUBLISH_PREFIX)
            following = steps[index + 1].get("name") if index + 1 < len(steps) else None
            if following != target or (workflow, job_id, target) not in listed:
                stray.append(f"{workflow} {job_id} step {index}: {name!r}")
    assert_that(stray).is_empty()


@pytest.mark.parametrize(
    ("condition", "expected"),
    [
        (None, "success() && V"),
        ("inputs.push", "success() && V && (inputs.push)"),
        ("${{ a ||\n  b }}", "success() && V && (a || b)"),
        ("always() && inputs.x", "!cancelled() && V && (always() && inputs.x)"),
    ],
)
def test_pre_publish_if_keeps_the_publish_condition(
    condition: str | None,
    expected: str,
) -> None:
    """The recheck runs exactly when the publish would, after a good start check."""
    publish: Step = {"name": "P"}
    if condition is not None:
        publish["if"] = condition
    verified = f"steps.{VERIFY_ID}.outcome == 'success'"
    assert_that(pre_publish_if(publish)).is_equal_to(expected.replace("V", verified))


def test_pre_publish_if_drops_the_recheck_outcome_operand() -> None:
    """With an id, the recheck mirrors the publish condition minus its own outcome."""
    publish: Step = {
        "name": "P",
        "if": "always() && steps.r.outcome == 'success' && inputs.x",
    }
    verified = f"steps.{VERIFY_ID}.outcome == 'success'"
    assert_that(pre_publish_if(publish, "r")).is_equal_to(
        f"!cancelled() && {verified} && (always() && inputs.x)",
    )
    assert_that(expected_pre_publish_step(publish, "r")).contains_entry({"id": "r"})


def _guarded_job(publish_if: str | None, recheck_id: str | None) -> list[Step]:
    """Return verify, a generated recheck and publish step ``P``."""
    publish: Step = {"name": "P", "run": "git push"}
    if publish_if is not None:
        publish["if"] = publish_if
    recheck = {
        **expected_pre_publish_step(publish, recheck_id),
        "run": RECHECK_RUN,
    }
    return [{"name": NAME, "id": VERIFY_ID}, recheck, publish]


@pytest.mark.parametrize(
    ("publish_if", "recheck_id"),
    [
        pytest.param("always()", None, id="always"),
        pytest.param("failure() && inputs.x", None, id="failure"),
        pytest.param("${{ !cancelled() }}", None, id="not-cancelled"),
        pytest.param("cancelled()", None, id="cancelled"),
        pytest.param("success() || always()", None, id="success-or-always"),
        pytest.param("always()", "r", id="id-but-not-required"),
        pytest.param(
            "always() || steps.r.outcome == 'success'",
            "r",
            id="outcome-under-or",
        ),
        pytest.param(
            "always() && (steps.r.outcome == 'success' || inputs.x)",
            "r",
            id="outcome-in-parentheses",
        ),
    ],
)
def test_status_function_publish_without_the_outcome_is_rejected(
    publish_if: str,
    recheck_id: str | None,
) -> None:
    """A failed recheck would not stop these publishes, so the contract fails."""
    problems = pre_publish_problems(_guarded_job(publish_if, recheck_id), "P")
    assert_that(problems).is_length(1)
    assert_that(problems[0]).contains("status function")


@pytest.mark.parametrize(
    ("publish_if", "recheck_id"),
    [
        pytest.param(None, None, id="no-if"),
        pytest.param("inputs.push", None, id="plain-if"),
        pytest.param(
            "always() && steps.r.outcome == 'success' && inputs.x",
            "r",
            id="status-function-with-outcome",
        ),
        pytest.param(
            "${{ !cancelled() && steps.r.outcome == 'success' }}",
            "r",
            id="not-cancelled-with-outcome",
        ),
    ],
)
def test_safe_publish_pairings_pass(
    publish_if: str | None,
    recheck_id: str | None,
) -> None:
    """The pinned shapes pass, including a status function with the outcome."""
    problems = pre_publish_problems(_guarded_job(publish_if, recheck_id), "P")
    assert_that(problems).is_empty()


def test_a_first_step_publish_fails() -> None:
    """A publish step with nothing before it cannot be guarded."""
    steps: list[Step] = [{"name": "P", "run": "git push"}]
    problems = pre_publish_problems(steps, "P")
    assert_that(problems).is_equal_to(["missing, or first step"])


def test_exempt_jobs_are_uses_only_and_need_a_verified_job() -> None:
    """An exempt job has no run: step and needs a job that runs the check."""
    jobs = {(workflow, job_id): steps for workflow, job_id, steps in _jobs()}
    for workflow, job_id in EXEMPT:
        steps = jobs[(workflow, job_id)]
        assert_that([step for step in steps if "uses" not in step]).is_empty()
        needs = load(WORKFLOWS / workflow)["jobs"][job_id].get("needs") or []
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
        for step in ((load(path).get("runs") or {}).get("steps") or [])
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
        document: dict[Any, Any] = load(path)
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
