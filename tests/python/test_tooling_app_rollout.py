# SPDX-License-Identifier: MIT
"""The documented tooling App rollout matches the workflows (#1622).

``docs/workflow-contract.md`` ("Tooling App credential") lists, in its
**Rollout** paragraph, every reusable that accepts the App secrets. A caller
reads that list to know where it may pass the pair; passing it to any other
reusable is a workflow error. This test holds the list to the reusables that
declare ``LGTM_CI_TOOLING_APP_CLIENT_ID``, so a slice cannot convert a
reusable without naming it, or name one it did not convert.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
CONTRACT = ROOT / "docs" / "workflow-contract.md"
SECTION = "### Tooling App credential"
ROLLOUT = "**Rollout:**"
CLIENT_ID = "LGTM_CI_TOOLING_APP_CLIENT_ID"
REUSABLE = re.compile(r"`(reusable-[\w.-]+\.ya?ml)`")


def declaring_workflows() -> set[str]:
    """Return the workflow files that declare the App client ID secret.

    Returns:
        set[str]: File names under ``.github/workflows``.
    """
    found: set[str] = set()
    for path in [*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        # PyYAML reads the bare key `on` as the Boolean True.
        trigger = document.get("on", document.get(True))
        call = trigger.get("workflow_call") if isinstance(trigger, dict) else None
        secrets = call.get("secrets") if isinstance(call, dict) else None
        if isinstance(secrets, dict) and CLIENT_ID in secrets:
            found.add(path.name)
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


def test_rollout_paragraph_names_exactly_the_converted_reusables() -> None:
    """The documented list equals the reusables that declare the App pair."""
    documented = set(REUSABLE.findall(rollout_paragraph()))
    declared = declaring_workflows()

    assert_that(declared).is_not_empty()
    assert_that(sorted(documented)).is_equal_to(sorted(declared))
