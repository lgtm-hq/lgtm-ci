# SPDX-License-Identifier: MIT
"""Offline credential-boundary tests; no provider request or real credential."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/actions/ai_review_auth.py"
spec = importlib.util.spec_from_file_location("review_auth_boundary", SCRIPT)
assert spec and spec.loader
AUTH = importlib.util.module_from_spec(spec)
spec.loader.exec_module(AUTH)


@pytest.fixture
def installed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Install a dummy CLI which reports only sentinel checks, never values."""
    venv = tmp_path / "venv/bin"
    venv.mkdir(parents=True)
    (venv / "lintro").touch()
    tools = tmp_path / "tools with ' quote"
    cli = tools / "codex/node_modules/.bin"
    cli.mkdir(parents=True)
    binary = cli / "codex"
    binary.write_text(
        "#!/usr/bin/python3\n"
        "import os, sys\n"
        "assert 'GH_TOKEN' not in os.environ\n"
        "assert 'GITHUB_TOKEN' not in os.environ\n"
        "assert os.environ.get('CODEX_API_KEY') == 'dummy-provider-key'\n"
        "assert sys.argv[1:] == ['exec', '--json', '-']\n"
        "assert sys.stdin.read() == 'review fixture'\n"
        "print('provider-boundary-ok')\n"
    )
    binary.chmod(0o700)
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("VENV_DIR", str(venv.parent))
    monkeypatch.setenv("AI_TOOLS_PREFIX", str(tools))
    monkeypatch.setenv("REVIEW_NODE_BIN", sys.executable)
    monkeypatch.setenv("GITHUB_WORKSPACE", str(tmp_path / "workspace"))
    monkeypatch.setenv("GH_TOKEN", "dummy-fetch-token")
    monkeypatch.setenv("GITHUB_TOKEN", "dummy-posting-token")
    monkeypatch.setenv("CODEX_API_KEY", "dummy-provider-key")
    monkeypatch.chdir(tmp_path)
    return home


def test_provider_cli_does_not_inherit_github_credentials(installed: Path) -> None:
    """Lintro retains fetch/post credentials; its CLI child does not."""
    selected = ["openai", "cli", "api_key"]
    row = next(row for row in AUTH.matrix_rows() if row[:3] == selected)
    env = AUTH.child_environment(installed, row)
    assert env["GH_TOKEN"] == "dummy-fetch-token"
    assert env["GITHUB_TOKEN"] == "dummy-posting-token"
    # Exercise the actual PATH lookup used by Lintro, not the staging helper alone.
    AUTH.stage_cli_boundary(installed, env, row)
    result = subprocess.run(
        ["/bin/bash", "-c", "exec codex exec --json --sandbox read-only -"],
        env=env,
        input="review fixture",
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "provider-boundary-ok\n"
    assert os.environ["GITHUB_TOKEN"] == "dummy-posting-token"


@pytest.mark.parametrize("sandbox", ["workspace-write", "danger-full-access"])
def test_cli_refuses_a_relaxed_legacy_sandbox(installed: Path, sandbox: str) -> None:
    """Do not translate a future provider request for broader permissions."""
    selected = ["openai", "cli", "api_key"]
    row = next(row for row in AUTH.matrix_rows() if row[:3] == selected)
    env = AUTH.child_environment(installed, row)
    AUTH.stage_cli_boundary(installed, env, row)
    result = subprocess.run(
        [str(installed / "bin/codex"), "exec", "--sandbox", sandbox],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 1
    assert result.stderr == "Unsupported review sandbox option\n"
    assert result.stdout == ""


@pytest.mark.parametrize("auth_method", ["oauth", "api_key"])
def test_codex_auth_is_not_exposed_to_model_tools(
    installed: Path, monkeypatch: pytest.MonkeyPatch, auth_method: str
) -> None:
    """Both Codex auth modes still stage credentials, but not local-read tools."""
    monkeypatch.setenv("HOME", str(installed))
    monkeypatch.setenv("GITHUB_RUN_ID", "1242")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    monkeypatch.setenv("GITHUB_JOB", "review")
    monkeypatch.setenv("LINTRO_AI_PROVIDER", "openai")
    monkeypatch.setenv("LINTRO_AI_TRANSPORT", "cli")
    monkeypatch.setenv("AI_REVIEW_AUTH", auth_method)
    monkeypatch.setenv("LINTRO_CLI_BARE", "")
    monkeypatch.setattr(sys, "argv", [str(SCRIPT)])
    raw = b""
    if auth_method == "oauth":
        monkeypatch.delenv("CODEX_API_KEY")
        names = ("id_token", "access_token", "refresh_token", "account_id")
        raw = json.dumps({"tokens": dict.fromkeys(names, "dummy-session")}).encode()
        monkeypatch.setenv("CODEX_AUTH_JSON", base64.b64encode(raw).decode())

    def inspect_staged(home: Path, env: dict[str, str], _redactions: list[str]) -> int:
        config = tomllib.loads((home / "codex/config.toml").read_text())
        expected_login = "chatgpt" if auth_method == "oauth" else "api"
        assert config["forced_login_method"] == expected_login
        if auth_method == "oauth":
            assert (home / "codex/auth.json").read_bytes() == raw
        else:
            assert env["CODEX_API_KEY"] == "dummy-provider-key"
        # Shell includes both exec_command and one-shot shell fallbacks.
        # view_image is also a filesystem reader; disabling shell alone is insufficient.
        for feature in (
            "shell_tool",
            "view_image",
            "js_repl",
            "multi_agent",
            "multi_agent_v2",
            "code_mode",
            "apps",
            "plugins",
        ):
            assert config["features"][feature] is False
        assert config["agents"]["enabled"] is False
        assert config["web_search"] == "disabled"
        # apply_patch is model-catalog-controlled, not disabled by shell_tool.
        # Its preflight reads must also be denied access to credentials/procfs.
        policy = config["permissions"][config["default_permissions"]]
        assert policy["filesystem"][str(installed)] == "none"
        assert policy["filesystem"]["/proc"] == "none"
        assert policy["filesystem"]["/dev"] == "none"
        assert policy["network"]["enabled"] is False
        assert Path(env["PATH"].split(":")[0], "codex").is_file()
        return 0

    monkeypatch.setattr(AUTH, "invoke", inspect_staged)
    assert AUTH.main() == 0
    assert not (installed / ".lgtm-ci-review-1242-1-review").exists()
