# SPDX-License-Identifier: MIT
"""Contracts for the opt-in cleanup App token of the suppression check (#1687).

``reusable-vuln-suppression-check.yml`` opens its cleanup PR with a GitHub App
token only when the caller sets the ``cleanup-app-token`` input and passes
``RELEASE_APP_CLIENT_ID`` or ``RELEASE_APP_ID`` with ``RELEASE_APP_PRIVATE_KEY``
(#1691); otherwise it uses ``GH_TOKEN`` and ignores the App secrets. These tests
run the shipped credential check, render the token expressions with the
``gha_expr`` evaluator, and hold where the token is minted, which permissions
and repository it asks for, and which steps can read each secret and the token.
"""

from __future__ import annotations

import os
import re
import subprocess  # nosec B404 - runs the shipped step text under bash
from collections.abc import Callable, Iterator
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
INPUT = "cleanup-app-token"
CHECK = "Check cleanup token credential"
SELECT = "Select GitHub App credential"
MINT = "Create GitHub App installation token"
CHECKOUT = "Checkout repository"
STALENESS = "Check suppression staleness"
TOOLING = "Checkout lgtm-ci tooling"
APP_SECRETS = ("RELEASE_APP_ID", "RELEASE_APP_CLIENT_ID", "RELEASE_APP_PRIVATE_KEY")
WATCHED = (*APP_SECRETS, "GH_TOKEN")
SENTINEL = "no-cleanup-app-token"  # nosec B105 - a placeholder, not a credential
MINTED = "ghs_minted"  # nosec B105 - a test value
CALLER = "ghs_caller"  # nosec B105 - a test value
COMPLETE = {"RELEASE_APP_CLIENT_ID": "Iv23li", "RELEASE_APP_PRIVATE_KEY": "key"}
# The check step's whole env: four booleans, nothing else (#1691).
CHECK_ENV = {
    "APP_MODE": "${{ inputs.cleanup-app-token }}",
    "APP_ID_SET": "${{ "
    + "secrets.RELEASE_APP_CLIENT_ID != '' || secrets.RELEASE_APP_ID != ''"
    + " }}",
    "APP_KEY_SET": "${{ secrets.RELEASE_APP_PRIVATE_KEY != '' }}",
    "GH_TOKEN_SET": "${{ secrets.GH_TOKEN != '' }}",
}
# Where each watched secret may be read as a value: (step name, field path).
VALUE_READERS = {
    "RELEASE_APP_PRIVATE_KEY": {(MINT, "with.private-key")},
    "RELEASE_APP_ID": {(SELECT, "env.APP_ID")},
    "RELEASE_APP_CLIENT_ID": {(SELECT, "env.APP_CLIENT_ID")},
    "GH_TOKEN": {(CHECKOUT, "with.token"), (STALENESS, "env.GH_TOKEN")},
}
TOKEN_READERS = {(CHECKOUT, "with.token"), (STALENESS, "env.GH_TOKEN")}
# Any spelling GitHub accepts: contexts are case-insensitive, `.name` and
# `['name']` / `["name"]` both index, and spaces may sit around the operators.
SECRET_REF = re.compile(
    r"secrets\s*(?:\.\s*([A-Za-z_][\w-]*)|\[\s*['\"]([^'\"]*)['\"]\s*\])",
    re.I,
)
PRESENCE = re.compile(r"\A\s*!=\s*''")
# A context named without `.name` or `['name']` after it, e.g. toJSON(secrets).
WHOLE = r"(?!\s*(?:\.\s*[A-Za-z_]|\[\s*['\"]))"
BARE_SECRETS = re.compile(r"(?<![\w.-])secrets" + WHOLE, re.I)
TOKEN_REF = re.compile(
    r"steps\s*(?:\.\s*app-token(?![\w-])|\[\s*['\"]app-token['\"]\s*\])",
    re.I,
)
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
BARE_STEPS = re.compile(r"(?<![\w.-])steps" + WHOLE, re.I)


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


