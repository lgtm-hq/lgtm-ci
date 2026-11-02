#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bind one review credential in an isolated home, config and child environment.

No repository config, dotenv, CLI settings, cached login, helper or test override
is loaded in credential scope. Codex preparation/install runs credential-free in
an owned execution root outside denied HOME; auth, logs and temp stay private.
An always() workflow step independently cleans either root after install failure.
"""

from __future__ import annotations

import base64
import binascii
import contextlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent / "lib"))
# Standalone script library is added to the search path above.
# pylint: disable-next=wrong-import-position
from ai_review_capabilities import matrix_rows  # noqa: E402

MAX_SESSION_BYTES = 65536
# Non-matrix credential forms must also be refused, never propagated.
COMPETING = {
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_REVIEW_API_KEY",
    "OPENAI_REVIEW_API_KEY",
}
# Deliberate allowlist: no PYTHONPATH, BASH_ENV, dotenv/config/endpoint/helper
# overrides, PR PATH additions, proxy settings or ambient CLI credentials.
CHILD_ENV = {
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GITHUB_REPOSITORY",
    "PR_NUMBER",
    "BLOCKING",
    "JOB_TIMEOUT_MINUTES",
    "JOB_STARTED_AT",
    "MAX_DIFF_LINES",
    "GITHUB_OUTPUT",
    "GITHUB_STEP_SUMMARY",
    "RUNNER_TEMP",
    "GITHUB_RUN_ID",
    "GITHUB_RUN_ATTEMPT",
    "GITHUB_JOB",
    "LINTRO_AI_MODEL",
    "LINTRO_AI_MAX_COST_USD",
}


def session_payload(encoded: str) -> tuple[bytes, list[str]]:
    """Validate a bounded base64 OAuth snapshot without disclosing its contents."""
    if len(encoded) > MAX_SESSION_BYTES:
        raise ValueError("CODEX_AUTH_JSON exceeds the 64 KiB secret limit")
    try:
        raw = base64.b64decode(encoded, validate=True)
        value = json.loads(raw.decode("utf-8"))
    except (ValueError, binascii.Error, RecursionError) as exc:
        raise ValueError(
            "CODEX_AUTH_JSON must be base64 of a complete OAuth auth.json",
        ) from exc
    if not isinstance(value, dict) or value.get("OPENAI_API_KEY"):
        raise ValueError(
            "CODEX_AUTH_JSON must contain an OAuth session, not an API-key login",
        )
    tokens = value.get("tokens")
    if value.get("auth_mode") not in (None, "chatgpt") or not isinstance(tokens, dict):
        raise ValueError("CODEX_AUTH_JSON is not a ChatGPT OAuth session")
    required = ("id_token", "access_token", "refresh_token", "account_id")
    values = [tokens.get(key) for key in required]
    if not all(isinstance(value, str) and value.strip() for value in values):
        raise ValueError(
            "CODEX_AUTH_JSON is missing OAuth session tokens; renew with codex login",
        )
    return raw, [encoded, *[tokens[key] for key in required]]


def owned_home() -> Path:
    """Return a job/attempt-specific home outside the runner's ambient CLI homes."""
    keys = ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB")
    ident = "-".join(os.environ.get(key, "") for key in keys)
    if not re.fullmatch(r"[0-9]+-[0-9]+-[A-Za-z0-9_-]+", ident):
        raise ValueError(
            "Run ID, attempt and job are required for review-home isolation",
        )
    base = Path.home()
    safe_location = base.is_absolute() and base == base.resolve()
    if not safe_location or base.stat().st_uid != os.getuid():
        raise ValueError(
            "Review HOME must be an absolute, owned, non-symlink directory",
        )
    return base / f".lgtm-ci-review-{ident}"


def external_base() -> Path:
    """Use only the canonical root-owned sticky system execution base on Linux."""
    base = Path("/var/tmp")
    info = base.lstat()
    if (
        sys.platform != "linux"
        or base != base.resolve(strict=True)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) != 0o1777
    ):
        raise ValueError("Unsafe external review execution base")
    return base


def execution_root(home: Path, *, check_workspace: bool = True) -> Path:
    """Derive a separate job-owned root; never accept an environment override."""
    base = external_base()
    identity = home.name.removeprefix(".lgtm-ci-review-")
    root = base / f".lgtm-ci-review-exec-{os.getuid()}-{identity}"
    denied = [Path.home()]
    if check_workspace:
        denied.append(Path(os.environ["GITHUB_WORKSPACE"]).resolve())
    if base != base.resolve(strict=True) or any(
        root == path or path in root.parents or root in path.parents for path in denied
    ):
        raise ValueError("Execution root overlaps HOME or the reviewed checkout")
    return root


