# SPDX-License-Identifier: MIT
"""Contracts for the optional cleanup App token of the suppression check (#1687).

``reusable-vuln-suppression-check.yml`` opens its cleanup PR with a GitHub App
token when the caller passes ``RELEASE_APP_CLIENT_ID`` or ``RELEASE_APP_ID``
with ``RELEASE_APP_PRIVATE_KEY``, and with ``GH_TOKEN`` otherwise. These tests
run the shipped credential check, render the token expressions with the
``gha_expr`` evaluator, and hold where the token is minted, which permissions
and repository it asks for, and which steps can read it.
"""

from __future__ import annotations

import os
import re
import subprocess  # nosec B404 - runs the shipped step text under bash
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "reusable-vuln-suppression-check.yml"
RELEASE = ROOT / ".github" / "workflows" / "reusable-release-version-pr.yml"
JOB = "vuln-suppression-check"
CHECK = "Check cleanup token credential"
SELECT = "Select GitHub App credential"
MINT = "Create GitHub App installation token"
CHECKOUT = "Checkout repository"
STALENESS = "Check suppression staleness"
TOOLING = "Checkout lgtm-ci tooling"
APP_SECRETS = ("RELEASE_APP_ID", "RELEASE_APP_CLIENT_ID", "RELEASE_APP_PRIVATE_KEY")
SENTINEL = "no-cleanup-app-token"  # nosec B105 - a placeholder, not a credential
MINTED = "ghs_minted"  # nosec B105 - a test value
CALLER = "ghs_caller"  # nosec B105 - a test value
FORMAT = re.compile(r"\A\$\{\{ format\('\{0\}/\{1\}/\{2\}',(.*)\) \}\}\Z", re.S)


@pytest.fixture(name="workflow", scope="module")
def fixture_workflow() -> dict[Any, Any]:
    """Parse the suppression workflow once.

    Returns:
        dict[Any, Any]: The parsed workflow.
    """
    parsed: dict[Any, Any] = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return parsed


@pytest.fixture(name="steps", scope="module")
def fixture_steps(workflow: dict[Any, Any]) -> list[dict[str, Any]]:
    """Return the cleanup job's steps.

    Args:
        workflow: The parsed workflow.

    Returns:
        list[dict[str, Any]]: The steps, in order.
    """
    found: list[dict[str, Any]] = workflow["jobs"][JOB]["steps"]
    return found