def strings(node: Any, path: str = "") -> Iterator[tuple[str, str]]:
    """Yield every string in a parsed YAML node with its dotted path.

    Args:
        node: A parsed YAML value.
        path: The dotted path of ``node``.

    Yields:
        tuple[str, str]: The path and the string, keys included.
    """
    if isinstance(node, dict):
        for key, value in node.items():
            child = f"{path}.{key}" if path else str(key)
            yield child, str(key)
            yield from strings(value, child)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from strings(value, f"{path}[{index}]")
    elif isinstance(node, str):
        yield path, node


def expressions(path: str, text: str) -> str:
    """Return the expression text of a workflow string.

    An ``if:`` value is an expression whole; elsewhere only the inside of each
    ``${{ }}`` is (shell text and comments are not read by the runner).

    Args:
        path: The dotted path of the string.
        text: The string.

    Returns:
        str: The expressions, joined by newlines.
    """
    if path == "if" or path.endswith(".if"):
        return text
    return "\n".join(EXPRESSION.findall(text))


def located(workflow: dict[Any, Any]) -> Iterator[tuple[str, str, str]]:
    """Yield the expressions of the workflow env and the jobs, with where they are.

    Args:
        workflow: The parsed workflow.

    Yields:
        tuple[str, str, str]: The step name (or the scope outside the steps),
        the field path inside it, and its expression text.
    """
    scopes: list[tuple[str, Any]] = [("workflow", {"env": workflow.get("env", {})})]
    for job_id, job in workflow["jobs"].items():
        outside = {key: value for key, value in job.items() if key != "steps"}
        scopes.append((f"job {job_id}", outside))
        for entry in job.get("steps", []):
            label = entry.get("name") or entry.get("id") or entry.get("uses", "")
            scopes.append((label, entry))
    for where, node in scopes:
        for path, text in strings(node):
            found = expressions(path, text)
            if found:
                yield where, path, found


def secrets_context(app_mode: bool, given: dict[str, str]) -> dict[str, Any]:
    """Bind the input and every secret the job reads; unset secrets are empty.

    Args:
        app_mode: The ``cleanup-app-token`` input.
        given: The secrets the caller passes, by name.

    Returns:
        dict[str, Any]: The flat evaluator context.
    """
    context: dict[str, Any] = {f"inputs.{INPUT}": app_mode}
    for name in WATCHED:
        context[f"secrets.{name}"] = given.get(name, "")
    return context


def render_env(
    evaluator: ModuleType,
    check: dict[str, Any],
    context: dict[str, Any],
) -> dict[str, str]:
    """Render the check step's env as the runner would (booleans as text).

    Args:
        evaluator: The ``gha_expr`` module.
        check: The check step.
        context: The evaluator context.

    Returns:
        dict[str, str]: The step's environment values.
    """
    rendered: dict[str, str] = {}
    for key, template in check["env"].items():
        value = evaluator.render(template, context)
        rendered[key] = str(value).lower() if isinstance(value, bool) else str(value)
    return rendered


def run_step(
    check: dict[str, Any],
    env: dict[str, str],
    tmp_path: Path,
) -> tuple[int, str, str]:
    """Run the shipped check step text under bash.

    Args:
        check: The check step.
        env: The step's environment values.
        tmp_path: Scratch directory for the step output file.

    Returns:
        tuple[int, str, str]: Exit status, stdout and the step output file.
    """
    output = tmp_path / "github-output"
    output.write_text("", encoding="utf-8")
    full = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    full["GITHUB_OUTPUT"] = str(output)
    full.update(env)
    argv = ["bash", "-c", check["run"]]
    result = subprocess.run(  # nosec B603 B607 - fixed argv, shipped step text
        argv, check=False, env=full, text=True, capture_output=True
    )
    return result.returncode, result.stdout, output.read_text(encoding="utf-8")


