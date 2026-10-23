# SPDX-License-Identifier: MIT
"""Exercise pinned lintro's real OpenAI CLI transport without network or models."""

from __future__ import annotations

import asyncio
import base64
import json
import os
from collections.abc import Callable
from importlib.metadata import version
from pathlib import Path
from types import ModuleType

from assertpy import assert_that
from lintro.ai.enums import AITransport
from lintro.ai.providers.openai.codex_auth import uses_subscription_session
from lintro.ai.providers.openai.provider import OpenAIProvider
from pytest import MonkeyPatch

FAKE_CODEX = '''#!/usr/bin/env python3
"""Implement only the offline Codex protocol needed by the handoff smoke test."""
import json
import os
import sys
from pathlib import Path

if "--version" in sys.argv:
    print("codex-cli 99.0.0")
elif "--help" in sys.argv:
    print("--json --model --sandbox --skip-git-repo-check --ephemeral")
else:
    home = Path(os.environ["CODEX_HOME"])
    session = json.loads((home / "auth.json").read_text())
    record = {
        "args": sys.argv[1:],
        "subscription": session.get("auth_mode"),
    }
    Path(os.environ["HANDOFF_RECORD"]).write_text(json.dumps(record))
    print(json.dumps({"type": "item.completed", "item": {
        "type": "agent_message", "text": "offline subscription handoff passed",
    }}))
    print(json.dumps({"type": "turn.completed", "usage": {
        "input_tokens": 1, "output_tokens": 1,
    }}))
'''


def test_pinned_lintro_passes_restored_subscription_to_codex(
    load_script: Callable[[str], ModuleType],
    tmp_path: Path,
    monkeypatch: MonkeyPatch,
) -> None:
    """A real lintro completion reaches an inert Codex with isolated file auth."""
    # This test's installed transport must match the canonical runtime pin.
    versions_file = Path(__file__).resolve().parents[2] / "scripts/ci/versions.env"
    runtime_version = next(
        line.removeprefix("DEFAULT_LINTRO_VERSION=").strip().strip('"')
        for line in versions_file.read_text().splitlines()
        if line.startswith("DEFAULT_LINTRO_VERSION=")
    )
    assert_that(version("lintro")).is_equal_to(runtime_version)
    module = load_script("scripts/ci/actions/prepare_codex_session.py")
    session_home = tmp_path / "session"
    session_home.mkdir()
    payload = {
        "auth_mode": "chatgpt",
        "tokens": {"access_token": "inert-access", "refresh_token": "inert-refresh"},
    }
    environment = {
        "LINTRO_AI_PROVIDER": "openai",
        "LINTRO_AI_TRANSPORT": "cli",
        "CODEX_AUTH_JSON": base64.b64encode(json.dumps(payload).encode()).decode(),
    }
    module.restore_session(destination=session_home, environment=environment)
    binary = tmp_path / "codex"
    binary.write_text(FAKE_CODEX)
    binary.chmod(0o700)
    record_file = tmp_path / "handoff.json"
    monkeypatch.setenv("PATH", f"{tmp_path}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("CODEX_HOME", str(session_home))
    monkeypatch.setenv("HANDOFF_RECORD", str(record_file))
    # The shell-wrapper BATS tests cover withholding; isolate this transport test.
    credential_keys = (
        "CODEX_AUTH_JSON",
        "CODEX_API_KEY",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
    )
    for key in credential_keys:
        monkeypatch.delenv(key, raising=False)
    assert_that(uses_subscription_session()).is_true()
    response = asyncio.run(
        OpenAIProvider(model="gpt-6.1-sol", transport=AITransport.CLI).complete(
            "Offline protocol smoke",
            repo_root=str(tmp_path),
        ),
    )
    assert_that(response.content).is_equal_to("offline subscription handoff passed")
    record = json.loads(record_file.read_text())
    assert_that(record["subscription"]).is_equal_to("chatgpt")
    assert_that(record["args"]).contains("--model", "gpt-6.1-sol")
