# SPDX-License-Identifier: MIT
"""What the tooling App steps and consumers do at run time (#1622).

GitHub cannot be run here, so these tests evaluate the pilot's own conditions
and token expressions with ``tests/helpers/gha_expr.py``, the repository's
evaluator of GitHub's expression semantics (``&&`` and ``||`` return an
operand, empty strings are falsy, unbound paths such as a skipped step's
outputs read as null, and a condition without a status function gets the
implicit ``success() &&``). ``simulate`` walks the four steps that matter: the
check step, the mint, the tooling checkout and the ``checkout-and-harden``
call. What only a real run shows: that the action mints, that git rejects the
sentinel, and how the runner orders ``$GITHUB_ENV`` against job ``env:``.
"""

from __future__ import annotations

import importlib
from collections.abc import Callable
from dataclasses import dataclass, field
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that
from gha_expr import ExpressionError, Value, evaluate, render
from tooling_app_tree import PILOT, ROOT, VALIDATOR

SENTINEL = "no-tooling-app-token"
MINTED = "ghs_minted-for-this-job"
STORED = "stored-tooling-token"
JOB_TOKEN = "job-github-token"
PAIR = {
    "LGTM_CI_TOOLING_APP_CLIENT_ID": "Iv23-client",
    "LGTM_CI_TOOLING_APP_PRIVATE_KEY": "-----BEGIN KEY-----",
}
CLIENT_ONLY = {"LGTM_CI_TOOLING_APP_CLIENT_ID": "Iv23-client"}
KEY_ONLY = {"LGTM_CI_TOOLING_APP_PRIVATE_KEY": "-----BEGIN KEY-----"}
STORED_ONLY = {"LGTM_CI_TOOLING_TOKEN": STORED}
FLAGS_ON = {"LGTM_CI_TOOLING_APP_ID_SET": "true", "LGTM_CI_TOOLING_APP_KEY_SET": "true"}
MINT_ID = "tooling-app-token"
CHECKOUT = "Checkout lgtm-ci tooling"
HARDEN = "Checkout and harden"
JOB_COMMENT = "      # Every tooling consumer below"
STEP_NAMES = (
    "Check tooling App credential",
    "Mint tooling App token",
    "Checkout lgtm-ci tooling",
    "Checkout and harden",
)


@pytest.fixture(name="validator")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which loads the App rules beside it."""
    return load_script(VALIDATOR)


def _pilot() -> dict[str, Any]:
    """Return the pilot job, parsed."""
    workflow = yaml.safe_load((ROOT / ".github" / "workflows" / PILOT).read_text())
    job: dict[str, Any] = workflow["jobs"]["semantic-title"]
    return job


def _steps(job: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Return the four steps that matter, by name."""
    wanted = [step for step in job["steps"] if step.get("name") in STEP_NAMES]
    return {step["name"]: step for step in wanted}


def as_text(value: Value) -> str:
    """Return the string a step input or an ``env:`` value receives."""
    if value is None or isinstance(value, bool):
        return {None: "", True: "true", False: "false"}[value]
    return str(value)


@dataclass
class Run:
    """The outcome of one simulated job run.

    Attributes:
        ran: Names of the steps that ran.
        failed: Whether a step failed.
        tokens: The value each consumer that ran received.
    """

    ran: list[str] = field(default_factory=list)
    failed: bool = False
    tokens: dict[str, str] = field(default_factory=dict)


