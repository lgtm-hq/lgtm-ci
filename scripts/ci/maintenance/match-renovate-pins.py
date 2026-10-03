#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Print regex customManager matches from renovate.json against files.

Used to prove #1062 annotations are visible to the managers in this repo.
Does not call Renovate or the network.

Usage:
    python3 scripts/ci/maintenance/match-renovate-pins.py [PATH ...]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_PIN_FILES = (
    "scripts/ci/testing/rust/setup-rust-nextest.sh",
    "scripts/ci/security/install-osv-scanner.sh",
    "scripts/ci/actions/run-bats-tests.sh",
    "scripts/ci/actions/install-ai-review-cli.sh",
    "scripts/ci/release/install-cross.sh",
    "scripts/ci/actions/setup-rust.sh",
    "scripts/ci/actions/prime-syft-tool-cache.sh",
    ".github/workflows/reusable-ai-review.yml",
    ".github/actions/setup-python/action.yml",
    ".github/actions/setup-node/action.yml",
    ".github/workflows/reusable-test-node.yml",
    ".github/workflows/reusable-test-node-custom.yml",
    ".github/workflows/reusable-test-e2e-playwright.yml",
    ".github/workflows/reusable-deploy-site-with-reports.yml",
    ".github/workflows/reusable-site-quality.yml",
    ".github/actions/scan-vulnerabilities/action.yml",
)


def load_renovate_config(
    path: Path,
) -> dict[str, Any]:
    """Load renovate.json.

    Args:
        path: Path to renovate.json.

    Returns:
        Parsed JSON object.
    """
    loaded: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise TypeError(f"renovate.json must be an object, got {type(loaded).__name__}")
    return loaded


def regex_managers(
    config: dict[str, Any],
) -> list[dict[str, Any]]:
    """Return customManagers with customType regex.

    Args:
        config: Parsed renovate.json.

    Returns:
        Regex manager objects.
    """
    managers = config.get("customManagers", [])
    if not isinstance(managers, list):
        return []
    return [
        manager
        for manager in managers
        if isinstance(manager, dict) and manager.get("customType") == "regex"
    ]


def file_matches_manager(
    rel_path: str,
    manager: dict[str, Any],
) -> bool:
    """Return whether rel_path is in a manager's managerFilePatterns.

    Args:
        rel_path: Repo-relative POSIX path.
        manager: One customManagers entry.

    Returns:
        True when any file pattern matches.
    """
    patterns = manager.get("managerFilePatterns", [])
    for raw in patterns:
        pattern = raw
        if pattern.startswith("/") and pattern.endswith("/"):
            pattern = pattern[1:-1]
        if re.search(pattern, rel_path) is not None:
            return True
    return False


def to_python_regex(
    match_string: str,
) -> str:
    """Convert Renovate/JS named groups to Python ``(?P<name>)`` groups.

    Args:
        match_string: Renovate matchString using ``(?<name>...)``.

    Returns:
        Pattern Python ``re`` can compile.
    """
    return re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", match_string)


def iter_matches(
    text: str,
    match_strings: list[str],
) -> Iterator[re.Match[str]]:
    """Yield regex matches for each Renovate matchString.

    Args:
        text: File contents.
        match_strings: Renovate matchStrings.

    Yields:
        Match objects with named groups.
    """
    for match_string in match_strings:
        yield from re.finditer(to_python_regex(match_string=match_string), text)


def format_match(
    rel_path: str,
    description: str,
    match: re.Match[str],
) -> str:
    """Format one match as a single evidence line.

    Args:
        rel_path: Repo-relative file path.
        description: Manager description.
        match: Regex match.

    Returns:
        Tab-separated evidence line.
    """
    groups = match.groupdict()
    dep_name = groups.get("depName") or ""
    current_value = groups.get("currentValue") or groups.get("currentDigest") or ""
    extract_version = groups.get("extractVersion") or ""
    versioning = groups.get("versioning") or ""
    return "\t".join(
        [
            rel_path,
            dep_name,
            current_value,
            extract_version,
            versioning,
            description,
        ],
    )


def scan_files(
    repo_root: Path,
    config: dict[str, Any],
    rel_paths: list[str],
) -> list[str]:
    """Scan files and return evidence lines.

    Args:
        repo_root: Repository root.
        config: Parsed renovate.json.
        rel_paths: Repo-relative files to scan.

    Returns:
        Evidence lines, one per match.
    """
    lines: list[str] = []
    for rel_path in rel_paths:
        path = repo_root / rel_path
        text = path.read_text(encoding="utf-8")
        for manager in regex_managers(config=config):
            if not file_matches_manager(rel_path=rel_path, manager=manager):
                continue
            match_strings = manager.get("matchStrings", [])
            description = str(manager.get("description", ""))
            for match in iter_matches(text=text, match_strings=match_strings):
                lines.append(
                    format_match(
                        rel_path=rel_path,
                        description=description,
                        match=match,
                    ),
                )
    return lines


def parse_args(
    argv: list[str],
) -> argparse.Namespace:
    """Parse CLI arguments.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Parsed arguments.
    """
    parser = argparse.ArgumentParser(
        description="Prove renovate.json regex managers match annotated pins.",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Repo-relative files to scan (default: #1062 pin files)",
    )
    return parser.parse_args(argv)


def main(
    argv: list[str],
) -> int:
    """Run the matcher.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Process exit code.
    """
    args = parse_args(argv=argv)
    rel_paths = list(args.paths) if args.paths else list(DEFAULT_PIN_FILES)
    config_path = REPO_ROOT / "renovate.json"
    config = load_renovate_config(path=config_path)
    lines = scan_files(
        repo_root=REPO_ROOT,
        config=config,
        rel_paths=rel_paths,
    )
    print("file\tdepName\tcurrentValue\textractVersion\tversioning\tmanager")
    for line in lines:
        print(line)
    return 0 if lines else 1


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