def validate_root(root: Path) -> None:
    """Require a private owned directory and its exact regular ownership marker."""
    info = root.lstat()
    marker = root / ".lgtm-ci-owned"
    mark = marker.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise ValueError("Refusing unowned review root")
    if (
        not stat.S_ISREG(mark.st_mode)
        or mark.st_uid != os.getuid()
        or stat.S_IMODE(mark.st_mode) != 0o600
        or marker.read_text() != root.name
    ):
        raise ValueError("Refusing unowned review root")


def create_owned_root(root: Path) -> None:
    """Create a new private root, rolling back partial marker failures only here."""
    root.mkdir(mode=0o700)
    try:
        descriptor = os.open(
            root / ".lgtm-ci-owned",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as marker:
            marker.write(root.name)
    except BaseException:
        shutil.rmtree(root)
        raise


def prepare_execution(root: Path) -> None:
    """Exclusively prepare credential-free installation and empty execution cwd."""
    os.umask(0o077)
    create_owned_root(root)
    try:
        (root / "work").mkdir(mode=0o700)
        (root / "work/.lintro-config.yaml").write_text("{}\n")
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(f"ai-tools-prefix={root}/ai-tools\n")
    except BaseException:
        # Only this invocation's exclusive mkdir succeeded; never roll back a
        # colliding pre-existing root, including an apparently valid marked one.
        shutil.rmtree(root)
        raise


def cleanup(root: Path) -> None:
    """Remove only this job's marked private root, never a symlink/foreign path."""
    if not root.exists() and not root.is_symlink():
        return
    validate_root(root)
    shutil.rmtree(root)


def selected_row() -> list[str]:
    """Refuse missing/unsupported selections and competing effective credentials."""
    rows: list[list[str]] = matrix_rows()
    selected = [
        os.environ.get(key, "")
        for key in ("LINTRO_AI_PROVIDER", "LINTRO_AI_TRANSPORT", "AI_REVIEW_AUTH")
    ]
    row = next((item for item in rows if item[:3] == selected), None)
    if row is None:
        raise ValueError(
            "Unsupported review tuple; supported choices: "
            + ", ".join("/".join(item[:3]) for item in rows)
        )
    if row[2] == "oauth" and "CODEX_API_KEY" in os.environ:
        raise ValueError(
            "CODEX_API_KEY must be absent when auth=oauth (including empty values)",
        )
    for name in {item[4] for item in rows} | COMPETING:
        if name != row[4] and os.environ.get(name, ""):
            raise ValueError(f"Competing credential {name} reached the review step")
    if not os.environ.get(row[4], "").strip():
        raise ValueError(
            f"Missing review credential {row[4]}; "
            "explicitly forward the selected secret "
            "(no smoke-key or login fallback)"
        )
    if os.environ.get("LINTRO_CLI_BARE", "") != row[6]:
        raise ValueError("LINTRO_CLI_BARE conflicts with selected review auth")
    return row


def validate_execution_tree(root: Path) -> None:
    """Check only job-owned install/work components, never follow escaped links."""
    prefix = root / "ai-tools"
    modules = prefix / "codex/node_modules"
    package = modules / "@openai/codex"
    launcher = modules / ".bin/codex"
    expected_link = "../@openai/codex/bin/codex.js"
    if not launcher.is_symlink() or os.readlink(launcher) != expected_link:
        raise ValueError("Codex requires the installed npm launcher link")
    # Only the known npm .bin link is allowed. Verify directories before
    # descending so an escaped package/resource link is never traversed/read.
    pending = [prefix, root / "work"]
    while pending:
        path = pending.pop()
        info = path.lstat()
        writable = not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o022
        if info.st_uid != os.getuid() or writable:
            raise ValueError("Untrusted writable Codex install component")
        if path == launcher and stat.S_ISLNK(info.st_mode):
            if path.resolve(strict=True) != package / "bin/codex.js":
                raise ValueError("Escaped Codex launcher")
        elif stat.S_ISDIR(info.st_mode):
            pending.extend(path.iterdir())
        elif not stat.S_ISREG(info.st_mode):
            raise ValueError("Unsafe Codex install component")


def codex_prefix(home: Path) -> Path:
    """Validate the prepared npm topology without replacing its published launcher."""
    root = execution_root(home)
    validate_root(root)
    prefix = root / "ai-tools"
    # Check the literal path first: resolving an alias is not proof of ownership.
    if os.environ["AI_TOOLS_PREFIX"] != str(prefix):
        raise ValueError("Codex requires the prepared execution prefix")
    validate_execution_tree(root)
    modules = prefix / "codex/node_modules"
    package = modules / "@openai/codex"
    pin_file = SCRIPT_DIR.parent / "ai-review-cli/codex/package.json"
    pin = json.loads(pin_file.read_text())["dependencies"]["@openai/codex"]
    manifest = json.loads((package / "package.json").read_text())
    if (
        manifest.get("name") != "@openai/codex"
        or manifest.get("version") != pin
        or manifest.get("bin") != {"codex": "bin/codex.js"}
    ):
        raise ValueError("Codex launcher does not match the pinned package")
    targets = {
        "x86_64": ("linux-x64", "x86_64-unknown-linux-musl"),
        "aarch64": ("linux-arm64", "aarch64-unknown-linux-musl"),
    }
    if sys.platform != "linux" or os.uname().machine not in targets:
        raise ValueError("Unsupported Codex execution platform")
    platform, triple = targets[os.uname().machine]
    platform_package = modules / f"@openai/codex-{platform}"
    optional = json.loads((platform_package / "package.json").read_text())
    native = platform_package / "vendor" / triple
    metadata = json.loads((native / "codex-package.json").read_text())
    if optional.get("name") != "@openai/codex":
        raise ValueError("Codex platform package is missing or incompatible")
    if optional.get("version") != f"{pin}-{platform}":
        raise ValueError("Codex platform package is missing or incompatible")
    if (
        metadata.get("version") != pin
        or metadata.get("target") != triple
        or metadata.get("entrypoint") != "bin/codex"
        or metadata.get("resourcesDir") != "codex-resources"
    ):
        raise ValueError("Codex native layout is missing or incompatible")
    if (
        not (native / "bin/codex").is_file()
        or not (native / "codex-resources/bwrap").is_file()
        or (root / "work/.lintro-config.yaml").read_text() != "{}\n"
    ):
        raise ValueError("Codex platform package is missing or incompatible")
    return prefix


def child_environment(home: Path, row: list[str]) -> dict[str, str]:
    """Construct a minimal environment pointing only at trusted installed binaries."""
    env: dict[str, str] = {}
    for key in CHILD_ENV:
        value = os.environ.get(key)
        if value is not None:
            env[key] = value
    venv = Path(os.environ["VENV_DIR"]).resolve(strict=True)
    lintro = venv / "bin/lintro"
    if not lintro.is_file():
        raise ValueError(
            "Install pinned lintro without credentials before the review step",
        )
    paths = ["/usr/local/bin", "/usr/bin", "/bin"]
    if row[5]:
        prefix = (
            codex_prefix(home)
            if row[5] == "codex"
            else Path(os.environ["AI_TOOLS_PREFIX"]).resolve(strict=True)
        )
        suffix = "bin" if row[5] == "agent" else f"{row[5]}/node_modules/.bin"
        cli_dir = prefix / suffix
        if not (cli_dir / row[5]).is_file():
            raise ValueError("Selected CLI is missing from the trusted install prefix")
        paths.insert(0, str(cli_dir))
        if row[5] != "agent":
            # setup-node installs outside the checkout. Never resolve a PR's node.
            node = Path(os.environ["REVIEW_NODE_BIN"]).resolve(strict=True)
            if Path(os.environ["GITHUB_WORKSPACE"]).resolve() in node.parents:
                raise ValueError("node must not come from the reviewed checkout")
            paths.insert(1, str(node.parent))
    env.update(
        {
            "CI": "true",
            "PATH": ":".join(paths),
            "HOME": str(home),
            "CODEX_HOME": str(home / "codex"),
            "XDG_CONFIG_HOME": str(home / "config"),
            "XDG_CACHE_HOME": str(home / "cache"),
            "TMPDIR": str(home / "tmp"),
            "LINTRO_LOG_DIR": str(home / "logs"),
            "LINTRO_BIN": str(lintro),
            "LINTRO_AI_PROVIDER": row[0],
            "LINTRO_AI_TRANSPORT": row[1],
            "LINTRO_AI_ENABLED": "1",
            "LINTRO_AI_REVIEW": "1",
            "LINTRO_CLI_BARE": row[6],
            "LINTRO_REVIEW_STATE_DIR": str(Path("ai-review-state").resolve()),
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_AUTOUPDATER": "1",
        }
    )
    state = Path("ai-review-state")
    if state.is_symlink():
        raise ValueError("Review state must not be a symlink")
    if row[4] != "CODEX_AUTH_JSON":
        env[row[4]] = os.environ[row[4]]
    return env


def stage_cli_boundary(home: Path, env: dict[str, str], row: list[str]) -> None:
    """Keep fetch/post tokens in Lintro, not in its provider CLI subprocess.

    Resolve before adding the private shim directory so the shim cannot recurse.
    The absolute target is from the credential-free, trusted install prefix.
    stdin, exit status and the selected provider credential are unchanged.
    Only Codex's legacy sandbox selector is replaced by the named deny-read policy.
    This is an environment boundary, not an OS isolation boundary.
    """
    if not row[5]:
        return
    binary = Path(env["PATH"].split(os.pathsep)[0]) / row[5]
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("Selected CLI is not executable in the trusted install prefix")
    directory = home / "bin"
    directory.mkdir(mode=0o700)
    shim = directory / row[5]
    # Codex's legacy --sandbox overrides named permissions. Accept only the
    # pinned Lintro exec/probe contract and one exact read-only pair to translate.
    # Unknown flags/config keys fail closed (including aliases, duplicates and
    # feature/profile switches); model/reasoning overrides cannot select policy.
    shim.write_text(
        f"#!{sys.executable} -I\n"
        "import os, sys\n"
        "env = dict(os.environ)\n"
        "env.pop('GH_TOKEN', None)\nenv.pop('GITHUB_TOKEN', None)\n"
        "args = sys.argv[1:]\n"
        + (
            "if args not in (['--version'], ['--help'], ['exec', '--help']):\n"
            "    error = 'Unsupported review CLI option'\n"
            "    if not args or args[0] != 'exec':\n"
            "        sys.exit(error)\n"
            "    kept = ['exec']\n"
            "    sandbox_seen = False\n"
            "    index = 1\n"
            "    while index < len(args):\n"
            "        arg = args[index]\n"
            "        index += 1\n"
            "        if arg == '--sandbox':\n"
            "            if sandbox_seen or args[index:index + 1] != ['read-only']:\n"
            "                sys.exit(error)\n"
            "            sandbox_seen = True\n"
            "            index += 1\n"
            "        elif arg in ('--model', '--output-schema', '-c', '--config'):\n"
            "            if index == len(args) or args[index].startswith('-'):\n"
            "                sys.exit(error)\n"
            "            value = args[index]\n"
            "            index += 1\n"
            "            if arg in ('--model', '--output-schema'):\n"
            "                kept.extend([arg, value])\n"
            "                continue\n"
            "            key, separator, _ = value.partition('=')\n"
            "            if not separator or key.strip() not in "
            "('model', 'model_reasoning_effort'):\n"
            "                sys.exit(error)\n"
            "            kept.extend([arg, value])\n"
            "        elif arg.startswith('--config=') or arg.startswith('-c'):\n"
            "            value = arg[len('--config='):] "
            "if arg.startswith('--config=') else arg[2:]\n"
            "            key, separator, _ = value.partition('=')\n"
            "            if not separator or key.strip() not in "
            "('model', 'model_reasoning_effort'):\n"
            "                sys.exit(error)\n"
            "            kept.append(arg)\n"
            "        elif arg == '--json' or (arg == '-' and index == len(args)):\n"
            "            kept.append(arg)\n"
            "        else:\n"
            "            sys.exit(error)\n"
            "    if not sandbox_seen:\n"
            "        sys.exit(error)\n"
            "    args = kept\n"
            if row[5] == "codex"
            else ""
        )
        + f"os.execve({str(binary)!r}, [{str(binary)!r}, *args], env)\n"
    )
    shim.chmod(0o700)
    env["PATH"] = f'{directory}:{env["PATH"]}'


def invoke(home: Path, env: dict[str, str], redactions: list[str], cwd: Path) -> int:
    """Run the bounded review and reap its process group before session cleanup."""
    # Darwin reports EPERM for an empty orphan process group after timeout;
    # Linux reports ESRCH. Children share our uid and cannot change credentials.
    group_absent_errors: tuple[type[OSError], ...] = (ProcessLookupError,)
    if sys.platform == "darwin":
        group_absent_errors += (PermissionError,)
    # Buffer inside the owned home, then redact before any log emission. This
    # also avoids a detached CLI holding a pipe open after its parent exits.
    with (
        (home / "review.log").open("w+", encoding="utf-8", errors="replace") as log,
        subprocess.Popen(
            ["/bin/bash", str(SCRIPT_DIR / "run-ai-review.sh")],
            cwd=cwd,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        ) as process,
    ):

        def cancel(signum: int, _frame: object) -> None:
            """Reap the cancelled child before removing credentials."""
            raise SystemExit(128 + signum)

        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, cancel)
        try:
            return process.wait()
        finally:
            # timeout --foreground keeps descendants in this group. Reap any
            # remaining provider before deleting its credential or log files.
            with contextlib.suppress(*group_absent_errors):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            with contextlib.suppress(*group_absent_errors):
                os.killpg(process.pid, signal.SIGKILL)
            log.seek(0)
            for line in log:
                for secret in redactions:
                    line = line.replace(secret, "[REDACTED]")
                print(line, end="", flush=True)