class Job:
    """The pilot job's context while its steps are walked.

    Args:
        secrets: The secrets the caller passes.
        event: ``github.event_name``.
        env_writes: Variables an earlier step wrote to ``$GITHUB_ENV``.
    """

    def __init__(
        self,
        secrets: dict[str, str],
        event: str,
        env_writes: dict[str, str],
    ) -> None:
        self.context: dict[str, Value] = {
            "github.event_name": event,
            "github.token": JOB_TOKEN,
            "job.workflow_repository": "example-org/example-ci",
            "job.status": "success",
        }
        for name, secret in secrets.items():
            self.context[f"secrets.{name}"] = secret
        for name, value in _pilot()["env"].items():
            self.context[f"env.{name}"] = as_text(render(value, self.context))
        for name, written in env_writes.items():
            self.context[f"env.{name}"] = written
        self.run = Run()

    def runs(self, step: dict[str, Any]) -> bool:
        """Apply the runner's rule for whether a step runs."""
        condition = str(step.get("if", "")).strip()
        result: bool = evaluate(condition or "true", self.context)
        return result

    def outcome(self, works: bool) -> None:
        """Record a step's result; a failure turns the job status to failure."""
        if not works:
            self.run.failed = True
            self.context["job.status"] = "failure"

    def check(self, step: dict[str, Any]) -> None:
        """The check step: fails on half a pair, else writes owner and name."""
        pair = self.context["env.LGTM_CI_TOOLING_APP_ID_SET"]
        pair = pair == self.context["env.LGTM_CI_TOOLING_APP_KEY_SET"]
        self.outcome(pair)
        if pair:
            prefix = f"steps.{step['id']}.outputs"
            self.context[f"{prefix}.owner"] = "example-org"
            self.context[f"{prefix}.repository"] = "example-ci"

    def mint(self, step: dict[str, Any], behaviour: str) -> None:
        """The mint: needs a client ID; ``behaviour`` decides the rest."""
        client = as_text(render(step["with"]["client-id"], self.context))
        works = behaviour != "fail" and client != ""
        self.outcome(works)
        if works:
            token = MINTED if behaviour == "token" else ""
            self.context[f"steps.{step['id']}.outputs.token"] = token

    def consume(self, name: str, step: dict[str, Any]) -> None:
        """A consumer: record the token value it receives."""
        key = "token" if name == CHECKOUT else "tooling-token"
        self.run.tokens[name] = as_text(render(step["with"][key], self.context))


def simulate(
    *,
    secrets: dict[str, str],
    event: str = "pull_request",
    mint: str = "token",
    env_writes: dict[str, str] | None = None,
    consumer_if: str | None = None,
) -> Run:
    """Run the pilot job's App steps and consumers on paper.

    Args:
        secrets: The secrets the caller passes.
        event: ``github.event_name``.
        mint: What the minting action does when it runs: ``token`` (outputs a
            token), ``empty`` (succeeds with an empty output) or ``fail``.
        env_writes: Variables an earlier step wrote to ``$GITHUB_ENV``.
        consumer_if: Replaces the ``if:`` of both consumers, to model a
            status-overriding consumer such as ``always()``.

    Returns:
        Run: What ran, whether the job failed and what each consumer got.
    """
    job = Job(secrets, event, env_writes or {})
    for name, step in _steps(_pilot()).items():
        if consumer_if is not None and name in (CHECKOUT, HARDEN):
            step = {**step, "if": consumer_if}
        if not job.runs(step):
            continue
        job.run.ran.append(name)
        if name == STEP_NAMES[0]:
            job.check(step)
        elif name == STEP_NAMES[1]:
            job.mint(step, mint)
        else:
            job.consume(name, step)
    return job.run


@pytest.mark.parametrize(
    ("secrets", "mint", "checkout", "harden"),
    [
        pytest.param({}, "token", JOB_TOKEN, "", id="neither"),
        pytest.param(STORED_ONLY, "token", STORED, STORED, id="stored-only"),
        pytest.param(PAIR, "token", MINTED, MINTED, id="pair-minted"),
        pytest.param(
            {**PAIR, "LGTM_CI_TOOLING_TOKEN": STORED},
            "token",
            MINTED,
            MINTED,
            id="pair-wins-over-stored",
        ),
        pytest.param(
            {**PAIR, "LGTM_CI_TOOLING_TOKEN": STORED},
            "empty",
            SENTINEL,
            SENTINEL,
            id="pair-empty-output",
        ),
    ],
)
def test_consumers_on_the_normal_path(
    secrets: dict[str, str],
    mint: str,
    checkout: str,
    harden: str,
) -> None:
    """The token each consumer receives when every step runs as it should."""
    run = simulate(secrets=secrets, mint=mint)

    assert_that(run.tokens).is_equal_to({CHECKOUT: checkout, HARDEN: harden})
    assert_that(run.failed).is_false()


