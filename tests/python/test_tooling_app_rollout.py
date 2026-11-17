# SPDX-License-Identifier: MIT
"""Every reusable with a tooling consumer takes the tooling App pair (#1622).

``docs/workflow-contract.md`` ("Tooling App credential") states the rule in
its **Rollout** paragraph: a caller may pass the App secrets to every
reusable that checks out the tooling, and to the reusables that only forward
them to one. This test holds the workflows to that rule instead of to a
hand-kept list:

- every reusable with a tooling consumer (a tooling checkout or a
  ``checkout-and-harden`` call, classified as ``validate_tooling_token.py``
  classifies them) declares both App secrets;
- every workflow that declares either App secret has a tooling consumer, or
  forwards both secrets to a local reusable that declares them;
- the reusables the paragraph names as forwarding only are exactly those.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
CONTRACT = ROOT / "docs" / "workflow-contract.md"
SECTION = "### Tooling App credential"
ROLLOUT = "**Rollout:**"
SCRIPT_PATH = "scripts/ci/quality/validate_tooling_token.py"
SECRETS = ("LGTM_CI_TOOLING_APP_CLIENT_ID", "LGTM_CI_TOOLING_APP_PRIVATE_KEY")
REUSABLE = re.compile(r"`(reusable-[\w.-]+\.ya?ml)`")
LOCAL_WORKFLOW = re.compile(r"\./\.github/workflows/([^/@]+\.ya?ml)")


@pytest.fixture(name="survey", scope="module")
def fixture_survey(
    load_script: Callable[[str], ModuleType],
) -> dict[str, tuple[bool, set[str], set[str]]]:
    """Read every workflow the way the tooling token validator does.

    Args:
        load_script: Loads a script under the repository root as a module.

    Returns:
        dict[str, tuple[bool, set[str], set[str]]]: Per checked workflow
        file name: whether it has a tooling consumer, the App secrets it
        declares, and the local reusables it forwards both App secrets to.
    """
    validator = load_script(SCRIPT_PATH)
    found: dict[str, tuple[bool, set[str], set[str]]] = {}
    for path in sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]):
        check = validator.WorkflowCheck(path)
        check.run()
        if not (path.name.startswith("reusable-") or validator.is_reusable(check.root)):
            continue
        consumer = bool(check.tooling_uses or check.composite_uses)
        declared = validator.fields(
            validator.descend(check.root, "on", "workflow_call", "secrets"),
        )
        targets: set[str] = set()
        for _, job in validator.fields(validator.descend(check.root, "jobs")).values():
            uses = validator.descend(job, "uses")
            given = validator.fields(validator.descend(job, "secrets"))
            local = LOCAL_WORKFLOW.fullmatch(uses.text.strip()) if uses else None
            if local and all(name in given for name in SECRETS):
                targets.add(local.group(1))
        found[path.name] = (
            consumer,
            {name for name in SECRETS if name in declared},
            targets,
        )
    return found


def rollout_paragraph() -> str:
    """Return the Rollout paragraph of the Tooling App credential section.

    The section ends at the next ``##`` or ``###`` heading, not at any line
    that starts with ``#``, so a comment line in a code block cannot cut it
    short.

    Returns:
        str: The paragraph from ``**Rollout:**`` to the next blank line.
    """
    text = CONTRACT.read_text(encoding="utf-8")
    assert_that(text).described_as(f"{CONTRACT.name} section").contains(SECTION)
    section = re.split(r"\n###? ", text.split(SECTION, 1)[1], maxsplit=1)[0]
    assert_that(section).described_as(
        f"the {ROLLOUT} paragraph of {SECTION!r} in {CONTRACT.name}",
    ).contains(ROLLOUT)
    start = section.index(ROLLOUT)
    return section[start:].split("\n\n", 1)[0]


def test_every_reusable_with_a_tooling_consumer_takes_the_pair(
    survey: dict[str, tuple[bool, set[str], set[str]]],
) -> None:
    """A reusable that checks out the tooling declares both App secrets."""
    consumers = {name for name, (consumer, _, _) in survey.items() if consumer}
    missing = {
        name: sorted(set(SECRETS) - declared)
        for name, (consumer, declared, _) in survey.items()
        if consumer and declared != set(SECRETS)
    }

    assert_that(consumers).is_not_empty()
    assert_that(missing).is_empty()


def test_every_declaring_reusable_consumes_or_forwards(
    survey: dict[str, tuple[bool, set[str], set[str]]],
) -> None:
    """A reusable that declares the pair uses it or hands it on.

    One that only forwards must forward to a reusable that declares the pair,
    so the secrets always end at a tooling consumer.
    """
    declaring = {name for name, (_, declared, _) in survey.items() if declared}
    idle = sorted(
        name
        for name, (consumer, _, targets) in survey.items()
        if name in declaring and not consumer and not targets & declaring
    )

    assert_that(declaring).is_not_empty()
    assert_that(idle).is_empty()


def test_rollout_paragraph_names_the_forwarding_only_reusables(
    survey: dict[str, tuple[bool, set[str], set[str]]],
) -> None:
    """The paragraph names exactly the reusables that take the pair to forward it."""
    forwarding_only = sorted(
        name for name, (uses, declared, _) in survey.items() if declared and not uses
    )

    assert_that(forwarding_only).is_not_empty()
    assert_that(sorted(set(REUSABLE.findall(rollout_paragraph())))).is_equal_to(
        forwarding_only,
    )
