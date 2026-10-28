#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bind one review credential in an isolated home, config and child environment.

No repository config, dotenv, CLI settings, cached login, helper or test override
is loaded in credential scope. The credential-free install step prepares VENV_DIR
and AI_TOOLS_PREFIX first. An always() workflow step provides a second cleanup.
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
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent / "lib"))
# Standalone script library is added to the search path above.
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
        value = json.loads(raw)
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


def cleanup(home: Path) -> None:
    """Remove only this job's owned material; refuse symlinks or unmarked paths."""
    if not home.exists() and not home.is_symlink():
        return
    marker = home / ".lgtm-ci-owned"
    if (
        home.is_symlink()
        or home.stat().st_uid != os.getuid()
        or marker.is_symlink()
        or not marker.is_file()
        or marker.read_text() != home.name
    ):
        raise ValueError("Refusing cleanup of an unowned review home")
    shutil.rmtree(home)


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
        prefix = Path(os.environ["AI_TOOLS_PREFIX"]).resolve(strict=True)
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


def invoke(home: Path, env: dict[str, str], redactions: list[str]) -> int:
    """Run the bounded review and reap its process group before session cleanup."""
    # Darwin reports EPERM for an empty orphan process group after timeout;
    # Linux reports ESRCH. Children share our uid and cannot change credentials.
    group_absent_errors: tuple[type[OSError], ...] = (ProcessLookupError,)
    if sys.platform == "darwin":
        group_absent_errors += (PermissionError,)
    # Buffer inside the owned home, then redact before any log emission. This
    # also avoids a detached CLI holding a pipe open after its parent exits.
    with (home / "review.log").open("w+", encoding="utf-8") as log:
        process = subprocess.Popen(
            ["/bin/bash", str(SCRIPT_DIR / "run-ai-review.sh")],
            cwd=home / "work",
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )

        def cancel(signum: int, _frame: object) -> None:
            """Forward cancellation and reap the child before removing credentials."""
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
        cleanup(home)
        return 0
    row = selected_row()
    env = child_environment(home, row)
    raw = b""
    redactions = [os.environ[row[4]]]
    if row[4] == "CODEX_AUTH_JSON":
        raw, redactions = session_payload(os.environ[row[4]])
    os.umask(0o077)
    # Exclusive mkdir refuses pre-existing homes and symlinks; never overwrite.
    home.mkdir(mode=0o700)
    try:
        (home / ".lgtm-ci-owned").write_text(home.name)
        (home / "work").mkdir(mode=0o700)
        # Empty config and isolated cwd exclude PR settings/hooks/dotenv completely.
        (home / "work/.lintro-config.yaml").write_text("{}\n")
        (home / "codex").mkdir(mode=0o700)
        (home / "codex/config.toml").write_text(
            'cli_auth_credentials_store = "file"\n'
            + f'forced_login_method = "{"chatgpt" if row[2] == "oauth" else "api"}"\n'
        )
        if raw:
            with (home / "codex/auth.json").open("xb") as auth_file:
                auth_file.write(raw)
        return invoke(home, env, redactions)
    finally:
        cleanup(home)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        # All errors above use static credential names, never credential values.
        print(f"::error::Review auth refused: {error}", file=sys.stderr)
        sys.exit(1)
