#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Refuse a version PR that would change a workflow file without the scope.

The version-PR reusables run this only when the caller set
``request-workflows-permission: false`` (#1449). The App token then carries
no ``workflows: write``, and GitHub rejects a push that changes anything
under ``.github/workflows/``. That rejection arrives late and names no file,
so this check fails first, after the updaters and the hook diff have been
applied and before anything is published.

Every path ``git status`` reports counts: modified, staged, untracked,
deleted, and both sides of a rename or copy.

Usage:
    check_workflow_file_changes.py [--repo-root DIR]

Exit status: 0 when no workflow file changed, 1 when one did, 2 when git
could not report the working-tree state.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

PROTECTED_DIR = ".github/workflows"
PROTECTED_PREFIX = f"{PROTECTED_DIR}/"
# Statuses whose entry is followed by a second NUL-terminated path: the
# source of the rename or copy.
TWO_PATH_STATUSES = frozenset("RC")
REMEDY = (
    "set `request-workflows-permission: true` on the release workflow call "
    'and grant the release App "Workflows: Read and write"'
)


def parse_status(
    raw: str,
) -> list[str]:
    """List every path named by ``git status --porcelain=v1 -z`` output.

    Args:
        raw: The NUL-separated porcelain output.

    Returns:
        Paths relative to the repository root, in the order git reported
        them. A rename or copy contributes its destination and its source.
    """
    fields = raw.split("\0")
    paths: list[str] = []
    index = 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if len(entry) < 4:
            continue
        status, path = entry[:2], entry[3:]
        paths.append(path)
        if TWO_PATH_STATUSES.intersection(status) and index < len(fields):
            paths.append(fields[index])
            index += 1
    return paths


def changed_paths(
    repo_root: Path,
) -> list[str]:
    """Ask git for every changed path in the working tree and the index.

    Args:
        repo_root: A directory inside the repository to inspect.

    Returns:
        Paths relative to the repository root. Untracked files are listed
        one by one, so an untracked directory cannot hide a workflow file.
    """
    # Bytes, not text mode: text mode rewrites a carriage return in a file
    # name to a line feed, and the error would then name a different path.
    result = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd=repo_root,
        check=True,
        capture_output=True,
    )
    return parse_status(raw=result.stdout.decode("utf-8", errors="replace"))


def workflow_paths(
    paths: list[str],
) -> list[str]:
    """Keep the paths at or under ``.github/workflows``.

    The directory path itself counts: a symlink or a plain file put in its
    place is reported by git without a trailing slash.

    Args:
        paths: Paths relative to the repository root.

    Returns:
        The protected paths, sorted and without duplicates.
    """
    protected: set[str] = set()
    for path in paths:
        if path == PROTECTED_DIR or path.startswith(PROTECTED_PREFIX):
            protected.add(path)
    return sorted(protected)


def escape_command_data(
    value: str,
) -> str:
    """Escape text for the message part of a workflow command.

    Args:
        value: Text that may hold ``%`` or line breaks.

    Returns:
        The text with the characters the runner would interpret encoded.
    """
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(
    argv: list[str] | None = None,
) -> int:
    """Run the check and report each offending path.

    Args:
        argv: Command-line arguments; ``None`` reads ``sys.argv``.

    Returns:
        The process exit status described in the module docstring.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)

    try:
        paths = changed_paths(repo_root=args.repo_root)
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", b"") or str(error)
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", errors="replace")
        message = escape_command_data(value=f"git status failed: {detail.strip()}")
        print(f"::error title=workflow file check failed::{message}")
        return 2

    offending = workflow_paths(paths=paths)
    if not offending:
        print("No changes under .github/workflows/")
        return 0

    for path in offending:
        message = escape_command_data(
            value=(
                f"{path} changed, but the version-PR token has no workflows "
                f"permission (request-workflows-permission is false); {REMEDY}"
            ),
        )
        print(f"::error title=workflow file changed::{message}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
