#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Classify vulnerability suppressions as active, stale, or expired.

Standalone version — does not depend on the lintro Python package.
Reads osv-scanner probe output from stdin and the suppression TOML from
CONFIG_PATH (default: .osv-scanner.toml). Outputs a JSON object with stale,
expired, and active ID arrays plus an ``expired_until`` map of expired ID to
its ISO ``ignoreUntil`` date.

Stale and expired are distinct outcomes: stale means the vulnerability is no
longer present (safe to auto-remove), while expired means the suppression
timebox lapsed and a human must re-evaluate it (flag, do not remove).

Usage:
    osv-scanner scan --recursive --format json --config /dev/null . \
        | python3 classify-suppressions.py

Environment:
    CONFIG_PATH  Path to suppression TOML (default: .osv-scanner.toml)

Exit codes:
    0 - Success (JSON printed to stdout)
    1 - Error
"""

from __future__ import annotations

import json
import os
import sys
import tomllib
import traceback
from dataclasses import asdict, dataclass
from datetime import date, datetime
from pathlib import Path


@dataclass(frozen=True)
class SuppressionEntry:
    """A single [[IgnoredVulns]] entry from .osv-scanner.toml."""

    id: str
    ignore_until: date | None
    reason: str


@dataclass(frozen=True)
class Classification:
    """Result of classifying suppressions into their handling categories.

    Attributes:
        active: IDs whose vulnerability is still present and not expired.
        stale: IDs whose vulnerability is resolved (safe to auto-remove).
        expired: IDs past their ignoreUntil date (flag for manual review).
        expired_until: Map of expired ID to its ISO ignoreUntil date.
    """

    active: list[str]
    stale: list[str]
    expired: list[str]
    expired_until: dict[str, str]


def parse_suppressions(toml_path: Path) -> list[SuppressionEntry]:
    """Parse [[IgnoredVulns]] entries from .osv-scanner.toml."""
    if not toml_path.is_file():
        return []

    with toml_path.open("rb") as f:
        data = tomllib.load(f)

    entries: list[SuppressionEntry] = []
    for item in data.get("IgnoredVulns", []):
        if not isinstance(item, dict):
            continue
        vuln_id = item.get("id")
        if not isinstance(vuln_id, str) or not vuln_id:
            continue
        ignore_until = item.get("ignoreUntil")
        if ignore_until is None:
            pass
        elif isinstance(ignore_until, datetime):
            print(
                f"WARNING: skipping '{vuln_id}': ignoreUntil must be a date, "
                f"not datetime ({ignore_until!r})",
                file=sys.stderr,
            )
            continue
        elif not isinstance(ignore_until, date):
            print(
                f"WARNING: skipping '{vuln_id}': ignoreUntil has unsupported "
                f"type {type(ignore_until).__name__} ({ignore_until!r})",
                file=sys.stderr,
            )
            continue
        reason = item.get("reason", "")
        entries.append(
            SuppressionEntry(id=vuln_id, ignore_until=ignore_until, reason=reason),
        )
    return entries


def parse_probe_vuln_ids(probe_output: str) -> set[str]:
    """Extract vulnerability IDs from osv-scanner JSON output."""
    try:
        data = json.loads(probe_output)
    except json.JSONDecodeError as e:
        print(
            f"ERROR: failed to parse osv-scanner JSON output: {e}",
            file=sys.stderr,
        )
        sys.exit(1)

    ids: set[str] = set()
    for result in data.get("results", []):
        for pkg in result.get("packages", []):
            for vuln in pkg.get("vulnerabilities", []):
                vid = vuln.get("id")
                if vid:
                    ids.add(str(vid))
            for group in pkg.get("groups", []):
                for vid in group.get("ids", []):
                    ids.add(str(vid))
    return ids


def classify(
    entries: list[SuppressionEntry],
    probe_ids: set[str],
    today: date | None = None,
) -> Classification:
    """Classify suppressions as active, stale, or expired.

    Args:
        entries: Parsed [[IgnoredVulns]] entries.
        probe_ids: Vulnerability IDs still present in the unsuppressed scan.
        today: Reference date for expiry checks (defaults to today).

    Returns:
        A Classification splitting IDs into active, stale, and expired, with an
        expired_until map from each expired ID to its ISO ignoreUntil date.
    """
    if today is None:
        today = date.today()

    active: list[str] = []
    stale: list[str] = []
    expired: list[str] = []
    expired_until: dict[str, str] = {}
    for entry in entries:
        if entry.ignore_until is not None and today > entry.ignore_until:
            expired.append(entry.id)
            expired_until[entry.id] = entry.ignore_until.isoformat()
        elif entry.id in probe_ids:
            active.append(entry.id)
        else:
            stale.append(entry.id)
    return Classification(
        active=active,
        stale=stale,
        expired=expired,
        expired_until=expired_until,
    )


def main() -> None:
    """Entry point."""
    toml_path = Path(os.environ.get("CONFIG_PATH", ".osv-scanner.toml"))
    entries = parse_suppressions(toml_path)

    probe_output = sys.stdin.read()
    if not probe_output.strip():
        print(
            "ERROR: osv-scanner produced no output — cannot classify "
            "suppressions without scan results",
            file=sys.stderr,
        )
        sys.exit(1)

    probe_ids = parse_probe_vuln_ids(probe_output)
    result = classify(entries, probe_ids)
    print(json.dumps(asdict(result)))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
