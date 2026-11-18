# SPDX-License-Identifier: MIT
"""``GH_REPO`` is refused unless its value keeps gh on the runner's host (#1624).

gh reads ``GH_REPO`` as ``[HOST/]OWNER/REPO``: a host part sends gh's API
calls, with its token, to that host. An ``env:`` may set it only to the
calling repository (``${{ github.repository }}``) or to a literal
``OWNER/REPO`` with exactly two segments.
"""

from __future__ import annotations

import importlib
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from inline_shell_support import (
    HEADER,
    JOB_STEPS,
    LEVELS,
    ROOT,
    SCRIPT,
    SCRIPT_PATH,
    indented,
    make_repo,
    passes,
    rejected,
    step,
    write_env_at,
    write_workflow,
)

ALLOWED = [
    pytest.param("${{ github.repository }}", id="calling-repository"),
    pytest.param("${{github.repository}}", id="calling-repository-tight"),
    pytest.param("owner/repo", id="literal"),
    pytest.param("my-org/my.repo_1", id="literal-punctuation"),
]
REFUSED = [
    pytest.param("host.example/owner/repo", id="host-qualified"),
    pytest.param("${{ inputs.repository }}", id="caller-input"),
    pytest.param("${{ github.server_url }}/x", id="server-url"),
    pytest.param("${{ github.repository }}/x", id="calling-repository-suffix"),
    pytest.param("owner", id="one-segment"),
    pytest.param("-owner/repo", id="leading-dash"),
    pytest.param("owner/repo\n", id="trailing-newline"),
    pytest.param("''", id="empty"),
]


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which puts its rule modules on ``sys.path``."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository with the sources the checks read."""
    return Path(make_repo(tmp_path))


def _quoted(value: str) -> str:
    """Return ``value`` as a YAML double-quoted scalar (empty stays ``''``)."""
    if value == "''":
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


@pytest.mark.parametrize("level", LEVELS)
@pytest.mark.parametrize("value", ALLOWED)
def test_gh_repo_on_the_runner_host_passes(
    check: ModuleType,
    repo: Path,
    level: str,
    value: str,
) -> None:
    """The calling repository and a literal OWNER/REPO name no host."""
    write_env_at(repo, level, f"\n  GH_REPO: {_quoted(value)}")
    passes(check, repo, "script-call")


@pytest.mark.parametrize("level", LEVELS)
@pytest.mark.parametrize("value", REFUSED)
def test_gh_repo_that_can_name_a_host_is_refused(
    check: ModuleType,
    repo: Path,
    level: str,
    value: str,
) -> None:
    """A host part, or a value the check cannot read as two segments, is refused."""
    write_env_at(repo, level, f"\n  GH_REPO: {_quoted(value)}")
    rejected(check, repo, "sets GH_REPO, which can weaken TLS or redirect traffic")


def test_gh_repo_that_is_not_a_scalar_is_refused(check: ModuleType, repo: Path) -> None:
    """A mapping or list value is not a repository the check can read."""
    write_env_at(repo, "step", "\n  GH_REPO: [owner/repo]")
    rejected(check, repo, "sets GH_REPO")


def test_a_job_value_is_read_even_when_the_step_sets_a_safe_one(
    check: ModuleType,
    repo: Path,
) -> None:
    """Each scope's value is judged: the job's reaches the job's other steps."""
    header = HEADER.replace(
        JOB_STEPS,
        "    env:\n      GH_REPO: host.example/owner/repo\n" + JOB_STEPS,
    )
    call = step(f"bash {SCRIPT}")
    pad = "        "
    block = indented("env:\n  GH_REPO: owner/repo", pad)
    write_workflow(repo, call.replace(f"{pad}run:", f"{block}{pad}run:"), header=header)
    rejected(check, repo, "sets GH_REPO")


@pytest.mark.parametrize(
    ("value", "refused"),
    [
        pytest.param('"${{ github.repository }}"', False, id="calling-repository"),
        pytest.param('"${{ inputs.repository }}"', True, id="caller-input"),
    ],
)
def test_a_uses_step_gh_repo_is_read_by_value(
    check: ModuleType,
    repo: Path,
    value: str,
    refused: bool,
) -> None:
    """The ``env:`` of a step without ``run:`` is judged by value as well."""
    uses = (
        "      - name: Call\n"
        "        uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955\n"
        f"        env:\n          GH_REPO: {value}\n"
    )
    write_workflow(repo, step(f"bash {SCRIPT}"), uses)
    steps, errors = check.check(repo)
    lines = "\n".join(check.report(steps, errors))
    assert_that("step env: sets GH_REPO" in lines).is_equal_to(refused)


def test_the_reference_names_each_allowed_value_pattern(check: ModuleType) -> None:
    """docs/inline-shell.md writes the patterns the exception matches, verbatim.

    ``test_docs_list_each_set_exactly`` pins the names; this pins the values,
    so a pattern cannot widen without the Reference changing with it.
    """
    del check
    denylist = importlib.import_module("inline_shell_denylist")
    docs = (ROOT / "docs" / "inline-shell.md").read_text(encoding="utf-8")
    reference = docs.split("## Reference", 1)[1].replace("\n  ", " ")
    prefix = "- `VALUE_EXCEPTIONS`:"
    line = next(text for text in reference.splitlines() if text.startswith(prefix))
    assert_that(sorted(denylist.VALUE_EXCEPTIONS)).is_equal_to(["GH_REPO"])
    for name in ("CALLING_REPOSITORY", "OWNER_REPO"):
        pattern = getattr(denylist, name).pattern
        assert_that(line).contains(f"`{name}`, `{pattern}`")
    assert_that(denylist.protected_reason("GH_REPO")).is_equal_to(denylist.TLS_REASON)
