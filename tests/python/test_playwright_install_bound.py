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

import pytest
import yaml
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "reusable-test-e2e-playwright.yml"
RUNNER_LIB = ROOT / "scripts" / "ci" / "lib" / "testing" / "playwright_runner.sh"
SIGNATURES = ROOT / "scripts" / "ci" / "lib" / "infra-signatures.sh"
LDD_PROBE = ROOT / "scripts" / "ci" / "lib" / "playwright_ldd.py"
STEP_NAME = "Install Playwright browsers"
# Two attempts plus the KILL grace must fit inside the step backstop.
ATTEMPTS = 2
# Seconds of the step kept for start-up, sourcing and the version checks.
STEP_MARGIN_SECONDS = 120
# Every branch of playwright_install_browsers (#1433), as the bounded stages it
# runs in order. "warm" is an exact cache hit with every artifact present;
# "unrecognised" is an install-deps dry run playwright_deps.py cannot read.
# "ready" is the readiness dry run after a cold install (#1659), which gates
# the browser cache save; it runs inside the same budget.
PATHS: dict[str, tuple[str, ...]] = {
    "always, cold": ("apt", "dry_run", "apt", "download", "ready"),
    "always, cold, unrecognised": ("apt", "dry_run", "download", "ready"),
    "always, warm": ("dry_run", "apt", "dry_run", "apt"),
    "always, warm, unrecognised": ("dry_run", "apt", "dry_run", "install_deps"),
    "if-missing, cold, probe passes": ("download", "dry_run", "probe", "ready"),
    "if-missing, cold, probe fails": (
        "download",
        "dry_run",
        "probe",
        "apt",
        "dry_run",
        "apt",
        "ready",
    ),
    "if-missing, cold, probe fails, unrecognised": (
        "download",
        "dry_run",
        "probe",
        "apt",
        "dry_run",
        "install_deps",
        "ready",
    ),
    "if-missing, warm, probe passes": ("dry_run", "probe"),
    "if-missing, warm, probe fails": ("dry_run", "probe", "apt", "dry_run", "apt"),
    "if-missing, warm, probe fails, unrecognised": (
        "dry_run",
        "probe",
        "apt",
        "dry_run",
        "install_deps",
    ),
    "macOS or Windows, cold": ("download", "ready"),
    "Windows, warm": ("dry_run", "install_deps"),
    "macOS, warm": ("dry_run",),
}
# The configured worst case of each path in seconds, before the shared budget
# cuts it: a changed timeout shows up here.
EXPECTED_WORST = {
    "always, cold": 1300,
    "always, cold, unrecognised": 1000,
    "always, warm": 680,
    "always, warm, unrecognised": 690,
    "if-missing, cold, probe passes": 790,
    "if-missing, cold, probe fails": 1430,
    "if-missing, cold, probe fails, unrecognised": 1440,
    "if-missing, warm, probe passes": 130,
    "if-missing, warm, probe fails": 770,
    "if-missing, warm, probe fails, unrecognised": 780,
    "macOS or Windows, cold": 660,
    "Windows, warm": 350,
    "macOS, warm": 40,
}


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


