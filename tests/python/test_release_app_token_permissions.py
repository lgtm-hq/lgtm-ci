# SPDX-License-Identifier: MIT
"""Least-privilege contracts for GitHub App installation token mints."""

from pathlib import Path
from typing import Any

import pytest
import yaml
from assertpy import assert_that

GITHUB_DIR = Path(__file__).resolve().parents[2] / ".github"
WORKFLOWS = GITHUB_DIR / "workflows"
MINT_ACTION = "actions/create-github-app-token@"
VERSION_PR_WORKFLOWS = (
    "reusable-release-version-pr.yml",
    "reusable-release-multi-ecosystem.yml",
)
WORKFLOWS_INPUT = "request-workflows-permission"
WORKFLOWS_EXPRESSION = "${{ inputs.request-workflows-permission && 'write' || '' }}"
PACKAGES_INPUT = "inputs.release-metadata-container-package"
PACKAGES_EXPRESSION = "${{ " + PACKAGES_INPUT + " != '' && 'read' || '' }}"
CHECK_STEP = "Refuse workflow file changes"
CHECK_SCRIPT = ".lgtm-ci-tooling/scripts/ci/release/check_workflow_file_changes.py"
CHECK_COMMAND = f"python3 {CHECK_SCRIPT}"

VERSION_PR = "workflows/reusable-release-version-pr.yml"
MULTI_ECOSYSTEM = "workflows/reusable-release-multi-ecosystem.yml"
VERSION_PR_WRITE = {
    "permission-contents": "write",
    "permission-pull-requests": "write",
    "permission-workflows": WORKFLOWS_EXPRESSION,
}
PREPARE_READ = {
    "permission-contents": "read",
    "permission-pull-requests": "read",
    "permission-packages": PACKAGES_EXPRESSION,
}

# Every App token mint under .github/, keyed "file:job:step-id". A new mint,
# or a changed permission on an old one, fails until it is recorded here.
EXPECTED_PERMISSIONS: dict[str, dict[str, str]] = {
    "workflows/duplication-scan.yml:duplication-scan:read-token": {
        "permission-contents": "read",
    },
    "workflows/external-consumer-canary.yml:canary:fixture-token": {
        "permission-actions": "write",
        "permission-contents": "write",
        "permission-workflows": "write",
    },
    "workflows/reusable-ai-review.yml:ai-review:lintro-review-app": {
        "permission-issues": "write",
        "permission-pull-requests": "write",
    },
    "workflows/reusable-release-auto-tag.yml:auto-tag:app-token": {
        "permission-contents": "write",
        "permission-workflows": "write",
    },
    f"{MULTI_ECOSYSTEM}:prepare:app-token": PREPARE_READ,
    f"{MULTI_ECOSYSTEM}:version-pr:app-token": VERSION_PR_WRITE,
    f"{VERSION_PR}:prepare:app-token": PREPARE_READ,
    f"{VERSION_PR}:version-pr:app-token": VERSION_PR_WRITE,
    # Exception: create-github-app-token has no input for the organisation
    # Variables permission the governor writes with, and naming any other
    # permission would drop it. This token keeps the App's own narrow set
    # (see docs/runner-governor.md). Do not add a second empty entry.
    "workflows/runner-governor.yml:governor:token": {},
}
UNLISTED_PERMISSIONS_EXCEPTIONS = frozenset(
    {"workflows/runner-governor.yml:governor:token"},
)


def load(path: Path) -> dict[Any, Any]:
    """Parse one workflow or action file.

    Args:
        path: The YAML file to read.

    Returns:
        The parsed document, or an empty mapping for a non-mapping file.
    """
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    return document if isinstance(document, dict) else {}


def collect_mints() -> dict[str, dict[str, str]]:
    """Find every App token mint under ``.github/``.

    Returns:
        The ``permission-*`` inputs of each mint, keyed "file:job:step-id".
        A composite action's steps are reported under the job name "runs".
    """
    mints: dict[str, dict[str, str]] = {}
    for path in sorted([*GITHUB_DIR.rglob("*.yml"), *GITHUB_DIR.rglob("*.yaml")]):
        document = load(path=path)
        jobs = dict(document.get("jobs") or {})
        if isinstance(document.get("runs"), dict):
            jobs["runs"] = document["runs"]
        for job_name, job in jobs.items():
            for step in (job or {}).get("steps") or []:
                if not str(step.get("uses", "")).startswith(MINT_ACTION):
                    continue
                relative = path.relative_to(GITHUB_DIR).as_posix()
                key = f"{relative}:{job_name}:{step.get('id', step.get('name'))}"
                mints[key] = {
                    name: value
                    for name, value in (step.get("with") or {}).items()
                    if name.startswith("permission-")
                }
    return mints


def version_pr_steps(workflow: str) -> list[dict[str, Any]]:
    """Return the steps of a version-PR reusable's ``version-pr`` job.

    Args:
        workflow: File name under ``.github/workflows``.

    Returns:
        The job's steps in order.
    """
    job = load(path=WORKFLOWS / workflow)["jobs"]["version-pr"]
    steps: list[dict[str, Any]] = job["steps"]
    return steps


def step_index(steps: list[dict[str, Any]], name: str) -> int:
    """Locate a step by its exact name.

    Args:
        steps: The job's steps.
        name: The step name to find.

    Returns:
        The position of the only step with that name.
    """
    matches = [index for index, step in enumerate(steps) if step.get("name") == name]
    assert_that(matches).described_as(name).is_length(1)
    return matches[0]


