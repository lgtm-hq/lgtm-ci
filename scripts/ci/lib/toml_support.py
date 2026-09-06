#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared TOML helpers for the standalone CI scripts.

The Python scripts under ``scripts/ci`` are executed directly by path and
are sometimes vendored individually together with this ``lib/`` directory,
so shared TOML plumbing lives here instead of being cloned into each
script. Importers try a plain ``from toml_support import ...`` first and,
when that fails, prepend this directory (resolved relative to their own
``__file__``) to ``sys.path`` and retry, so a script never depends on an
ambient installation of the module.
"""

from __future__ import annotations

import sys
from pathlib import Path
from types import ModuleType
from typing import Any, cast

# Source table keys uv uses for local (non-registry) packages. The
# project's own entry always carries one of these, which disambiguates
# it from a same-name registry package elsewhere in the lockfile.
LOCAL_SOURCE_KEYS = ("editable", "virtual", "directory", "path", "workspace")

try:
    import tomlkit
except ImportError:  # optional runtime dependency; require_tomlkit() reports it
    tomlkit = None  # type: ignore[assignment]


def require_tomlkit() -> ModuleType:
    """Return the ``tomlkit`` module, exiting with a hint when unavailable.

    Returns:
        The imported ``tomlkit`` module. When ``tomlkit`` is not installed,
        prints an install hint to stderr and exits with status 1, preserving
        the import-guard contract of the standalone updater scripts.
    """
    if tomlkit is None:
        print(
            "ERROR: tomlkit is required. Install via: pip install tomlkit",
            file=sys.stderr,
        )
        sys.exit(1)
    return tomlkit


def is_local_source(package: dict[str, Any]) -> bool:
    """Return True when a [[package]] entry has a local source.

    Args:
        package: A parsed ``[[package]]`` table from uv.lock.

    Returns:
        True if the entry's source is editable, virtual, directory,
        path, or workspace.
    """
    source = package.get("source") or {}
    return any(key in source for key in LOCAL_SOURCE_KEYS)


def load_toml_document(path: Path) -> dict[str, Any]:
    """Read and parse a TOML file with tomlkit.

    Args:
        path: TOML file to read.

    Returns:
        The parsed document, preserving formatting and comments.

    Raises:
        SystemExit: When the file cannot be read or parsed; prints a
            formatted ``ERROR:`` line to stderr for the CI log.
    """
    tk = require_tomlkit()
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    try:
        return cast(dict[str, Any], tk.parse(content))
    except (ValueError, tk.exceptions.TOMLKitError) as exc:
        print(f"ERROR: failed to parse {path}: {exc}", file=sys.stderr)
        sys.exit(1)
