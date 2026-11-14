# SPDX-License-Identifier: MIT
"""The Playwright browser install is bounded and retried once (#1563).

A hung browser download (fixture run 43557274435) sat 25 minutes in
`Install Playwright browsers` until the canary budget cancelled the run. The
download now runs under a per-attempt timeout with one retry inside
playwright_install_with_retry, the step has a `timeout-minutes` backstop that
covers both attempts, and a double timeout prints the external canary's
playwright-download signature.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "reusable-test-e2e-playwright.yml"
RUNNER_LIB = ROOT / "scripts" / "ci" / "lib" / "testing" / "playwright_runner.sh"
SIGNATURES = ROOT / "scripts" / "ci" / "lib" / "infra-signatures.sh"
STEP_NAME = "Install Playwright browsers"
# Two attempts plus the KILL grace must fit inside the step backstop.
ATTEMPTS = 2


def _install_step() -> dict[str, Any]:
    """Return the single `Install Playwright browsers` step of the workflow.

    Returns:
        The parsed step mapping.
    """
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    steps: list[dict[str, Any]] = [
        step
        for job in doc["jobs"].values()
        for step in job.get("steps", [])
        if step.get("name") == STEP_NAME
    ]
    assert len(steps) == 1, steps
    return steps[0]


def _library_default(name: str) -> int:
    """Return an integer default assigned at the top level of the library.

    Args:
        name: The variable name, e.g. PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT.

    Returns:
        The assigned value.
    """
    match = re.search(
        rf"^{name}=(\d+)$",
        RUNNER_LIB.read_text(encoding="utf-8"),
        re.M,
    )
    assert match, f"{name} not found"
    return int(match.group(1))


def _default_attempt_seconds() -> int:
    """Return PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT from the runner library.

    Returns:
        The default per-attempt timeout in seconds.
    """
    return _library_default(name="PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT")


def test_install_step_has_a_backstop_covering_both_attempts() -> None:
    """The step is bounded, and the bound leaves room for both attempts."""
    step = _install_step()
    minutes = step.get("timeout-minutes")
    assert isinstance(minutes, int), step
    grace = _library_default(name="PLAYWRIGHT_INSTALL_KILL_GRACE_DEFAULT")
    budget = ATTEMPTS * (_default_attempt_seconds() + grace)
    assert budget < minutes * 60 <= 20 * 60, (minutes, budget)


def test_install_step_fails_the_job() -> None:
    """A double failure must fail the job, never be swallowed."""
    step = _install_step()
    assert "continue-on-error" not in step
    assert step["env"]["STEP"] == "install-browsers"
    assert "run-playwright-tests.sh" in step["run"]


def test_every_browser_download_goes_through_the_retry() -> None:
    """Each `install` call in playwright_install_browsers is wrapped."""
    text = RUNNER_LIB.read_text(encoding="utf-8")
    body = text.split("playwright_install_browsers() {", 1)[1]
    # `install` only, not `install-deps` (the dry run downloads nothing).
    calls = re.findall(r'^\s*(.*)"\$@" install(?![\w-])', body, re.M)
    assert len(calls) == 3, calls
    assert all(call == "playwright_install_with_retry " for call in calls), calls


def test_canary_signature_matches_the_timeout_message_only() -> None:
    """The canary retries a double timeout, never an install error."""
    out = subprocess.run(
        ["bash", "-c", 'source "$1" && infra_canary_signatures', "_", str(SIGNATURES)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    label = "playwright-download\t"
    entries = [line.split("\t") for line in out.splitlines() if line.startswith(label)]
    assert [entry[1] for entry in entries] == [STEP_NAME]
    pattern = re.compile(entries[0][2])
    seconds = _default_attempt_seconds()
    assert pattern.search(
        f"Playwright browser install timed out twice ({seconds}s per attempt)",
    )
    assert not pattern.search(
        "Playwright browser install failed twice (timeout or error)",
    )
    lib = RUNNER_LIB.read_text(encoding="utf-8")
    assert (
        'echo "::error::Playwright browser install timed out twice '
        '(${seconds}s per attempt)"' in lib
    )