def run_check(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    scenario: tuple[bool, dict[str, str]],
    tmp_path: Path,
) -> tuple[int, str, str]:
    """Render the check step's env for a scenario and run it.

    Args:
        evaluator: The ``gha_expr`` module.
        steps: The job's steps.
        scenario: The ``cleanup-app-token`` input and the secrets passed.
        tmp_path: Scratch directory for the step output file.

    Returns:
        tuple[int, str, str]: Exit status, stdout and the step output file.
    """
    check = step(steps, CHECK)
    env = render_env(evaluator, check, secrets_context(*scenario))
    return run_step(check, env, tmp_path)


def test_input_is_a_boolean_that_defaults_off(workflow: dict[Any, Any]) -> None:
    """App mode is an explicit opt-in: a boolean input, false by default."""
    declared = workflow[True]["workflow_call"]["inputs"][INPUT]

    assert_that(declared["type"]).is_equal_to("boolean")
    assert_that(declared["required"]).is_false()
    assert_that(declared["default"]).is_false()


def test_app_secrets_and_gh_token_are_optional(workflow: dict[Any, Any]) -> None:
    """The three App secrets and GH_TOKEN are declared and all optional."""
    declared = workflow[True]["workflow_call"]["secrets"]
    for name in WATCHED:
        assert_that(declared).described_as(name).contains_key(name)
        assert_that(declared[name]["required"]).described_as(name).is_false()


def test_check_step_reads_only_booleans(steps: list[dict[str, Any]]) -> None:
    """The check step's env is the input and three presence comparisons."""
    check = step(steps, CHECK)

    assert_that(check["env"]).is_equal_to(CHECK_ENV)
    begin = "# lgtm-ci-inline:begin select-cleanup-token\n"
    assert_that(check["run"]).starts_with(begin)


@pytest.mark.parametrize(
    "given",
    [
        COMPLETE,
        {"RELEASE_APP_ID": "123", "RELEASE_APP_PRIVATE_KEY": "key"},
        {"RELEASE_APP_CLIENT_ID": "Iv23li"},
        {"RELEASE_APP_PRIVATE_KEY": "key"},
        {},
    ],
    ids=["complete", "app-id-complete", "id-only", "key-only", "absent"],
)
def test_input_off_with_gh_token_ignores_app_secrets(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
    given: dict[str, str],
) -> None:
    """Input off: complete, incomplete or absent App secrets change nothing."""
    status, stdout, output = run_check(
        evaluator,
        steps,
        (False, {**given, "GH_TOKEN": CALLER}),
        tmp_path,
    )

    assert_that(status).described_as(stdout).is_equal_to(0)
    assert_that(stdout).is_empty()
    assert_that(output).is_equal_to("mode=github-token\n")


@pytest.mark.parametrize(
    "given",
    [COMPLETE, {"RELEASE_APP_PRIVATE_KEY": "key"}, {}],
    ids=["complete", "key-only", "absent"],
)
def test_input_off_without_gh_token_fails_naming_both_and_the_input(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
    given: dict[str, str],
) -> None:
    """Input off and no GH_TOKEN fails, even with a complete App credential."""
    status, stdout, output = run_check(evaluator, steps, (False, given), tmp_path)

    assert_that(status).is_equal_to(1)
    assert_that(stdout).starts_with("::error title=missing cleanup token::")
    assert_that(stdout).contains("GH_TOKEN", INPUT, "RELEASE_APP_PRIVATE_KEY")
    assert_that(output).is_empty()


@pytest.mark.parametrize("gh_token", [CALLER, ""], ids=["gh-token", "no-gh-token"])
@pytest.mark.parametrize(
    "given",
    [
        COMPLETE,
        {"RELEASE_APP_ID": "123", "RELEASE_APP_PRIVATE_KEY": "key"},
        {
            "RELEASE_APP_ID": "123",
            "RELEASE_APP_CLIENT_ID": "Iv23li",
            "RELEASE_APP_PRIVATE_KEY": "key",
        },
    ],
    ids=["client-id", "app-id", "both-ids"],
)
def test_input_on_with_complete_credential_selects_app(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
    given: dict[str, str],
    gh_token: str,
) -> None:
    """Input on with an ID and the key selects the App, GH_TOKEN or not."""
    status, stdout, output = run_check(
        evaluator,
        steps,
        (True, {**given, "GH_TOKEN": gh_token}),
        tmp_path,
    )

    assert_that(status).described_as(stdout).is_equal_to(0)
    assert_that(output).is_equal_to("mode=app\n")


