# SPDX-License-Identifier: MIT
"""Offline credential-boundary tests; no provider request or real credential."""

from __future__ import annotations

import base64
import importlib.util
import inspect
import json
import os
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/actions/ai_review_auth.py"
spec = importlib.util.spec_from_file_location("review_auth_boundary", SCRIPT)
assert spec and spec.loader
AUTH = importlib.util.module_from_spec(spec)
spec.loader.exec_module(AUTH)
FIXTURE_TARGETS = {
    "x86_64": ("linux-x64", "x86_64-unknown-linux-musl"),
    "aarch64": ("linux-arm64", "aarch64-unknown-linux-musl"),
}


@pytest.fixture(autouse=True)
def fixture_invocation(monkeypatch: pytest.MonkeyPatch) -> None:
    """Each synthetic workflow carries an explicit invocation binding."""
    monkeypatch.setenv("AI_REVIEW_INVOCATION", "a" * 32)


@pytest.fixture(name="installed")
def fixture_installed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Install a dummy CLI which reports only sentinel checks, never values."""
    if sys.platform != "linux" or os.uname().machine not in FIXTURE_TARGETS:
        pytest.skip("Codex execution fixture requires Linux x86_64 or aarch64")
    target, triple = FIXTURE_TARGETS[os.uname().machine]
    venv = tmp_path / "venv/bin"
    venv.mkdir(parents=True)
    (venv / "lintro").touch()
    home = tmp_path / "home"
    home.mkdir()
    base = tmp_path / "external"
    base.mkdir()
    monkeypatch.setattr(AUTH, "EXECUTION_BASE", base, raising=False)
    monkeypatch.setattr(AUTH, "external_base", lambda: base)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("GITHUB_RUN_ID", "1242")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    monkeypatch.setenv("GITHUB_JOB", "review")
    monkeypatch.setenv("GITHUB_WORKSPACE", str(tmp_path / "workspace"))
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "output"))
    tools = AUTH.execution_root(AUTH.owned_home()) / "ai-tools"
    AUTH.prepare_execution(tools.parent)
    cli = tools / "codex/node_modules/.bin"
    cli.mkdir(parents=True)
    package = cli.parent / "@openai/codex"
    (package / "bin").mkdir(parents=True)
    pin_file = ROOT / "scripts/ci/ai-review-cli/codex/package.json"
    version = json.loads(pin_file.read_text())["dependencies"]["@openai/codex"]
    (package / "package.json").write_text(
        json.dumps(
            {
                "name": "@openai/codex",
                "version": version,
                "bin": {"codex": "bin/codex.js"},
            }
        )
    )
    platform = cli.parent / f"@openai/codex-{target}"
    native = platform / "vendor" / triple
    (native / "bin").mkdir(parents=True)
    (native / "codex-resources").mkdir()
    (native / "bin/codex").write_text("unit fixture, not a native isolation proof")
    (native / "codex-resources/bwrap").touch()
    (platform / "package.json").write_text(
        json.dumps({"name": "@openai/codex", "version": f"{version}-{target}"})
    )
    (native / "codex-package.json").write_text(
        json.dumps(
            {
                "version": version,
                "target": triple,
                "entrypoint": "bin/codex",
                "resourcesDir": "codex-resources",
            }
        )
    )
    binary = package / "bin/codex.js"
    (cli / "codex").symlink_to("../@openai/codex/bin/codex.js")
    binary.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        "assert 'GH_TOKEN' not in os.environ\n"
        "assert 'GITHUB_TOKEN' not in os.environ\n"
        "assert os.environ.get('CODEX_API_KEY') == 'dummy-provider-key'\n"
        "assert sys.argv[1:] == ['exec', '--skip-git-repo-check', '--json', '-']\n"
        "assert sys.stdin.read() == 'review fixture'\n"
        "print('provider-boundary-ok')\n"
    )
    binary.chmod(0o700)
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
    env = AUTH.child_environment(AUTH.owned_home(), row)
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


@pytest.mark.usefixtures("installed")
def test_child_forwards_actions_context_only(monkeypatch: pytest.MonkeyPatch) -> None:
    """Lintro's Actions gate needs these two keys; other GITHUB_* stay out."""
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    monkeypatch.setenv("GITHUB_ENV", "/tmp/should-not-leak")
    selected = ["openai", "cli", "api_key"]
    row = next(row for row in AUTH.matrix_rows() if row[:3] == selected)
    env = AUTH.child_environment(AUTH.owned_home(), row)
    assert env["GITHUB_ACTIONS"] == "true"
    assert env["GITHUB_EVENT_NAME"] == "pull_request"
    assert "GITHUB_ENV" not in env


