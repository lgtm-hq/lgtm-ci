#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared TOML helpers for the standalone CI scripts.

The Python scripts under ``scripts/ci`` are executed directly by path and
are sometimes vendored individually, so shared TOML plumbing lives here
instead of being cloned into each script. Importers put this directory on
``sys.path`` relative to their own ``__file__`` and import what they need.
"""

from __future__ import annotations

import sys
from types import ModuleType
from typing import Any

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
