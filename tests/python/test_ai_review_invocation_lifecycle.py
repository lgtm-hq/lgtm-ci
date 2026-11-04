# SPDX-License-Identifier: MIT
"""Dummy-only invocation ownership regressions through production orchestration."""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci/actions/ai_review_auth.py"
SPEC = importlib.util.spec_from_file_location("invocation_auth", SCRIPT)
assert SPEC and SPEC.loader
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)


@pytest.fixture(name="lane")
def fixture_lane(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Use synthetic homes and external roots, never ambient auth or a provider."""
    home = tmp_path / "home"
    home.mkdir()
    external = tmp_path / "external"
    external.mkdir()
    monkeypatch.setattr(AUTH, "EXECUTION_BASE", external)
    monkeypatch.setattr(AUTH, "external_base", lambda: external)
    for key, value in {
        "HOME": str(home),
        "GITHUB_RUN_ID": "1242",
        "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_JOB": "review",
        "GITHUB_WORKSPACE": str(tmp_path / "workspace"),
        "GITHUB_OUTPUT": str(tmp_path / "output"),
        "AI_REVIEW_INVOCATION": "a" * 32,
    }.items():
        monkeypatch.setenv(key, value)
    return home


def test_duplicate_preserves_roots(lane: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A failed exclusive HOME acquisition must not delete prepared E."""
    home = AUTH.owned_home()
    assert home.parent == lane
    execution = AUTH.execution_root(home)
    AUTH.prepare_execution(execution)
    AUTH.create_owned_root(home)
    (home / "sentinel").write_text("live-home")
    (execution / "sentinel").write_text("live-execution")
    row = ["openai", "cli", "api_key", "", "CODEX_API_KEY", "codex", ""]
    monkeypatch.setattr(AUTH, "selected_row", lambda: row)
    monkeypatch.setattr(AUTH, "child_environment", lambda *_args: {})
    monkeypatch.setenv("CODEX_API_KEY", "dummy")
    monkeypatch.setattr(sys, "argv", [str(SCRIPT)])
    with pytest.raises(FileExistsError):
        AUTH.main()
    assert (home / "sentinel").read_text() == "live-home"
    assert (execution / "sentinel").read_text() == "live-execution"


@pytest.mark.parametrize("prepared", [False, True])
def test_other_invocation_cleanup_preserves_live_roots(
    lane: Path, monkeypatch: pytest.MonkeyPatch, prepared: bool
) -> None:
    """A second same-job invocation cannot clean the first invocation's roots."""
    home = AUTH.owned_home()
    assert home.parent == lane
    execution = AUTH.execution_root(home)
    AUTH.prepare_execution(execution)
    AUTH.create_owned_root(home)
    (home / "sentinel").touch()
    (execution / "sentinel").touch()
    monkeypatch.setenv("AI_REVIEW_INVOCATION", "b" * 32)
    other_execution = AUTH.execution_root(AUTH.owned_home())
    if prepared:
        AUTH.prepare_execution(other_execution)
        # Installation fails after writing only credential-free invocation B data.
        (other_execution / "ai-tools").mkdir()
        (other_execution / "ai-tools/partial-install").touch()
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--cleanup"])
    AUTH.main()
    assert not other_execution.exists()
    assert (home / "sentinel").exists()
    assert (execution / "sentinel").exists()


def test_init_allocates_unique_ids_without_credentials(lane: Path) -> None:
    """Each workflow obtains its own binding before installation or auth."""
    output = Path(os.environ["GITHUB_OUTPUT"])
    for _ in range(2):
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--init-invocation"],
            env={"GITHUB_OUTPUT": str(output), "HOME": str(lane)},
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
    lines = output.read_text(encoding="utf-8").splitlines()
    identities = [line.removeprefix("invocation=") for line in lines]
    assert len(identities) == 2
    assert all(re.fullmatch(r"[0-9a-f]{32}", value) for value in identities)
    assert identities[0] != identities[1]
    assert not list(lane.iterdir())


@pytest.mark.parametrize("option", ["--cleanup", "review"])
def test_live_lease_rejects_real_second_process(
    lane: Path,
    tmp_path: Path,
    option: str,
) -> None:
    """A replay cannot delete either root while a review owns the lease."""
    home = AUTH.owned_home()
    assert home.parent == lane
    execution = AUTH.execution_root(home)
    AUTH.prepare_execution(execution)
    AUTH.create_owned_root(home)
    (home / "sentinel").touch()
    (execution / "sentinel").touch()
    driver = tmp_path / "driver.py"
    driver.write_text(
        "import importlib.util, os, sys\nfrom pathlib import Path\n"
        f"s=importlib.util.spec_from_file_location('auth', {str(SCRIPT)!r})\n"
        "a=importlib.util.module_from_spec(s); s.loader.exec_module(a)\n"
        f"a.EXECUTION_BASE=Path({str(execution.parent)!r})\n"
        "a.external_base=lambda: a.EXECUTION_BASE\n"
        "a.selected_row=lambda: ['openai','cli','api_key','',"
        "'CODEX_API_KEY','codex','']\n"
        "sys.exit(a.main())\n"
    )
    args = [] if option == "review" else [option]
    with AUTH.root_lease(execution):
        result = subprocess.run(
            [sys.executable, "-I", str(driver), *args],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode != 0
        assert "BlockingIOError" in result.stderr
        assert (home / "sentinel").exists()
        assert (execution / "sentinel").exists()
    # Releasing the lease permits the exact same always-cleanup target.
    with pytest.MonkeyPatch.context() as patcher:
        patcher.setattr(sys, "argv", [str(SCRIPT), "--cleanup"])
        assert AUTH.main() == 0
    assert not home.exists()
    assert not execution.exists()


@pytest.mark.parametrize("failure", ["collision", "output"])
def test_failed_prepare_then_always_cleanup_preserves_other_invocation(
    lane: Path,
    monkeypatch: pytest.MonkeyPatch,
    failure: str,
) -> None:
    """Rollback of a failed fresh invocation must leave live A untouched."""
    home_a = AUTH.owned_home()
    execution_a = AUTH.execution_root(home_a)
    AUTH.prepare_execution(execution_a)
    AUTH.create_owned_root(home_a)
    (home_a / "sentinel").touch()
    (execution_a / "sentinel").touch()
    monkeypatch.setenv("AI_REVIEW_INVOCATION", "b" * 32)
    execution_b = AUTH.execution_root(AUTH.owned_home())
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--prepare-execution"])
    if failure == "collision":
        # Exercise exclusive mkdir against a live marked root, not a mocked error.
        with pytest.raises(FileExistsError):
            AUTH.prepare_execution(execution_a)
    else:
        monkeypatch.setenv("GITHUB_OUTPUT", str(lane))
        with pytest.raises(IsADirectoryError):
            AUTH.main()
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--cleanup"])
    assert AUTH.main() == 0
    assert not execution_b.exists()
    assert (home_a / "sentinel").exists()
    assert (execution_a / "sentinel").exists()


def test_missing_invocation_cleanup_cannot_target_live_roots(
    lane: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A skipped/failed initialization gives always-cleanup no ownership."""
    home = AUTH.owned_home()
    assert home.parent == lane
    execution = AUTH.execution_root(home)
    AUTH.prepare_execution(execution)
    AUTH.create_owned_root(home)
    monkeypatch.delenv("AI_REVIEW_INVOCATION")
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--cleanup"])
    assert AUTH.main() == 0
    assert home.is_dir() and execution.is_dir()
