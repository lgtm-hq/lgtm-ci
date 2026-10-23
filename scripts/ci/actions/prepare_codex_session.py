#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Restore a subscription-only Codex session into a caller-owned private home."""

from __future__ import annotations

import base64
import binascii
import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path


def restore_session(*, destination: Path, environment: Mapping[str, str]) -> None:
    """Validate and restore subscription authentication without logging secrets.

    Args:
        destination: Empty temporary directory owned and cleaned by the caller.
        environment: Review environment containing the base64 auth.json secret.

    Raises:
        ValueError: If credentials conflict or the session is not a ChatGPT login.
        OSError: If private session files cannot be created.
    """
    pair = (
        environment.get("LINTRO_AI_PROVIDER"),
        environment.get("LINTRO_AI_TRANSPORT"),
    )
    if pair != ("openai", "cli"):
        raise ValueError("CODEX_AUTH_JSON requires openai/cli")
    competing_auth = ("CODEX_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL")
    if any(environment.get(name) for name in competing_auth):
        raise ValueError("Subscription session conflicts with API authentication")
    try:
        encoded = "".join(environment.get("CODEX_AUTH_JSON", "").split())
        payload = json.loads(base64.b64decode(encoded, validate=True))
    except (ValueError, binascii.Error, UnicodeError) as error:
        raise ValueError("Invalid base64 session JSON") from error
    if not isinstance(payload, dict) or payload.get("OPENAI_API_KEY"):
        raise ValueError("CODEX_AUTH_JSON must be a subscription session object")
    tokens = payload.get("tokens")
    if payload.get("auth_mode") != "chatgpt" or not isinstance(tokens, dict):
        raise ValueError("CODEX_AUTH_JSON must contain a ChatGPT login")
    if not all(
        isinstance(tokens.get(name), str) and tokens[name].strip()
        for name in ("access_token", "refresh_token")
    ):
        raise ValueError("CODEX_AUTH_JSON is missing ChatGPT session tokens")
    # Refuse to replace an existing login or inherit provider/auth configuration.
    if destination.is_symlink() or any(destination.iterdir()):
        raise ValueError("Codex session destination must be an empty private directory")
    destination.chmod(0o700)
    for name, content in (
        ("auth.json", json.dumps(payload)),
        (
            "config.toml",
            'model_provider = "openai"\n'
            'forced_login_method = "chatgpt"\n'
            'cli_auth_credentials_store = "file"\n',
        ),
    ):
        with (destination / name).open(mode="x", encoding="utf-8") as session_file:
            (destination / name).chmod(0o600)
            session_file.write(content)


def main() -> int:
    """Restore a session without emitting credential-bearing exceptions.

    Returns:
        Zero on success, two on invalid configuration or filesystem failure.
    """
    try:
        if len(sys.argv) != 2:
            raise ValueError("Expected a private session directory")
        restore_session(destination=Path(sys.argv[1]), environment=os.environ)
    except ValueError as error:
        # Validation reasons are fixed messages; never expose underlying causes.
        print(
            f"::error::Cannot restore a subscription-only Codex session: {error}",
            file=sys.stderr,
        )
        return 2
    except OSError:
        print(
            "::error::Cannot restore a subscription-only Codex session",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