@pytest.mark.usefixtures("installed")
def test_child_sees_review_state_with_actions_flag(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A populated state dir plus GITHUB_ACTIONS reaches the review child."""
    state = tmp_path / "ai-review-state"
    state.mkdir()
    (state / "state.json").write_text("{}")
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    selected = ["openai", "cli", "api_key"]
    row = next(row for row in AUTH.matrix_rows() if row[:3] == selected)
    env = AUTH.child_environment(AUTH.owned_home(), row)
    assert env["LINTRO_REVIEW_STATE_DIR"] == str(state.resolve())
    assert env["GITHUB_ACTIONS"] == "true"


@pytest.mark.parametrize(
    "arguments",
    [
        ["exec", "--sandbox", "read-only", "-"],
        ["--help"],
        ["--version"],
        ["exec", "--help"],
    ],
)
def test_codex_exec_pins_cwd_only(installed: Path, arguments: list[str]) -> None:
    """Lintro's private no-tree fallback must not become the native exec cwd."""
    row = next(
        (row for row in AUTH.matrix_rows() if row[:3] == ["openai", "cli", "api_key"]),
    )
    env = AUTH.child_environment(AUTH.owned_home(), row)
    binary = Path(env["PATH"].split(os.pathsep)[0]) / "codex"
    binary.write_text(
        f"#!{sys.executable}\nimport os\n"
        "assert 'GH_TOKEN' not in os.environ and 'GITHUB_TOKEN' not in os.environ\n"
        "assert os.environ['CODEX_API_KEY'] == 'dummy-provider-key'\n"
        "print(os.getcwd())\n"
    )
    private_tmp = Path(env["TMPDIR"])
    private_tmp.mkdir(parents=True)
    # Same allocation and empty Git topology as pinned Lintro empty_workspace().
    fallback = Path(tempfile.mkdtemp(prefix="lintro-review-no-tree-", dir=private_tmp))
    subprocess.run(["git", "-C", str(fallback), "init", "-q"], check=True)
    AUTH.stage_cli_boundary(installed, env, row)
    result = subprocess.run(
        [str(installed / "bin/codex"), *arguments],
        cwd=fallback,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    expected = fallback
    if arguments[-1] == "-":
        expected = AUTH.execution_root(AUTH.owned_home()) / "work"
    assert result.stdout.strip() == str(expected)
    assert env["TMPDIR"] == str(AUTH.owned_home() / "tmp")
    assert env["LINTRO_LOG_DIR"] == str(AUTH.owned_home() / "logs")


@pytest.mark.parametrize(
    "override",
    [
        ["--sandbox", "workspace-write"],
        ["--sandbox", "danger-full-access"],
        ["--sandbox", "read-only"],
        ["--sandbox=read-only"],
        ["--sandbox=danger-full-access"],
        ["-s", "workspace-write"],
        ["-sread-only"],
        ["-sdanger-full-access"],
        ["--full-auto"],
        ["--approve-for-me"],
        ["--not-so-yolo"],
        ["--dangerously-bypass-approvals-and-sandbox"],
        ["--dangerously-bypass-hook-trust"],
        ["--yolo"],
        ["--add-dir", "/"],
        ["--add-dir=/"],
        ["--profile", "other"],
        ["--profile=other"],
        ["-pother"],
        ["-p", "other"],
        ["-hpother"],
        ["--permission-profile", ":read-only"],
        ["-P:read-only"],
        ["--enable", "shell_tool"],
        ["--enable=shell_tool"],
        ["--disable", "a_security_feature"],
        ["--ignore-user-config"],
        ["--image", "/dummy/credential-file"],
        ["--cd", "/"],
        ["--oss"],
        ["--skip-git-repo-check"],
        ["--future-permission-selector", "unrestricted"],
        ["--config", "default_permissions=':read-only'"],
        ["--config=permissions.review.filesystem.\"/\"='read'"],
        ["-c", "features.shell_tool=true"],
        ["-cfeatures.view_image=true"],
        ["-c", '"features".shell_tool=true'],
        ["-c", "sandbox_mode='danger-full-access'"],
        ["-c", "approval_policy='never'"],
        ["-c", "profiles.other.features.shell_tool=true"],
        ["-c", "model_provider='other'"],
        ["-c", "unknown_future_security_setting=true"],
        ["-c"],
        ["--config"],
        ["--sandbox"],
        ["--", "--sandbox", "danger-full-access"],
    ],
)
def test_cli_refuses_permission_overrides(installed: Path, override: list[str]) -> None:
    """Reject alternate/duplicate selectors before the trusted binary executes."""
    row = next(
        (row for row in AUTH.matrix_rows() if row[:3] == ["openai", "cli", "api_key"]),
    )
    env = AUTH.child_environment(AUTH.owned_home(), row)
    binary = Path(env["PATH"].split(os.pathsep)[0]) / "codex"
    marker = installed / "provider-was-executed"
    binary.write_text(
        f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(marker)!r}).touch()\n"
    )
    AUTH.stage_cli_boundary(installed, env, row)
    result = subprocess.run(
        [str(installed / "bin/codex"), "exec", "--sandbox", "read-only", *override],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 1
    assert result.stderr == "Unsupported review CLI option\n"
    assert result.stdout == ""
    assert not marker.exists()


@pytest.mark.parametrize(
    "arguments",
    [
        ["--version"],
        ["--help"],
        ["exec", "--help"],
        ["exec", "--json", "--sandbox", "read-only", "-"],
        [
            "exec",
            "--sandbox",
            "read-only",
            "--model",
            "fixture-model",
            "--output-schema",
            "/dummy/schema.json",
            "-",
        ],
        ["exec", "-c", 'model="fixture-model"', "--sandbox", "read-only", "-"],
        [
            "exec",
            "--sandbox",
            "read-only",
            "--config",
            'model_reasoning_effort="medium"',
            "-",
        ],
        ["exec", "--sandbox", "read-only", '--config=model="fixture-model"', "-"],
        ["exec", "--sandbox", "read-only", '-cmodel_reasoning_effort="medium"', "-"],
    ],
)
def test_cli_preserves_review_arguments(installed: Path, arguments: list[str]) -> None:
    """Preserve probes, model/reasoning settings, JSON/schema and stdin exactly."""
    row = next(
        (row for row in AUTH.matrix_rows() if row[:3] == ["openai", "cli", "api_key"]),
    )
    env = AUTH.child_environment(AUTH.owned_home(), row)
    binary = Path(env["PATH"].split(os.pathsep)[0]) / "codex"
    binary.write_text(
        f"#!{sys.executable}\nimport os, sys, json\n"
        "assert 'GH_TOKEN' not in os.environ and 'GITHUB_TOKEN' not in os.environ\n"
        "assert os.environ['CODEX_API_KEY'] == 'dummy-provider-key'\n"
        "assert sys.stdin.read() == 'review fixture'\n"
        "print(json.dumps(sys.argv[1:]))\n"
    )
    AUTH.stage_cli_boundary(installed, env, row)
    result = subprocess.run(
        [str(installed / "bin/codex"), *arguments],
        env=env,
        input="review fixture",
        text=True,
        capture_output=True,
        check=False,
    )
    expected = arguments.copy()
    if "--sandbox" in expected:
        index = expected.index("--sandbox")
        del expected[index : index + 2]
        expected.insert(1, "--skip-git-repo-check")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == expected
    assert env["GH_TOKEN"] == "dummy-fetch-token"
    assert env["GITHUB_TOKEN"] == "dummy-posting-token"


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

    def inspect_staged(
        home: Path, env: dict[str, str], _redactions: list[str], cwd: Path | None = None
    ) -> int:
        cwd = cwd or home / "work"
        root = AUTH.execution_root(home)
        assert cwd == root / "work"
        assert (cwd / ".lintro-config.yaml").read_text() == "{}\n"
        assert not (home / "work").exists()
        assert env["TMPDIR"] == str(home / "tmp")
        assert env["LINTRO_LOG_DIR"] == str(home / "logs")
        assert Path(env["TMPDIR"]).is_dir()
        assert Path(env["LINTRO_LOG_DIR"]).is_dir()
        config = tomllib.loads((home / "codex/config.toml").read_text())
        assert config["project_root_markers"] == []
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
    assert not AUTH.owned_home().exists()


def test_prepare_execution_without_credentials(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Credential-free preparation exclusively creates and emits an external root."""
    home = tmp_path / "runner-home"
    home.mkdir()
    base = tmp_path / "external"
    base.mkdir()
    output = tmp_path / "output"
    monkeypatch.setattr(AUTH, "external_base", lambda: base, raising=False)
    monkeypatch.setattr(AUTH, "EXECUTION_BASE", base, raising=False)
    monkeypatch.setattr(
        os,
        "environ",
        {
            "HOME": str(home),
            "AI_REVIEW_INVOCATION": "a" * 32,
            "GITHUB_RUN_ID": "1242",
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_JOB": "review",
            "GITHUB_OUTPUT": str(output),
            "GITHUB_WORKSPACE": str(tmp_path / "checkout"),
        },
    )
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--prepare-execution"])
    assert AUTH.main() == 0
    root = AUTH.execution_root(AUTH.owned_home())
    assert root.stat().st_mode & 0o777 == 0o700
    assert (root / ".lgtm-ci-owned").read_text() == root.name
    assert (root / "work/.lintro-config.yaml").read_text() == "{}\n"
    assert output.read_text() == f"ai-tools-prefix={root}/ai-tools\n"
    with pytest.raises(FileExistsError):
        AUTH.main()
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--cleanup"])
    assert AUTH.main() == 0
    assert not root.exists()
    assert AUTH.main() == 0


@pytest.mark.parametrize(
    "damage",
    [
        "prefix-alias",
        "bin-escape",
        "native-escape",
        "resource-escape",
        "writable-package",
        "wrong-version",
        "missing-platform",
        "package-link",
        "root-mode",
        "marker-mismatch",
        "work-link",
        "special-file",
    ],
)
def test_codex_install_refuses_untrusted_layout(
    installed: Path, monkeypatch: pytest.MonkeyPatch, damage: str
) -> None:
    """Internal npm launcher links work; alternate roots and package escapes do not."""
    prefix = Path(os.environ["AI_TOOLS_PREFIX"])
    root = prefix.parent
    modules = prefix / "codex/node_modules"
    package = modules / "@openai/codex"
    target, triple = FIXTURE_TARGETS[os.uname().machine]
    platform = modules / f"@openai/codex-{target}"
    native = platform / "vendor" / triple
    outside = installed / "outside"
    outside.write_text("not trusted")
    if damage == "prefix-alias":
        alias = installed.parent / "alias"
        alias.symlink_to(prefix, target_is_directory=True)
        monkeypatch.setenv("AI_TOOLS_PREFIX", str(alias))
    elif damage == "bin-escape":
        (modules / ".bin/codex").unlink()
        (modules / ".bin/codex").symlink_to(outside)
    elif damage == "native-escape":
        (native / "bin/codex").unlink()
        (native / "bin/codex").symlink_to(outside)
    elif damage == "resource-escape":
        (native / "codex-resources/bwrap").unlink()
        (native / "codex-resources/bwrap").symlink_to(outside)
    elif damage == "writable-package":
        package.chmod(0o777)
    elif damage == "wrong-version":
        (package / "package.json").write_text('{"version":"0.0.0"}')
    elif damage == "missing-platform":
        (platform / "package.json").unlink()
    elif damage == "package-link":
        package.rename(modules / "@openai/moved")
        package.symlink_to("moved", target_is_directory=True)
    elif damage == "root-mode":
        root.chmod(0o755)
    elif damage == "marker-mismatch":
        (root / ".lgtm-ci-owned").write_text("foreign-job")
    elif damage == "work-link":
        (root / "work/.lintro-config.yaml").unlink()
        (root / "work").rmdir()
        (root / "work").symlink_to(installed, target_is_directory=True)
    elif damage == "special-file":
        (native / "codex-resources/bwrap").unlink()
        os.mkfifo(native / "codex-resources/bwrap")
    row = next(
        (row for row in AUTH.matrix_rows() if row[:3] == ["openai", "cli", "api_key"]),
    )
    with pytest.raises((ValueError, OSError)):
        AUTH.child_environment(AUTH.owned_home(), row)


@pytest.mark.parametrize(
    "kind",
    [
        "symlink",
        "marker-link",
        "marker-mismatch",
        "mode",
        "unmarked",
        "foreign-owner",
    ],
)
def test_cleanup_refuses_foreign_roots(
    installed: Path, monkeypatch: pytest.MonkeyPatch, kind: str
) -> None:
    """Cleanup cannot follow a root/marker link or remove someone else's material."""
    root = Path(os.environ["AI_TOOLS_PREFIX"]).parent
    marker = root / ".lgtm-ci-owned"
    if kind == "symlink":
        moved = root.with_name("preserved")
        root.rename(moved)
        root.symlink_to(moved, target_is_directory=True)
    elif kind == "marker-link":
        marker.unlink()
        outside = installed / "marker"
        outside.write_text(root.name)
        marker.symlink_to(outside)
    elif kind == "marker-mismatch":
        marker.write_text("other-job")
    elif kind == "mode":
        root.chmod(0o777)
    elif kind == "unmarked":
        marker.unlink()
    else:
        owner = os.getuid()
        monkeypatch.setattr(AUTH.os, "getuid", lambda: owner + 1)
    with pytest.raises((ValueError, OSError)):
        AUTH.cleanup(root)
    assert root.exists()


def test_prepare_rolls_back_output_failure(
    installed: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failed output emission cannot strand a partially prepared owned root."""
    root = Path(os.environ["AI_TOOLS_PREFIX"]).parent
    AUTH.cleanup(root)
    monkeypatch.setenv("GITHUB_OUTPUT", str(installed))
    with pytest.raises(IsADirectoryError):
        AUTH.prepare_execution(root)
    assert not root.exists()


def test_marker_failure_defers_execution_cleanup(
    installed: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A staging failure before credential writes rolls back H and prepared E."""
    execution = Path(os.environ["AI_TOOLS_PREFIX"]).parent
    monkeypatch.setenv("LINTRO_AI_PROVIDER", "openai")
    monkeypatch.setenv("LINTRO_AI_TRANSPORT", "cli")
    monkeypatch.setenv("AI_REVIEW_AUTH", "api_key")
    monkeypatch.setenv("LINTRO_CLI_BARE", "")
    monkeypatch.setattr(sys, "argv", [str(SCRIPT)])
    real_open = os.open

    def refuse_marker(
        path: str | Path, flags: int, mode: int = 0o777, *, dir_fd: int | None = None
    ) -> int:
        if path == AUTH.owned_home() / ".lgtm-ci-owned":
            raise OSError("injected marker staging failure")
        return real_open(path, flags, mode, dir_fd=dir_fd)

    monkeypatch.setattr(AUTH.os, "open", refuse_marker)
    with pytest.raises(OSError, match="marker staging failure"):
        AUTH.main()
    assert not AUTH.owned_home().exists()
    # Failed HOME creation did not acquire the prepared execution root. The
    # independent always-cleanup step owns rollback of that installation.
    assert execution.exists()
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--cleanup"])
    assert AUTH.main() == 0
    assert not execution.exists()
    assert installed.is_dir()


@pytest.mark.parametrize("location", ["home", "checkout", "ancestor-link", "missing"])
def test_external_execution_location_fails_closed(
    installed: Path, monkeypatch: pytest.MonkeyPatch, location: str
) -> None:
    """Never fall back under denied HOME, a checkout, or a noncanonical base."""
    if location == "home":
        base = installed
    elif location == "checkout":
        base = Path(os.environ["GITHUB_WORKSPACE"])
        base.mkdir()
    elif location == "ancestor-link":
        base = installed.parent / "external-alias"
        base.symlink_to(installed.parent / "external", target_is_directory=True)
    else:
        base = installed.parent / "missing"
    monkeypatch.setattr(AUTH, "external_base", lambda: base)
    with pytest.raises((ValueError, OSError)):
        AUTH.execution_root(AUTH.owned_home())


@pytest.mark.parametrize("platform", ["linux", "darwin"])
@pytest.mark.parametrize(
    "existing",
    ["absent", "directory", "dangling-link", "inaccessible"],
)
def test_cleanup_checks_external_base_only_for_existing_candidate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, platform: str, existing: str
) -> None:
    """Unused Codex roots need no Linux base; existing unsafe roots still fail."""
    home = tmp_path / "home"
    home.mkdir()
    base = tmp_path / "hardened-external"
    base.mkdir(mode=0o700)
    monkeypatch.setattr(AUTH, "EXECUTION_BASE", base, raising=False)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("GITHUB_RUN_ID", "1242")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    monkeypatch.setenv("GITHUB_JOB", "noncodex")
    monkeypatch.delenv("GITHUB_WORKSPACE", raising=False)
    monkeypatch.setattr(sys, "platform", platform)
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "--cleanup"])
    owned = AUTH.owned_home()
    AUTH.create_owned_root(owned)
    candidate = AUTH.execution_candidate(owned, base)
    if existing == "directory":
        candidate.mkdir(mode=0o700)
    elif existing == "dangling-link":
        candidate.symlink_to(base / "missing")
    if existing == "absent":
        assert AUTH.main() == 0
    elif existing == "inaccessible":
        real_lstat = Path.lstat

        def refuse_candidate(path: Path) -> os.stat_result:
            if path == candidate:
                raise PermissionError("injected inaccessible execution candidate")
            return real_lstat(path)

        monkeypatch.setattr(Path, "lstat", refuse_candidate)
        with pytest.raises(PermissionError, match="inaccessible execution candidate"):
            AUTH.main()
    else:
        with pytest.raises(ValueError, match="Unsafe external review execution base"):
            AUTH.main()
        assert candidate.exists() or candidate.is_symlink()
    assert not owned.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="Linux Codex layout fixture")
@pytest.mark.parametrize("machine", ["x86_64", "aarch64"])
def test_fixture_matches_supported_linux_architecture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, machine: str
) -> None:
    """Both platform layouts validate; the dummy launcher uses this interpreter."""
    host = os.uname()
    monkeypatch.setattr(os, "uname", lambda: type(host)([*host[:4], machine]))
    runner_home = inspect.unwrap(fixture_installed)(tmp_path, monkeypatch)
    test_provider_cli_does_not_inherit_github_credentials(runner_home)


def test_marker_fdopen_failure_closes_descriptor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A marker wrapper failure rolls back the new root and closes its raw fd."""
    root = tmp_path / "owned"
    descriptors: list[int] = []

    def refuse_fdopen(descriptor: int, *_args: object, **_kwargs: object) -> None:
        descriptors.append(descriptor)
        raise OSError("injected fdopen failure")

    monkeypatch.setattr(AUTH.os, "fdopen", refuse_fdopen)
    with pytest.raises(OSError, match="injected fdopen failure"):
        AUTH.create_owned_root(root)
    assert not root.exists()
    assert len(descriptors) == 1
    with pytest.raises(OSError, match="Bad file descriptor"):
        os.fstat(descriptors[0])