@pytest.mark.parametrize("gh_token", [CALLER, ""], ids=["gh-token", "no-gh-token"])
@pytest.mark.parametrize(
    "given",
    [
        {"RELEASE_APP_CLIENT_ID": "Iv23li"},
        {"RELEASE_APP_ID": "123"},
        {"RELEASE_APP_ID": "123", "RELEASE_APP_CLIENT_ID": "Iv23li"},
        {"RELEASE_APP_PRIVATE_KEY": "key"},
        {},
    ],
    ids=["client-id-only", "app-id-only", "both-ids-no-key", "key-only", "absent"],
)
def test_input_on_with_incomplete_credential_fails(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    tmp_path: Path,
    given: dict[str, str],
    gh_token: str,
) -> None:
    """Input on with half or none of the credential fails; GH_TOKEN never helps."""
    status, stdout, output = run_check(
        evaluator,
        steps,
        (True, {**given, "GH_TOKEN": gh_token}),
        tmp_path,
    )

    assert_that(status).is_equal_to(1)
    assert_that(stdout).starts_with("::error title=incomplete App credential::")
    assert_that(output).is_empty()


@pytest.mark.parametrize(
    "flag",
    ["APP_MODE", "APP_ID_SET", "APP_KEY_SET", "GH_TOKEN_SET"],
)
def test_catch_all_fails_on_a_flag_that_is_not_boolean(
    steps: list[dict[str, Any]],
    tmp_path: Path,
    flag: str,
) -> None:
    """A value other than true or false never falls through to a mode."""
    env = dict.fromkeys(CHECK_ENV, "true")
    env[flag] = "maybe"
    status, stdout, output = run_step(step(steps, CHECK), env, tmp_path)

    assert_that(status).is_equal_to(1)
    assert_that(stdout).starts_with("::error title=unexpected cleanup token state::")
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


def test_no_step_continues_on_error(workflow: dict[Any, Any]) -> None:
    """Fail closed: no step of the job, and the job itself, continues on error."""
    job = workflow["jobs"][JOB]

    assert_that(job).does_not_contain_key("continue-on-error")
    for entry in job["steps"]:
        assert_that(entry).described_as(entry.get("name")).does_not_contain_key(
            "continue-on-error",
        )


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
    ("scenario", "minted", "expected"),
    [
        ((True, COMPLETE), MINTED, MINTED),
        ((True, {**COMPLETE, "GH_TOKEN": CALLER}), MINTED, MINTED),
        ((True, {**COMPLETE, "GH_TOKEN": CALLER}), "", SENTINEL),
        ((True, COMPLETE), "", SENTINEL),
        ((False, {**COMPLETE, "GH_TOKEN": CALLER}), "", CALLER),
        ((False, {**COMPLETE, "GH_TOKEN": CALLER}), MINTED, CALLER),
        ((False, {"GH_TOKEN": CALLER}), "", CALLER),
    ],
    ids=[
        "app",
        "app-over-gh-token",
        "app-mint-empty-no-fallback",
        "app-mint-empty",
        "off-ignores-app-secrets",
        "off-never-reads-the-mint",
        "gh-token",
    ],
)
def test_consumers_follow_the_input(
    evaluator: ModuleType,
    steps: list[dict[str, Any]],
    scenario: tuple[bool, dict[str, str]],
    minted: str,
    expected: str,
) -> None:
    """Input on: the minted token or the placeholder; input off: GH_TOKEN."""
    context = secrets_context(*scenario)
    context["steps.app-token.outputs.token"] = minted
    for name, template in token_templates(steps).items():
        rendered = evaluator.render(template, context)
        assert_that(rendered).described_as(name).is_equal_to(expected)