@pytest.fixture(name="evaluator", scope="module")
def fixture_evaluator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the ``gha_expr`` evaluator.

    Args:
        load_script: The conftest loader for files by path.

    Returns:
        ModuleType: The evaluator module.
    """
    return load_script("tests/helpers/gha_expr.py")


def step(steps: list[dict[str, Any]], name: str) -> dict[str, Any]:
    """Return the one step with a name.

    Args:
        steps: The job's steps.
        name: The step name.

    Returns:
        dict[str, Any]: The step.
    """
    found = [entry for entry in steps if entry.get("name") == name]
    assert_that(found).described_as(name).is_length(1)
    return found[0]


def position(steps: list[dict[str, Any]], name: str) -> int:
    """Return the index of the one step with a name.

    Args:
        steps: The job's steps.
        name: The step name.

    Returns:
        int: Its index.
    """
    return steps.index(step(steps, name))


def secrets_context(given: dict[str, str]) -> dict[str, Any]:
    """Bind every secret the job reads; an unset secret is empty, as on GitHub.

    Args:
        given: The secrets the caller passes, by name.

    Returns:
        dict[str, Any]: The flat evaluator context.
    """
    names = (*APP_SECRETS, "GH_TOKEN")
    return {f"secrets.{name}": given.get(name, "") for name in names}


def credential(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    given: dict[str, str],
) -> str:
    """Render the check step's CREDENTIAL value as the runner would.

    Args:
        evaluator: The ``gha_expr`` module.
        steps: The job's steps.
        given: The secrets the caller passes.

    Returns:
        str: Three booleans joined by ``/``.
    """
    template = step(steps, CHECK)["env"]["CREDENTIAL"]
    match = FORMAT.match(template.strip())
    if match is None:
        pytest.fail(f"CREDENTIAL is not the expected format(): {template}")
    context = secrets_context(given)
    parts = [
        evaluator.evaluate(argument, context, is_condition=False)
        for argument in match[1].split(",")
    ]
    assert_that(parts).is_length(3)
    return "/".join("true" if part else "false" for part in parts)


def run_check(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    given: dict[str, str],
    tmp_path: Path,
) -> tuple[subprocess.CompletedProcess[str], str]:
    """Run the shipped credential check under bash.

    Args:
        evaluator: The ``gha_expr`` module.
        steps: The job's steps.
        given: The secrets the caller passes.
        tmp_path: Scratch directory for the step output file.

    Returns:
        tuple[subprocess.CompletedProcess[str], str]: The run and the step
        output file's text.
    """
    check = step(steps, CHECK)
    output = tmp_path / "github-output"
    output.write_text("", encoding="utf-8")
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "GITHUB_OUTPUT": str(output),
        "CREDENTIAL": credential(evaluator, steps, given),
        "INCOMPLETE": check["env"]["INCOMPLETE"],
        "MISSING": check["env"]["MISSING"],
    }
    argv = ["bash", "-c", check["run"]]
    result = subprocess.run(  # nosec B603 B607 - fixed argv, shipped step text
        argv, check=False, env=env, text=True, capture_output=True
    )
    return result, output.read_text(encoding="utf-8")


def test_app_secrets_and_gh_token_are_optional(workflow: dict[Any, Any]) -> None:
    """The three App secrets and GH_TOKEN are declared and all optional."""
    declared = workflow[True]["workflow_call"]["secrets"]
    for name in (*APP_SECRETS, "GH_TOKEN"):
        assert_that(declared).described_as(name).contains_key(name)
        assert_that(declared[name]["required"]).described_as(name).is_false()


@pytest.mark.parametrize(
    "given",
    [
        {"RELEASE_APP_CLIENT_ID": "Iv23li", "RELEASE_APP_PRIVATE_KEY": "key"},
        {"RELEASE_APP_ID": "123", "RELEASE_APP_PRIVATE_KEY": "key"},
        {
            "RELEASE_APP_ID": "123",
            "RELEASE_APP_CLIENT_ID": "Iv23li",
            "RELEASE_APP_PRIVATE_KEY": "key",
            "GH_TOKEN": CALLER,
        },
    ],
    ids=["client-id", "app-id", "both-ids-and-gh-token"],
)
def test_complete_app_credential_selects_app_mode(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
    given: dict[str, str],
) -> None:
    """An ID with the key selects the App, with or without GH_TOKEN."""
    result, output = run_check(evaluator, steps, given, tmp_path)

    assert_that(result.returncode).described_as(result.stdout).is_equal_to(0)
    assert_that(output).is_equal_to("mode=app\n")


@pytest.mark.parametrize(
    "given",
    [
        {"RELEASE_APP_CLIENT_ID": "Iv23li"},
        {"RELEASE_APP_ID": "123"},
        {"RELEASE_APP_ID": "123", "RELEASE_APP_CLIENT_ID": "Iv23li"},
        {"RELEASE_APP_PRIVATE_KEY": "key"},
        {"RELEASE_APP_CLIENT_ID": "Iv23li", "GH_TOKEN": CALLER},
        {"RELEASE_APP_PRIVATE_KEY": "key", "GH_TOKEN": CALLER},
    ],
    ids=[
        "client-id-only",
        "app-id-only",
        "both-ids-no-key",
        "key-only",
        "client-id-with-gh-token",
        "key-with-gh-token",
    ],
)
def test_incomplete_app_credential_fails(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
    given: dict[str, str],
) -> None:
    """Half an App credential fails, even when GH_TOKEN could stand in."""
    result, output = run_check(evaluator, steps, given, tmp_path)

    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stdout).starts_with("::error title=incomplete App credential::")
    assert_that(result.stdout).contains(
        "RELEASE_APP_PRIVATE_KEY",
        "RELEASE_APP_CLIENT_ID",
    )
    assert_that(output).is_empty()


def test_gh_token_alone_selects_fallback(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
) -> None:
    """GH_TOKEN without App secrets passes and writes no App mode."""
    result, output = run_check(evaluator, steps, {"GH_TOKEN": CALLER}, tmp_path)

    assert_that(result.returncode).is_equal_to(0)
    assert_that(result.stdout).is_empty()
    assert_that(output).is_empty()


def test_neither_credential_fails_naming_both(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
) -> None:
    """No App credential and no GH_TOKEN fails with an error naming both."""
    result, output = run_check(evaluator, steps, {}, tmp_path)

    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stdout).starts_with("::error title=missing cleanup token::")
    assert_that(result.stdout).contains("RELEASE_APP_PRIVATE_KEY", "GH_TOKEN")
    assert_that(output).is_empty()


def test_mint_runs_in_this_job_before_its_consumers(
    steps: list[dict[str, Any]],
) -> None:
    """Check, select and mint precede the checkout, the tooling and the check."""
    names = (CHECK, SELECT, MINT, CHECKOUT, TOOLING, STALENESS)
    order = [position(steps, name) for name in names]

    assert_that(order).is_equal_to(sorted(order))
    for name in (SELECT, MINT):
        assert_that(step(steps, name)["if"]).is_equal_to(
            "steps.cleanup-credential.outputs.mode == 'app'",
        )
    assert_that(step(steps, CHECK)).does_not_contain_key("if")


def test_mint_asks_for_two_permissions_on_the_calling_repository(
    steps: list[dict[str, Any]],
) -> None:
    """The mint takes the selected ID and asks for exactly two write scopes.

    With no ``owner`` and no ``repositories`` the action scopes the token to
    the current repository only.
    """
    mint = step(steps, MINT)

    assert_that(mint["with"]).is_equal_to(
        {
            "app-id": "${{ steps.app-cred.outputs.app-id }}",
            "client-id": "${{ steps.app-cred.outputs.client-id }}",
            "private-key": "${{ secrets.RELEASE_APP_PRIVATE_KEY }}",
            "permission-contents": "write",
            "permission-pull-requests": "write",
        },
    )
    assert_that(mint).does_not_contain_key("env")


def test_mint_uses_the_release_pin(steps: list[dict[str, Any]]) -> None:
    """The mint reuses the release reusables' pin of the action."""
    pattern = r"actions/create-github-app-token@[0-9a-f]{40}"
    pins = set(re.findall(pattern, RELEASE.read_text(encoding="utf-8")))

    assert_that(pins).is_length(1)
    assert_that(step(steps, MINT)["uses"]).is_equal_to(pins.pop())