@pytest.mark.parametrize(
    ("secrets", "mint", "expected"),
    [
        pytest.param({**PAIR, **STORED_ONLY}, "fail", SENTINEL, id="mint-failed"),
        pytest.param(
            {**CLIENT_ONLY, **STORED_ONLY},
            "token",
            SENTINEL,
            id="client-only",
        ),
        pytest.param(
            {**KEY_ONLY, **STORED_ONLY},
            "token",
            SENTINEL,
            id="key-only",
        ),
        pytest.param({}, "token", JOB_TOKEN, id="neither"),
    ],
)
def test_status_overriding_consumer_never_falls_back(
    secrets: dict[str, str],
    mint: str,
    expected: str,
) -> None:
    """A consumer with ``always()`` gets the sentinel, not the stored token."""
    run = simulate(secrets=secrets, mint=mint, consumer_if="always()")

    assert_that(run.tokens[CHECKOUT]).is_equal_to(expected)


@pytest.mark.parametrize(
    "secrets",
    [PAIR, CLIENT_ONLY],
    ids=["mint-failed", "half-pair"],
)
def test_failed_mint_or_half_pair_stops_ordinary_consumers(
    secrets: dict[str, str],
) -> None:
    """Without a status function the consumers are skipped and the job is red."""
    run = simulate(secrets=secrets, mint="fail")

    assert_that(run.failed).is_true()
    assert_that(run.tokens).is_empty()


def test_neither_secret_runs_no_app_step() -> None:
    """A caller that passes nothing runs neither App step."""
    run = simulate(secrets={})

    assert_that(run.ran).is_equal_to([CHECKOUT, HARDEN])


def test_merge_group_skips_the_mint_and_stays_green() -> None:
    """No consumer runs on merge_group, so nothing is minted and the job passes."""
    run = simulate(secrets=PAIR, event="merge_group")

    assert_that(run.ran).is_empty()
    assert_that(run.failed).is_false()


def test_merge_group_half_pair_stays_green() -> None:
    """Half a pair fails only where the App would have been used."""
    run = simulate(secrets=CLIENT_ONLY, event="merge_group")

    assert_that(run.failed).is_false()


@pytest.mark.parametrize(
    "writes",
    [
        {"LGTM_CI_TOOLING_APP_ID_SET": "false", "LGTM_CI_TOOLING_APP_KEY_SET": "false"},
        {"LGTM_CI_TOOLING_APP_NEEDED": "false"},
    ],
    ids=["flags-false", "needed-false"],
)
def test_forged_variables_only_fail_closed(writes: dict[str, str]) -> None:
    """Rewriting the job variables skips the mint; the consumers get the sentinel."""
    run = simulate(secrets={**PAIR, "LGTM_CI_TOOLING_TOKEN": STORED}, env_writes=writes)

    assert_that(run.ran).is_equal_to([CHECKOUT, HARDEN])
    assert_that(run.tokens).is_equal_to({CHECKOUT: SENTINEL, HARDEN: SENTINEL})


def test_forged_flags_without_secrets_only_break_the_job() -> None:
    """Flags forced on with no secret make the mint fail; no App is used."""
    run = simulate(secrets={}, env_writes=FLAGS_ON, consumer_if="always()")

    assert_that(run.failed).is_true()
    assert_that(run.tokens[CHECKOUT]).is_equal_to(JOB_TOKEN)


# Item 1: the mint's effective environment, as the action reads it.


