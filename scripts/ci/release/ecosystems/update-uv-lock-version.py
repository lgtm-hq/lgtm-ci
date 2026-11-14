#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Update the own-package version in a uv.lock file using tomlkit.

Used by ``python.sh`` instead of ``uv lock``, which would execute
caller-controlled code in the token-holding version-PR job (#1545).
Only rewrites the ``version`` of the project's own ``[[package]]`` entry
and of the dependency references that pin that entry by version; it
does NOT re-resolve dependencies or refresh any other lockfile metadata.

The project's entry is selected by source identity, never by name alone:
it is the entry named ``<package-name>`` whose ``editable``, ``virtual``,
``directory`` or ``path`` source points at the project directory relative
to the lockfile (``"."`` for a project beside its lock, ``"pkg"`` for a
workspace member in ``pkg/``). A lock with platform-dependent sources can
hold several entries of that name; the others are left alone. When the
entry cannot be identified uniquely, or a version-pinned reference to it
is ambiguous, the script exits non-zero without writing.

Preserves all formatting, comments, and table ordering.

Usage:
    python3 update-uv-lock-version.py <uv-lock-path> <package-name> \\
        <new-version> [--project-dir <dir>]

``--project-dir`` defaults to the lockfile's directory. The package name
must already be normalized the way uv records it in uv.lock (PEP 503:
lowercase, runs of ``-_.`` collapsed to a dash).
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import argparse
import contextlib
import os
import sys
import tempfile
from collections.abc import Iterator
from pathlib import Path
from typing import Any

try:
    from toml_support import (
        is_project_source,
        load_toml_document,
        lock_relative_project_path,
        require_tomlkit,
    )
except ImportError:  # standalone execution: bootstrap the vendored lib/ path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
    sys.modules.pop("toml_support", None)  # a failed attribute import stays cached
    from toml_support import (
        is_project_source,
        load_toml_document,
        lock_relative_project_path,
        require_tomlkit,
    )

tomlkit = require_tomlkit()

# Tables of a [[package]] entry that hold dependency references.
_DEPENDENCY_GROUP_KEYS = ("optional-dependencies", "dev-dependencies")


class LockUpdateError(Exception):
    """The lockfile cannot be updated safely."""


def _plain(value: Any) -> Any:
    """Return a tomlkit value as plain Python data for comparison."""
    unwrap = getattr(value, "unwrap", None)
    return unwrap() if callable(unwrap) else value


def _dependency_refs(package: dict[str, Any]) -> Iterator[dict[str, Any]]:
    """Yield every dependency reference table of a [[package]] entry."""
    yield from package.get("dependencies") or []
    for key in _DEPENDENCY_GROUP_KEYS:
        groups = package.get(key) or {}
        for refs in groups.values():
            yield from refs


def select_target(
    packages: list[dict[str, Any]],
    package_name: str,
    project_path: str,
) -> dict[str, Any]:
    """Return the project's own [[package]] entry.

    Args:
        packages: The lock's ``[[package]]`` entries.
        package_name: Normalized project name.
        project_path: Project directory relative to the lock's directory.

    Returns:
        The single entry named ``package_name`` whose local source points
        at ``project_path``.

    Raises:
        LockUpdateError: When no entry or more than one entry matches.
    """
    named = [p for p in packages if p.get("name") == package_name]
    if not named:
        raise LockUpdateError(f"package {package_name!r} not found")
    targets = [p for p in named if is_project_source(p, project_path)]
    if len(targets) == 1:
        return targets[0]
    found = ", ".join(repr(_plain(p.get("source"))) for p in named)
    if not targets:
        raise LockUpdateError(
            f"no {package_name!r} entry has a local source at {project_path!r} "
            f"(sources: {found}); cannot identify the project package",
        )
    raise LockUpdateError(
        f"{len(targets)} {package_name!r} entries have a local source at "
        f"{project_path!r}; cannot identify the project package",
    )


def pinned_references(
    packages: list[dict[str, Any]],
    target: dict[str, Any],
) -> list[dict[str, Any]]:
    """Return the dependency references that pin ``target`` by version.

    uv adds ``version`` (and ``source``) to a reference only when several
    entries share the name. A reference with a ``source`` refers to the
    entry with that source; one without refers to the entry with that
    version, which must then be unique.

    Args:
        packages: The lock's ``[[package]]`` entries.
        target: The project's own entry, as returned by ``select_target``.

    Returns:
        The reference tables whose ``version`` must follow the target's.

    Raises:
        LockUpdateError: When a reference matches the target and another
            same-name entry equally well.
    """
    name = target.get("name")
    old_version = _plain(target.get("version"))
    target_source = _plain(target.get("source"))
    same_name = [p for p in packages if p.get("name") == name]
    same_version = sum(1 for p in same_name if _plain(p.get("version")) == old_version)
    pinned: list[dict[str, Any]] = []
    for package in packages:
        for ref in _dependency_refs(package):
            if ref.get("name") != name or "version" not in ref:
                continue
            if "source" in ref:
                if _plain(ref["source"]) == target_source:
                    pinned.append(ref)
                continue
            if _plain(ref["version"]) != old_version:
                continue
            if same_version > 1:
                raise LockUpdateError(
                    f"a dependency of {_plain(package.get('name'))!r} pins "
                    f"{name!r} {old_version} without a source, and "
                    f"{same_version} entries carry that version",
                )
            pinned.append(ref)
    return pinned


def write_atomic(lock_path: Path, content: str) -> None:
    """Replace ``lock_path`` with ``content`` via a same-directory rename.

    Args:
        lock_path: The lockfile to replace.
        content: New file content.
    """
    fd, tmp_name = tempfile.mkstemp(
        dir=lock_path.parent,
        prefix=f".{lock_path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
            tmp_file.write(content)
        os.replace(tmp_name, lock_path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp_name)
        raise


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse the command line.

    Args:
        argv: Arguments without the program name.

    Returns:
        The parsed arguments.
    """
    parser = argparse.ArgumentParser(
        description="Update the own-package version in a uv.lock file.",
    )
    parser.add_argument("lock_path", type=Path)
    parser.add_argument("package_name")
    parser.add_argument("new_version")
    parser.add_argument("--project-dir", type=Path, default=None)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    """Rewrite the own-package ``version`` in a uv.lock file.

    Exits with status 1 on a missing lockfile, unreadable or unparseable
    TOML, a missing or ambiguous project entry, an ambiguous version-pinned
    reference, or a write failure. Nothing is written on failure.

    Args:
        argv: Arguments without the program name (default: ``sys.argv``).
    """
    args = parse_args(sys.argv[1:] if argv is None else argv)
    lock_path: Path = args.lock_path

    if not lock_path.is_file():
        print(f"ERROR: {lock_path} does not exist", file=sys.stderr)
        sys.exit(1)

    project_dir = args.project_dir or lock_path.parent
    project_path = lock_relative_project_path(lock_path, project_dir)

    doc = load_toml_document(lock_path)
    packages = doc.get("package")
    if not packages:
        print(f"ERROR: no [[package]] entries in {lock_path}", file=sys.stderr)
        sys.exit(1)

    try:
        target = select_target(packages, args.package_name, project_path)
        references = pinned_references(packages, target)
    except LockUpdateError as exc:
        print(f"ERROR: {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    target["version"] = args.new_version
    for ref in references:
        ref["version"] = args.new_version

    try:
        write_atomic(lock_path, tomlkit.dumps(doc))
    except OSError as exc:
        print(f"ERROR: cannot write {lock_path}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
