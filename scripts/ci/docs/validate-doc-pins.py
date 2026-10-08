#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Require exact-commit pins in every lgtm-ci reference in docs and examples.

Governance (#1082, ``docs/governance.md#pinning``): callers pin a reusable
workflow or composite action to the full commit SHA of a release, with a
``# vX.Y.Z`` comment. Branches (``@main``), floating tags (``@v0``, ``@v1``)
and even release tags (``@v1.2.3``, movable by anyone who can push tags) are
not pins, and examples get copied verbatim, so the docs must not show them.

Every ``lgtm-hq/lgtm-ci/.github/{workflows,actions}/...@<ref>`` in
``README.md``, ``SECURITY.md``, ``docs/**/*.md`` and ``examples/**`` must
use a 40-character SHA, a placeholder in angle brackets (``<sha>``) or a
``${{ }}`` expression. ``CHANGELOG.md`` is history and is not scanned.

Usage:
    validate-doc-pins.py [--repo-root DIR]
"""

# pylint: disable=invalid-name  # CLI script; the path is the contract

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
REFERENCE = re.compile(
    r"lgtm-hq/lgtm-ci/\.github/(?:workflows|actions)/[\w./-]+@(?P<ref>[^\s\"'`)\]]+)",
)
ALLOWED_REF = re.compile(r"^(?:[0-9a-f]{40}|<[\w-]+>|\$\{\{|\\\$\{\{)")
SCANNED = ("README.md", "SECURITY.md", "docs/**/*.md", "examples/**/*")
TEXT_SUFFIXES = frozenset({".md", ".yml", ".yaml", ".json", ".toml"})


def scanned_files(
    repo_root: Path,
) -> list[Path]:
    """List the files whose lgtm-ci references are checked.

    Args:
        repo_root: Repository root.

    Returns:
        Sorted, de-duplicated text files.
    """
    found: set[Path] = set()
    for pattern in SCANNED:
        for path in repo_root.glob(pattern):
            if path.is_file() and path.suffix in TEXT_SUFFIXES:
                found.add(path)
    return sorted(found)


def floating_refs(
    text: str,
) -> list[tuple[int, str]]:
    """Find lgtm-ci references that are not pinned to a commit.

    Args:
        text: File content.

    Returns:
        ``(line number, reference)`` pairs.
    """
    problems = []
    for number, line in enumerate(text.splitlines(), start=1):
        for match in REFERENCE.finditer(line):
            if not ALLOWED_REF.match(match.group("ref")):
                problems.append((number, match.group(0)))
    return problems


def main(
    argv: list[str],
) -> int:
    """Check every scanned file.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Process exit code: 0 when every reference is pinned.
    """
    parser = argparse.ArgumentParser(description="Check lgtm-ci pins in docs.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    args = parser.parse_args(argv)
    repo_root: Path = args.repo_root.resolve()
    errors = 0
    files = scanned_files(repo_root=repo_root)
    for path in files:
        for number, reference in floating_refs(text=path.read_text(encoding="utf-8")):
            relative = path.relative_to(repo_root)
            print(
                f"ERROR: {relative}:{number}: `{reference}` is not pinned; use "
                "@<sha> # vX.Y.Z (docs/governance.md#pinning)",
                file=sys.stderr,
            )
            errors += 1
    if errors:
        print(f"ERROR: {errors} unpinned lgtm-ci reference(s)", file=sys.stderr)
        return 1
    print(f"OK: every lgtm-ci reference in {len(files)} file(s) is pinned to a commit")
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