def test_every_mint_requests_exactly_the_recorded_permissions() -> None:
    """Every mint under .github/ matches the recorded permission map."""
    assert_that(collect_mints()).is_equal_to(EXPECTED_PERMISSIONS)


def test_only_the_governor_mint_omits_permissions() -> None:
    """A mint without permission inputs must be a recorded exception."""
    unlisted = {key for key, grants in collect_mints().items() if not grants}
    assert_that(unlisted).is_equal_to(UNLISTED_PERMISSIONS_EXCEPTIONS)


@pytest.mark.parametrize("key", sorted(EXPECTED_PERMISSIONS))
def test_mint_permissions_cannot_all_be_empty(key: str) -> None:
    """At least one permission is a literal, so the token never inherits all.

    The action skips an empty permission value. If every value on a mint were
    an expression, all could be empty at once and the token would carry every
    permission the App holds.

    Args:
        key: The mint to check.
    """
    if key in UNLISTED_PERMISSIONS_EXCEPTIONS:
        pytest.skip("recorded exception: the action cannot express its scope")
    literals = {
        name: value
        for name, value in collect_mints()[key].items()
        if isinstance(value, str) and value.strip() and "${{" not in value
    }
    assert_that(literals).described_as(key).is_not_empty()


@pytest.mark.parametrize("workflow", VERSION_PR_WORKFLOWS)
def test_version_pr_write_token_permissions(workflow: str) -> None:
    """The write mint keeps two literal scopes and one opt-out scope.

    Args:
        workflow: The version-PR reusable to check.
    """
    steps = version_pr_steps(workflow=workflow)
    mints = [step for step in steps if step.get("id") == "app-token"]
    assert_that(mints).is_length(1)
    assert_that(mints[0]["uses"]).starts_with(MINT_ACTION)
    grants = mints[0]["with"]
    permissions = {k: v for k, v in grants.items() if k.startswith("permission-")}
    assert_that(permissions).is_equal_to(
        {
            "permission-contents": "write",
            "permission-pull-requests": "write",
            "permission-workflows": WORKFLOWS_EXPRESSION,
        },
    )


@pytest.mark.parametrize("workflow", VERSION_PR_WORKFLOWS)
def test_request_workflows_permission_input(workflow: str) -> None:
    """The opt-out is an optional boolean that defaults to requesting.

    Args:
        workflow: The version-PR reusable to check.
    """
    document = load(path=WORKFLOWS / workflow)
    # PyYAML reads the bare `on` key as the boolean True.
    triggers = document.get("on") or document[True]
    declared = triggers["workflow_call"]["inputs"][WORKFLOWS_INPUT]
    assert_that(declared["type"]).is_equal_to("boolean")
    assert_that(declared["default"]).is_true()
    assert_that(declared["required"]).is_false()


@pytest.mark.parametrize("workflow", VERSION_PR_WORKFLOWS)
def test_workflow_file_check_runs_only_without_the_permission(workflow: str) -> None:
    """The check is gated on the input being false and calls the script.

    Args:
        workflow: The version-PR reusable to check.
    """
    steps = version_pr_steps(workflow=workflow)
    check = steps[step_index(steps=steps, name=CHECK_STEP)]
    conditions = [clause.strip() for clause in check["if"].split("&&")]
    assert_that(conditions).contains("!inputs.request-workflows-permission")
    assert_that(conditions).contains(
        "steps.version.outputs.release-needed == 'true'",
    )
    assert_that(check["run"].strip()).is_equal_to(CHECK_COMMAND)
    assert_that(check).does_not_contain_key("continue-on-error")
    references = [
        step.get("name")
        for step in steps
        if "check_workflow_file_changes" in str(step.get("run", ""))
    ]
    assert_that(references).is_equal_to([CHECK_STEP])


@pytest.mark.parametrize("workflow", VERSION_PR_WORKFLOWS)
def test_workflow_file_check_sits_between_updates_and_publish(workflow: str) -> None:
    """Every writer runs before the check; the tooling and the PR come after.

    Args:
        workflow: The version-PR reusable to check.
    """
    steps = version_pr_steps(workflow=workflow)
    check = step_index(steps=steps, name=CHECK_STEP)
    writers = [
        index
        for index, step in enumerate(steps)
        if "/scripts/ci/release/ecosystems/" in str(step.get("run", ""))
        or step.get("name") in {"Update CHANGELOG.md", "Apply version update changes"}
    ]
    assert_that(len(writers)).is_greater_than_or_equal_to(3)
    assert_that(max(writers)).is_less_than(check)
    publish = step_index(steps=steps, name="Create or update version PR")
    # The exact steps between the check and publication. None of them writes
    # to the working tree. A step added here must be reviewed for that, and a
    # writer belongs before the check.
    between = [step.get("name") for step in steps[check + 1 : publish]]
    assert_that(between).is_equal_to(
        [
            "Check for version file changes",
            "Check version PR merge queue",
            "Notice skipped queued version PR update",
            "Remove tooling checkout before PR creation",
            # Generated agent recheck (#1551): reads systemd state and
            # resolved.conf from runner.temp, writes nothing.
            "Recheck harden-runner agent before Create or update version PR",
        ],
    )