def _permissions(environment: dict[str, str]) -> dict[str, str]:
    """Port of ``lib/get-permissions-from-inputs.js`` at the pinned commit."""
    found: dict[str, str] = {}
    for key, value in environment.items():
        if key.startswith("INPUT_PERMISSION-") and value:
            found[key[len("INPUT_PERMISSION-") :].lower()] = value
    return found


def _effective(job: dict[str, Any], workflow_env: dict[str, str]) -> dict[str, str]:
    """Return what the mint's process sees from the workflow file."""
    mint = next(step for step in job["steps"] if step.get("id") == "tooling-app-token")
    environment = {**workflow_env, **job.get("env", {})}
    environment.update(
        {f"INPUT_{name.upper()}": str(value) for name, value in mint["with"].items()},
    )
    return environment


def _pilot_text() -> str:
    """Return the pilot's text."""
    text: str = (ROOT / ".github" / "workflows" / PILOT).read_text(encoding="utf-8")
    return text


def test_mint_reads_exactly_its_own_inputs(validator: ModuleType) -> None:
    """The INPUT_ variables of the pilot's mint are its with: and nothing else."""
    reader = importlib.import_module("tooling_token_yaml")
    ambient = validator.app.ambient
    root, _ = reader.parse(_pilot_text())
    job = reader.descend(root, "jobs", "semantic-title")
    steps = reader.descend(job, "steps").items
    mints = [step for step in steps if validator.app.step_id(step) == MINT_ID]
    mint = mints[0]

    names = ambient.mint_environment(root, job, mint)

    inputs = {name for name in names if name.upper().startswith("INPUT")}
    assert_that(inputs).is_equal_to(
        {
            "INPUT_CLIENT-ID",
            "INPUT_PRIVATE-KEY",
            "INPUT_OWNER",
            "INPUT_REPOSITORIES",
            "INPUT_PERMISSION-CONTENTS",
        },
    )


def test_pilot_mint_requests_contents_read_only() -> None:
    """Run through the action's own handler, the pilot asks for one permission."""
    workflow = yaml.safe_load(_pilot_text())
    environment = _effective(workflow["jobs"]["semantic-title"], workflow["env"])

    assert_that(_permissions(environment)).is_equal_to({"contents": "read"})


def test_job_env_widening_is_real_and_refused(
    validator: ModuleType,
    tmp_path: Any,
) -> None:
    """The reproduced widening: the handler takes it, the validator refuses it."""
    text = _pilot_text().replace(
        "    env:\n" + JOB_COMMENT,
        "    env:\n      INPUT_PERMISSION-issues: write\n" + JOB_COMMENT,
        1,
    )
    workflow = yaml.safe_load(text)
    environment = _effective(workflow["jobs"]["semantic-title"], workflow["env"])
    path = tmp_path / PILOT
    path.write_text(text, encoding="utf-8")

    findings = [finding.render() for finding in validator.WorkflowCheck(path).run()]

    widened = {"issues": "write", "contents": "read"}
    assert_that(_permissions(environment)).is_equal_to(widened)
    assert_that("\n".join(findings)).contains(
        "[app] job `semantic-title` env may not set `INPUT_PERMISSION-issues`",
    )


def test_first_slice_expression_fell_back() -> None:
    """The first slice's expression gave a failed mint's consumer the stored token."""
    first_slice = (
        "${{ steps.tooling-app-token.outputs.token "
        "|| secrets.LGTM_CI_TOOLING_TOKEN || github.token }}"
    )
    context: dict[str, Value] = {
        "secrets.LGTM_CI_TOOLING_TOKEN": STORED,
        "github.token": JOB_TOKEN,
    }

    assert_that(render(first_slice, context)).is_equal_to(STORED)


def test_unknown_expression_is_an_error() -> None:
    """The evaluator refuses what it cannot read rather than guessing."""
    with pytest.raises(ExpressionError):
        evaluate("a ~ b", {})
