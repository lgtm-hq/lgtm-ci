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

import importlib
import importlib.util
import os
import posixpath
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, cast

# Source table keys uv uses for local (non-registry) packages. The
# project's own entry always carries one of these, which disambiguates
# it from a same-name registry package elsewhere in the lockfile.
LOCAL_SOURCE_KEYS = ("editable", "virtual", "directory", "path", "workspace")


def _import_tomlkit() -> ModuleType | None:
    """Return the ``tomlkit`` module, or ``None`` when it is not installed."""
    if importlib.util.find_spec("tomlkit") is None:
        return None
    return importlib.import_module("tomlkit")


tomlkit: ModuleType | None = _import_tomlkit()


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


# Local source keys whose value is a path relative to the lockfile's
# directory ("." for the root project, "packages/foo" for a member).
PATH_SOURCE_KEYS = ("editable", "virtual", "directory", "path")


def normalize_lock_path(value: str) -> str:
    """Return a uv.lock-relative path in a comparable form.

    Args:
        value: A path as uv writes it in a ``source`` table, or one
            computed from the filesystem.

    Returns:
        The POSIX-normalized path (``"."`` for the lockfile's own
        directory).
    """
    return posixpath.normpath(str(value).replace("\\", "/"))


def is_project_source(package: dict[str, Any], project_path: str) -> bool:
    """Return True when a [[package]] entry is the project at a path.

    Args:
        package: A parsed ``[[package]]`` table from uv.lock.
        project_path: The project's directory relative to the
            lockfile's directory, as returned by ``normalize_lock_path``.

    Returns:
        True if the entry's source is editable, virtual, directory, or
        path and points at ``project_path``.
    """
    source = package.get("source") or {}
    return any(
        key in source and normalize_lock_path(source[key]) == project_path
        for key in PATH_SOURCE_KEYS
    )


def lock_relative_project_path(lock_path: Path, project_dir: Path) -> str:
    """Return ``project_dir`` relative to the directory of ``lock_path``.

    Args:
        lock_path: The uv.lock file.
        project_dir: Directory holding the project's pyproject.toml.

    Returns:
        The normalized relative path uv would record in a source table.
    """
    return normalize_lock_path(
        os.path.relpath(project_dir.resolve(), lock_path.resolve().parent),
    )


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