def _library_default(name: str, path: Path = RUNNER_LIB) -> int:
    """Return an integer default assigned at the top level of the library.

    Args:
        name: The variable name, e.g. PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT.
        path: The file that assigns it (``NAME=1`` or ``NAME = 1``).

    Returns:
        The assigned value.
    """
    match = re.search(
        rf"^{name} ?= ?(\d+)$",
        path.read_text(encoding="utf-8"),
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


def _stage_seconds() -> dict[str, int]:
    """Return the configured worst case of each bounded stage.

    Returns:
        Seconds per stage name used in PATHS.
    """
    grace = _library_default(name="PLAYWRIGHT_INSTALL_KILL_GRACE_DEFAULT")
    dry_run = _library_default(name="PLAYWRIGHT_DRY_RUN_TIMEOUT_DEFAULT")
    install_deps = _library_default(name="PLAYWRIGHT_INSTALL_DEPS_TIMEOUT_DEFAULT")
    ldd_budget = _library_default(name="LDD_BUDGET_SECONDS", path=LDD_PROBE)
    ldd_call = _library_default(name="LDD_TIMEOUT_SECONDS", path=LDD_PROBE)
    return {
        # Each apt helper run ends within its run budget (#1571).
        "apt": _library_default(name="PLAYWRIGHT_APT_TIMEOUT_DEFAULT"),
        # Two attempts, each with its KILL grace (#1563).
        "download": ATTEMPTS * (_default_attempt_seconds() + grace),
        # install --dry-run or install-deps --dry-run: one bounded attempt.
        "dry_run": dry_run + grace,
        # The readiness install --dry-run after a cold install (#1659).
        "ready": dry_run + grace,
        # The single install-deps attempt that replaces a second download.
        "install_deps": install_deps + grace,
        # No ldd call starts after the budget; one may have just started.
        "probe": ldd_budget + ldd_call,
    }


def _step_seconds() -> int:
    """Return the install step's ``timeout-minutes`` backstop in seconds.

    Returns:
        The backstop.
    """
    minutes = _install_step().get("timeout-minutes")
    assert_that(minutes).is_instance_of(int)
    return int(minutes or 0) * 60


def test_install_step_has_a_backstop_covering_both_attempts() -> None:
    """The step is bounded, and the shared install budget fits inside it.

    Every bounded stage of playwright_install_browsers is cut to what is left
    of PLAYWRIGHT_INSTALL_BUDGET_DEFAULT (#1433), so the budget, not the sum
    of the stages, is the step's worst case.
    """
    step = _install_step()
    minutes = step.get("timeout-minutes")
    assert isinstance(minutes, int), step
    budget = _library_default(name="PLAYWRIGHT_INSTALL_BUDGET_DEFAULT")
    assert budget + STEP_MARGIN_SECONDS <= minutes * 60 <= 25 * 60, (minutes, budget)


@pytest.mark.parametrize("path", sorted(PATHS))
def test_every_install_path_has_a_pinned_worst_case(path: str) -> None:
    """Each path's configured worst case is pinned, and its cut ends in the step.

    Paths whose stages add up past the shared budget (if-missing on a cold
    cache when the probe fails) are cut to it; every other path ends on its
    own, the shared budget unused.
    """
    stages = _stage_seconds()
    worst = sum(stages[stage] for stage in PATHS[path])
    budget = _library_default(name="PLAYWRIGHT_INSTALL_BUDGET_DEFAULT")

    assert_that(worst).described_as(path).is_equal_to(EXPECTED_WORST[path])
    assert_that(min(worst, budget) + STEP_MARGIN_SECONDS).described_as(
        path,
    ).is_less_than_or_equal_to(_step_seconds())


def test_the_shared_budget_is_what_cuts_the_longest_paths() -> None:
    """Without the shared budget two if-missing paths would outlive the margin."""
    budget = _library_default(name="PLAYWRIGHT_INSTALL_BUDGET_DEFAULT")
    over = sorted(path for path, worst in EXPECTED_WORST.items() if worst > budget)

    assert_that(over).is_equal_to(
        [
            "if-missing, cold, probe fails",
            "if-missing, cold, probe fails, unrecognised",
        ],
    )
    assert_that(set(EXPECTED_WORST)).is_equal_to(set(PATHS))


def test_install_step_fails_the_job() -> None:
    """A double failure must fail the job, never be swallowed."""
    step = _install_step()
    assert "continue-on-error" not in step
    assert step["env"]["STEP"] == "install-browsers"
    assert "run-playwright-tests.sh" in step["run"]


def test_every_browser_download_goes_through_the_retry() -> None:
    """Each download is wrapped in the budget cut and the retry.

    ``install`` only: not ``install-deps`` and not ``install --dry-run``,
    which download nothing and run as one bounded stage each.
    """
    text = RUNNER_LIB.read_text(encoding="utf-8")
    body = text.split("playwright_install_system_packages() {", 1)[1]
    calls = re.findall(r'^\s*(.*)"\$@" install(?![\w-])(?! --dry-run)', body, re.M)
    assert len(calls) == 4, calls
    assert all(call == "playwright_install_within_budget " for call in calls), calls
    wrapper = text.split("playwright_install_within_budget() {", 1)[1]
    body = wrapper.split("\n}\n", 1)[0]
    assert_that(body).contains('playwright_install_with_retry "$@"')


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


def test_the_readiness_check_runs_inside_the_install_budget() -> None:
    """The #1659 readiness dry run is a budget-cut stage of the same install.

    playwright_install_browsers sets the deadline, then runs the install and
    playwright_check_browsers_ready, whose dry run goes through
    playwright_install_locations (playwright_bounded_stage), so it cannot
    outlive the shared budget.
    """
    text = RUNNER_LIB.read_text(encoding="utf-8")
    wrapper = text.split("playwright_install_browsers() {", 1)[1].split("\n}\n", 1)[0]
    deadline = wrapper.index("local _PLAYWRIGHT_INSTALL_DEADLINE=")
    run = wrapper.index('_playwright_install_browsers_run "$browsers" "$@"')
    ready = wrapper.index('playwright_check_browsers_ready "$browsers" "$@"')
    assert_that(deadline < run < ready).is_true()
    check = text.split("playwright_check_browsers_ready() {", 1)[1].split("\n}\n", 1)[0]
    assert_that(check).contains("playwright_install_locations")
    assert_that(check).contains("PLAYWRIGHT_STAGE_MIN_SECONDS")
