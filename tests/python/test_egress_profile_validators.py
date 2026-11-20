# SPDX-License-Identifier: MIT
"""A copy generated with each egress profile passes the copy's own validators (#1688).

An adopter generates a copy with ``render-egress-profile.py`` and runs this
repository's CI on it, so the validators shipped in the copy check the
rewritten workflows. Each profile is written into a temporary directory,
removed afterwards, and these run from the copy, on the copy:

- ``validate-tooling-token.sh``: a step the profile puts before the tooling
  App mint must be a reviewed shape (the notice step, #1688);
- ``validate_inline_shell.py``: every ``run:`` step is a script call, a
  generated copy that equals its source, or trivial.

The other validators listed in AGENTS.md cannot apply to the generated
surface: the catalog, deprecation, doc-pin and caller-permission checks read
``docs/``, ``catalog/`` or git history, which a copy does not hold; the source
and test standards read files the generator copies unchanged or not at all;
and ``sync_inline_blocks.py --check`` counts verify and recheck blocks a
non-block copy no longer has (docs/workflow-contract.md).
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterator
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/bootstrap/render-egress-profile.py"
ACTION = ".github/actions/checkout-and-harden/action.yml"
FIRST = "step runs FIRST in the job"
PROFILES = ("block", "audit", "none")
# The copy's own validators, run with the interpreter of this test run (which
# has PyYAML) and no repository override, so each reads the copy it ships in.
VALIDATORS = {
    "tooling-token": ("bash", "scripts/ci/quality/validate-tooling-token.sh"),
    "inline-shell": (sys.executable, "scripts/ci/quality/validate_inline_shell.py"),
}


@pytest.fixture(name="render", scope="module")
def fixture_render(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the renderer without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="copies", scope="module")
def fixture_copies(render: ModuleType) -> Iterator[dict[str, Path]]:
    """Write every profile into one temporary directory, removed afterwards."""
    with tempfile.TemporaryDirectory(prefix="egress-profile-") as scratch:
        copies: dict[str, Path] = {}
        for profile in PROFILES:
            out = Path(scratch).resolve() / profile
            code = render.main(["--profile", profile, "--out", str(out)])
            assert_that(code, description=profile).is_equal_to(0)
            copies[profile] = out
        yield copies


def _validate(copy: Path, command: tuple[str, str]) -> subprocess.CompletedProcess[str]:
    """Run one of the copy's validators in the copy."""
    keep = ("HOME", "LANG", "LC_ALL", "PATH", "TMPDIR")
    env = {key: os.environ[key] for key in keep if key in os.environ}
    env["PYTHON"] = sys.executable
    return subprocess.run(  # noqa: S603 - fixed argv, no shell
        [command[0], str(copy / command[1])],
        cwd=copy,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def _load(path: Path) -> dict[str, Any]:
    """Parse one YAML file of a copy."""
    document: dict[str, Any] = yaml.safe_load(path.read_text(encoding="utf-8"))
    return document


@pytest.mark.parametrize("validator", sorted(VALIDATORS))
@pytest.mark.parametrize("profile", PROFILES)
def test_copy_passes_its_validators(
    copies: dict[str, Path],
    profile: str,
    validator: str,
) -> None:
    """No profile adds a step the copy's own validators refuse."""
    result = _validate(copies[profile], VALIDATORS[validator])

    output = result.stdout[-4000:] + result.stderr[-2000:]
    assert_that(result.returncode, description=output).is_equal_to(0)


@pytest.mark.parametrize("profile", ["audit", "none"])
def test_copy_carries_the_notice_before_the_mint(
    copies: dict[str, Path],
    profile: str,
) -> None:
    """The passing run did check notice steps: the copy has them (#1688)."""
    workflow = copies[profile] / ".github/workflows/reusable-semantic-pr-title.yml"
    text = workflow.read_text(encoding="utf-8")

    notice = text.index("# lgtm-ci-inline:begin egress-profile-notice")
    mint = text.index("# lgtm-ci-inline:begin tooling-app-mint")
    assert_that(notice).is_less_than(mint)


def test_checkout_and_harden_description_matches_each_profile(
    copies: dict[str, Path],
) -> None:
    """``none`` drops the harden-runner-first claim; block and audit keep it."""
    descriptions = {
        profile: " ".join(_load(copy / ACTION)["description"].split())
        for profile, copy in copies.items()
    }

    assert_that(descriptions["block"]).contains(FIRST)
    assert_that(descriptions["audit"]).is_equal_to(descriptions["block"])
    assert_that(descriptions["none"]).does_not_contain(FIRST)
    assert_that(descriptions["none"]).does_not_contain("step-security")
    assert_that(descriptions["none"]).contains(
        "In this copy (egress profile none, #1597) harden-runner is not run",
    )