def test_select_step_reads_both_ids(steps: list[dict[str, Any]]) -> None:
    """The selection step gets both IDs, never the key."""
    assert_that(step(steps, SELECT)["env"]).is_equal_to(
        {
            "APP_ID": "${{ secrets.RELEASE_APP_ID }}",
            "APP_CLIENT_ID": "${{ secrets.RELEASE_APP_CLIENT_ID }}",
        },
    )


def token_templates(steps: list[dict[str, Any]]) -> dict[str, str]:
    """Return the token value of each consumer, by step name.

    Args:
        steps: The job's steps.

    Returns:
        dict[str, str]: The checkout's ``token`` and the check's ``GH_TOKEN``.
    """
    return {
        CHECKOUT: step(steps, CHECKOUT)["with"]["token"],
        STALENESS: step(steps, STALENESS)["env"]["GH_TOKEN"],
    }


@pytest.mark.parametrize(
    ("given", "minted", "expected"),
    [
        (
            {"RELEASE_APP_CLIENT_ID": "Iv23li", "RELEASE_APP_PRIVATE_KEY": "k"},
            MINTED,
            MINTED,
        ),
        (
            {"RELEASE_APP_ID": "1", "RELEASE_APP_PRIVATE_KEY": "k", "GH_TOKEN": CALLER},
            MINTED,
            MINTED,
        ),
        ({"RELEASE_APP_CLIENT_ID": "Iv23li", "GH_TOKEN": CALLER}, "", SENTINEL),
        ({"RELEASE_APP_PRIVATE_KEY": "k", "GH_TOKEN": CALLER}, "", SENTINEL),
        ({"GH_TOKEN": CALLER}, "", CALLER),
    ],
    ids=[
        "app",
        "app-over-gh-token",
        "id-only-no-fallback",
        "key-only-no-fallback",
        "gh-token",
    ],
)
def test_consumers_get_the_selected_token(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    given: dict[str, str],
    minted: str,
    expected: str,
) -> None:
    """The checkout and the check get the App token, else GH_TOKEN, never both."""
    context = secrets_context(given)
    context["steps.app-token.outputs.token"] = minted
    for name, template in token_templates(steps).items():
        rendered = evaluator.render(template, context)
        assert_that(rendered).described_as(name).is_equal_to(expected)


def test_checkout_does_not_persist_the_token(steps: list[dict[str, Any]]) -> None:
    """The repository checkout keeps no credential for later steps."""
    assert_that(step(steps, CHECKOUT)["with"]["persist-credentials"]).is_false()


def test_only_the_two_consumers_read_the_minted_token(workflow: dict[Any, Any]) -> None:
    """No output, workflow or job env carries the token; two steps read it."""
    job = workflow["jobs"][JOB]
    dumped = {entry["name"]: yaml.safe_dump(entry) for entry in job["steps"]}
    readers = [name for name, text in dumped.items() if "steps.app-token" in text]

    assert_that(readers).is_equal_to([CHECKOUT, STALENESS])
    assert_that(job).does_not_contain_key("outputs")
    assert_that(workflow[True]["workflow_call"]).does_not_contain_key("outputs")
    for scope in (workflow.get("env", {}), job.get("env", {})):
        text = yaml.safe_dump(scope)
        assert_that(text).does_not_contain("app-token", "RELEASE_APP", "GH_TOKEN")


def test_private_key_reaches_only_the_mint(steps: list[dict[str, Any]]) -> None:
    """Outside presence checks, only the mint reads the private key."""
    readers = [
        entry["name"]
        for entry in steps
        if "${{ secrets.RELEASE_APP_PRIVATE_KEY }}" in yaml.safe_dump(entry, width=1000)
    ]

    assert_that(readers).is_equal_to([MINT])


def test_job_permissions_are_unchanged(workflow: dict[Any, Any]) -> None:
    """Minting needs no job permission beyond the two the job already has."""
    assert_that(workflow["jobs"][JOB]["permissions"]).is_equal_to(
        {"contents": "write", "pull-requests": "write"},
    )