def main() -> int:
    """Validate, stage and invoke; always remove only the home created here."""
    home = owned_home()
    if sys.argv[1:] == ["--cleanup"]:
        try:
            cleanup(execution_root(home, check_workspace=False))
        finally:
            cleanup(home)
        return 0
    if sys.argv[1:] == ["--prepare-execution"]:
        os.umask(0o077)
        prepare_execution(execution_root(home))
        return 0
    if sys.argv[1:]:
        raise ValueError("Unsupported review auth option")
    row = selected_row()
    execution = execution_root(home) if row[5] == "codex" else None
    try:
        return run_review(home, row, execution)
    finally:
        if execution is not None:
            cleanup(execution)


def run_review(home: Path, row: list[str], execution: Path | None) -> int:
    """Stage private state while keeping Codex's native target/cwd outside HOME."""
    env = child_environment(home, row)
    raw = b""
    redactions = [os.environ[row[4]]]
    if row[4] == "CODEX_AUTH_JSON":
        raw, redactions = session_payload(os.environ[row[4]])
    os.umask(0o077)
    # Exclusive mkdir refuses pre-existing homes and symlinks; never overwrite.
    create_owned_root(home)
    try:
        cwd = (execution if execution is not None else home) / "work"
        if execution is None:
            cwd.mkdir(mode=0o700)
            # Non-Codex routes retain their existing private empty cwd.
            (cwd / ".lintro-config.yaml").write_text("{}\n")
        else:
            validate_root(execution)
            if cwd.is_symlink() or (cwd / ".lintro-config.yaml").read_text() != "{}\n":
                raise ValueError("Invalid prepared review cwd")
        for directory in ("tmp", "logs"):
            (home / directory).mkdir(mode=0o700)
        (home / "codex").mkdir(mode=0o700)
        (home / "codex/config.toml").write_text(
            'cli_auth_credentials_store = "file"\n'
            + f'forced_login_method = "{"chatgpt" if row[2] == "oauth" else "api"}"\n'
            # Lintro supplies the diff/context on stdin. No model-controlled local
            # execution or file readers are needed to produce its JSON review.
            # read-only sandboxing alone still permits reading auth.json/procfs.
            + 'web_search = "disabled"\n'
            + "project_root_markers = []\n"
            + 'default_permissions = "review"\n'
            + "[permissions.review.filesystem]\n"
            + '":root" = "read"\n'
            + f'{json.dumps(str(Path.home()))} = "none"\n'
            + '"/proc" = "none"\n"/dev" = "none"\n'
            + "[permissions.review.network]\nenabled = false\n"
            + "[agents]\nenabled = false\n"
            + "[features]\n"
            + "shell_tool = false\nview_image = false\njs_repl = false\n"
            + "multi_agent = false\nmulti_agent_v2 = false\ncode_mode = false\n"
            + "apps = false\nplugins = false\n"
        )
        stage_cli_boundary(home, env, row)
        if raw:
            with (home / "codex/auth.json").open("xb") as auth_file:
                auth_file.write(raw)
        return invoke(home, env, redactions, cwd)
    finally:
        cleanup(home)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        # All errors above use static credential names, never credential values.
        print(f"::error::Review auth refused: {error}", file=sys.stderr)
        sys.exit(1)
