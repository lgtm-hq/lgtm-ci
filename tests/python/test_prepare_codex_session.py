# SPDX-License-Identifier: MIT
"""Behavioral tests for isolated subscription authentication restoration."""

from __future__ import annotations

import base64
import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that


def encoded_session(payload: object) -> str:
    """Encode an inert authentication fixture in the workflow secret format.

    Args:
        payload: JSON-compatible authentication fixture.

    Returns:
        Base64-encoded JSON.
    """
    return base64.b64encode(json.dumps(payload).encode()).decode()


@pytest.fixture(name="session_environment")
def make_session_environment() -> dict[str, str]:
    """Provide inert ChatGPT credentials and an explicit provider/transport pair."""
    return {
        "LINTRO_AI_PROVIDER": "openai",
        "LINTRO_AI_TRANSPORT": "cli",
        "CODEX_AUTH_JSON": encoded_session(
            {
                "auth_mode": "chatgpt",
                "OPENAI_API_KEY": None,
                "tokens": {
                    "access_token": "inert-access",
                    "refresh_token": "inert-refresh",
                },
            },
        ),
    }


@pytest.mark.parametrize("wrapped", [False, True], ids=["unwrapped", "wrapped"])
def test_restores_private_session_without_inheriting_user_config(
    load_script: Callable[[str], ModuleType],
    tmp_path: Path,
    session_environment: dict[str, str],
    wrapped: bool,
) -> None:
    """Restore wrapped or plain sessions with private subscription configuration."""
    if wrapped:
        raw = base64.b64decode(session_environment["CODEX_AUTH_JSON"])
        session_environment["CODEX_AUTH_JSON"] = base64.encodebytes(raw).decode()
    module = load_script("scripts/ci/actions/prepare-codex-session.py")
    module.restore_session(destination=tmp_path, environment=session_environment)
    auth = tmp_path / "auth.json"
    config = tmp_path / "config.toml"
    restored = json.loads(auth.read_text())
    assert_that(restored["tokens"]["access_token"]).is_equal_to("inert-access")
    assert_that(auth.stat().st_mode & 0o777).is_equal_to(0o600)
    assert_that(config.stat().st_mode & 0o777).is_equal_to(0o600)
    assert_that(tmp_path.stat().st_mode & 0o777).is_equal_to(0o700)
    assert_that(config.read_text()).contains(
        'forced_login_method = "chatgpt"', 'model_provider = "openai"'
    )


@pytest.mark.parametrize(
    "secret",
    [
        "not-base64!",
        base64.b64encode(b"not JSON").decode(),
        encoded_session([]),
        encoded_session({"OPENAI_API_KEY": "inert-api-key"}),
        encoded_session({"auth_mode": "apikey", "tokens": {}}),
        encoded_session(
            {"auth_mode": "chatgpt", "tokens": {"access_token": "inert-access"}},
        ),
    ],
    ids=["base64", "json", "object", "embedded-api", "login-mode", "missing-refresh"],
)
def test_rejects_malformed_or_api_sessions_before_writing(
    load_script: Callable[[str], ModuleType],
    tmp_path: Path,
    session_environment: dict[str, str],
    secret: str,
) -> None:
    """Invalid authentication cannot leave a partial login on disk."""
    module = load_script("scripts/ci/actions/prepare-codex-session.py")
    session_environment["CODEX_AUTH_JSON"] = secret
    with pytest.raises(ValueError):
        module.restore_session(destination=tmp_path, environment=session_environment)
    assert_that(list(tmp_path.iterdir())).is_empty()


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("CODEX_API_KEY", "inert-key"),
        ("OPENAI_API_KEY", "inert-key"),
        ("OPENAI_BASE_URL", "https://example.invalid"),
        ("LINTRO_AI_PROVIDER", "anthropic"),
        ("LINTRO_AI_TRANSPORT", "api"),
    ],
)
def test_rejects_competing_authentication_and_provider_mismatch(
    load_script: Callable[[str], ModuleType],
    tmp_path: Path,
    session_environment: dict[str, str],
    name: str,
    value: str,
) -> None:
    """Subscription callers cannot drift onto API billing or another provider."""
    module = load_script("scripts/ci/actions/prepare-codex-session.py")
    session_environment[name] = value
    with pytest.raises(ValueError):
        module.restore_session(destination=tmp_path, environment=session_environment)
    assert_that(list(tmp_path.iterdir())).is_empty()


def test_refuses_to_replace_an_existing_login(
    load_script: Callable[[str], ModuleType],
    tmp_path: Path,
    session_environment: dict[str, str],
) -> None:
    """Existing authentication and configuration must never be overwritten."""
    module = load_script("scripts/ci/actions/prepare-codex-session.py")
    auth = tmp_path / "auth.json"
    auth.write_text("existing")
    with pytest.raises(ValueError, match="empty private"):
        module.restore_session(destination=tmp_path, environment=session_environment)
    assert_that(auth.read_text()).is_equal_to("existing")