def test_checkout_does_not_persist_the_token(steps: list[dict[str, Any]]) -> None:
    """The repository checkout keeps no credential for later steps."""
    assert_that(step(steps, CHECKOUT)["with"]["persist-credentials"]).is_false()


def test_watched_secrets_are_read_only_where_allowed(workflow: dict[Any, Any]) -> None:
    """Every reference to an App secret or GH_TOKEN, in any spelling, is allowed.

    A value read is allowed only at its listed reader; a presence comparison
    (``!= ''``) only in the check step's env. No expression may take the
    whole ``secrets`` context.
    """
    problems: list[str] = []
    for where, path, text in located(workflow):
        if BARE_SECRETS.search(text):
            problems.append(f"{where} {path}: the whole secrets context")
        for match in SECRET_REF.finditer(text):
            name = (match[1] or match[2]).upper()
            if name not in WATCHED:
                continue
            presence = PRESENCE.match(text[match.end() :]) is not None
            if presence and where == CHECK and path.startswith("env."):
                continue
            if not presence and (where, path) in VALUE_READERS[name]:
                continue
            kind = "presence check" if presence else "value read"
            problems.append(f"{where} {path}: {kind} of {name}")

    assert_that(problems).is_empty()


def test_minted_token_is_read_only_by_the_two_consumers(
    workflow: dict[Any, Any],
) -> None:
    """Only the checkout and the cleanup step read the token, in any spelling."""
    readers = set()
    problems: list[str] = []
    for where, path, text in located(workflow):
        if BARE_STEPS.search(text):
            problems.append(f"{where} {path}: the whole steps context")
        if TOKEN_REF.search(text):
            readers.add((where, path))

    assert_that(problems).is_empty()
    assert_that(readers).is_equal_to(TOKEN_READERS)


def test_no_output_or_shared_env_carries_a_token(workflow: dict[Any, Any]) -> None:
    """No job or workflow output exists, and no shared env names a token."""
    job = workflow["jobs"][JOB]

    assert_that(job).does_not_contain_key("outputs")
    assert_that(workflow[True]["workflow_call"]).does_not_contain_key("outputs")
    for scope in (workflow.get("env", {}), job.get("env", {})):
        text = yaml.safe_dump(scope).lower()
        assert_that(text).does_not_contain("app-token", "release_app", "gh_token")


@pytest.mark.parametrize(
    "spelling",
    [
        "${{ secrets.RELEASE_APP_PRIVATE_KEY || '' }}",
        "${{ secrets [ 'release_app_private_key' ] }}",
        "${{ SECRETS.Release_App_Id }}",
        "${{ toJSON(secrets) }}",
        "${{ steps['app-token'].outputs.token }}",
        "${{ toJSON(steps) }}",
    ],
)
def test_reader_checks_catch_other_spellings(
    workflow: dict[Any, Any],
    spelling: str,
) -> None:
    """A stray reader in another spelling is reported by one of the checks."""
    edited = yaml.safe_load(yaml.safe_dump(workflow))
    install = step(edited["jobs"][JOB]["steps"], "Install osv-scanner")
    install["env"]["STRAY"] = spelling

    caught = 0
    for check in (
        test_watched_secrets_are_read_only_where_allowed,
        test_minted_token_is_read_only_by_the_two_consumers,
    ):
        try:
            check(edited)
        except AssertionError:
            caught += 1
    assert_that(caught).is_greater_than(0)


def test_job_permissions_are_unchanged(workflow: dict[Any, Any]) -> None:
    """Minting needs no job permission beyond the two the job already has."""
    assert_that(workflow["jobs"][JOB]["permissions"]).is_equal_to(
        {"contents": "write", "pull-requests": "write"},
    )
