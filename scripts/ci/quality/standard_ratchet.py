# SPDX-License-Identifier: MIT
"""Read the base revision a standard check ratchets against (#1625, #1626).

Shared by ``validate_test_standard.py`` and ``validate_source_standard.py``,
whose lists (a baseline, an exception list) may only shrink against the base
revision. This module runs git without prompting, picks the base a GitHub
Actions event implies, and reads a list file from that base. Kept to the
standard library and to Python 3.9 syntax: CI runs the checks with the
runner's ``python3``.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

__all__ = [
    "PUSH_SKIPPED",
    "RATCHET_EVENTS",
    "base_file",
    "ci_base_ref",
    "git",
    "has_commit",
    "read",
]

RATCHET_EVENTS = ("pull_request", "merge_group")
PUSH_SKIPPED = "a push, which the pull request already ratcheted"


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    """Run git in the repository, capturing its output, never prompting.

    Args:
        repo: The repository root.
        *args: The git arguments after ``git -C repo``.

    Returns:
        The finished process; a failure is in its return code, not raised.
    """
    return subprocess.run(  # noqa: S603 - fixed argv, no shell
        ["git", "-C", str(repo), *args],  # noqa: S607 - git from PATH, as in CI
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
    )


def has_commit(repo: Path, ref: str) -> bool:
    """Return whether a revision resolves to a commit in the checkout.

    Args:
        repo: The repository root.
        ref: The revision.

    Returns:
        True when git can resolve ``ref`` to a commit.
    """
    commit = f"{ref}^{{commit}}"
    return git(repo, "rev-parse", "--verify", "--quiet", commit).returncode == 0


def base_file(
    repo: Path,
    ref: str,
    paths: tuple[str, str],
    names: tuple[str, str],
) -> tuple[str | None, str]:
    """Read a check's list file from a base revision that is in the checkout.

    Args:
        repo: The repository root.
        ref: The base revision.
        paths: The list file's and the check script's repository paths.
        names: What the list is (``the baseline``) and what a base without
            it lacks (``no baseline file``), for the message.

    Returns:
        The list's text (``""`` when the base has the script but not the
        list, so it allows nothing; ``None`` when the base has neither and
        predates the check), and a message naming the base.
    """
    listed, script = paths
    name, missing = names
    shown = git(repo, "show", f"{ref}:{listed}")
    if shown.returncode == 0:
        return shown.stdout, f"{name} of {ref}"
    if git(repo, "cat-file", "-e", f"{ref}:{script}").returncode == 0:
        return "", f"{ref}, which has {missing}"
    return None, f"{ref}, which predates the check"


def ci_base_ref() -> tuple[str | None, str | None]:
    """Return the base revision the GitHub Actions event implies.

    Returns:
        ``("HEAD^1", None)`` in a ``pull_request`` or ``merge_group`` run (the
        commit the merge commit was built on), ``(None, PUSH_SKIPPED)`` in any
        other Actions run, and ``(None, None)`` outside GitHub Actions.
    """
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return None, None
    if os.environ.get("GITHUB_EVENT_NAME") not in RATCHET_EVENTS:
        return None, PUSH_SKIPPED
    return "HEAD^1", None


def read(path: Path, what: str) -> str:
    """Return a file's text; raise ``ValueError`` saying which file is unreadable.

    Args:
        path: The file.
        what: What the file is, for the message.

    Returns:
        The file's text.

    Raises:
        ValueError: When the file does not exist or is not UTF-8.
    """
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError(f"cannot read the {what} {path}: {error}") from error
