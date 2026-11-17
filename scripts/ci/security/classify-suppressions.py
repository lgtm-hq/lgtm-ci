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
    osv-scanner scan --recursive --format json --config <probe-config> . \
        | python3 classify-suppressions.py

    check-vuln-suppressions.sh probes with a config that sets
    ``ScanGoModVersion = true`` so osv-scanner 2.4.0 and later still report Go
    toolchain advisories from go.mod, and retries with /dev/null on older
    releases that reject the key.

Environment:
    CONFIG_PATH  Path to suppression TOML (default: .osv-scanner.toml)

An ID listed more than once is reported once, in the category of its
strictest copy (expired before active or stale), with a warning on stderr.
An ID with a copy that was skipped (for example for a bad ``ignoreUntil``) is
never reported as stale, so the cleanup cannot remove a block the classifier
did not fully read; a warning on stderr says why it was left out.

Exit codes:
    0 - Success (JSON printed to stdout)
    1 - Error: empty probe output, or probe output that is not JSON in
        osv-scanner's shape (one ERROR line); a suppression file that is not
        valid TOML ends in a traceback (see the note at the bottom)
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import json
import os
import sys
import tomllib
from dataclasses import asdict, dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Any, NoReturn


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


def read_suppressions(toml_path: Path) -> tuple[list[SuppressionEntry], set[str]]:
    """Read [[IgnoredVulns]] entries from .osv-scanner.toml.

    Returns:
        The usable entries, and the IDs of entries skipped because their
        ``ignoreUntil`` is not a date. Entries without a usable ID are
        dropped from both.
    """
    if not toml_path.is_file():
        return [], set()

    with toml_path.open("rb") as f:
        data = tomllib.load(f)

    entries: list[SuppressionEntry] = []
    skipped: set[str] = set()
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
            skipped.add(vuln_id)
            continue
        elif not isinstance(ignore_until, date):
            print(
                f"WARNING: skipping '{vuln_id}': ignoreUntil has unsupported "
                f"type {type(ignore_until).__name__} ({ignore_until!r})",
                file=sys.stderr,
            )
            skipped.add(vuln_id)
            continue
        reason = item.get("reason", "")
        entries.append(
            SuppressionEntry(id=vuln_id, ignore_until=ignore_until, reason=reason),
        )
    return entries, skipped


def parse_suppressions(toml_path: Path) -> list[SuppressionEntry]:
    """Parse the usable [[IgnoredVulns]] entries from .osv-scanner.toml."""
    return read_suppressions(toml_path)[0]


def _fail_parse(detail: str) -> NoReturn:
    print(f"ERROR: failed to parse osv-scanner JSON output: {detail}", file=sys.stderr)
    sys.exit(1)


def _items(container: dict[str, Any], key: str, where: str) -> list[Any]:
    """Return ``container[key]`` or fail if it is not a list.

    A missing key or ``null`` is empty: osv-scanner is written in Go, which
    encodes an empty slice as ``null``.
    """
    value = container.get(key)
    if value is None:
        return []
    if not isinstance(value, list):
        _fail_parse(f"{where}.{key} is {type(value).__name__}, not an array")
    return value


def _objects(container: dict[str, Any], key: str, where: str) -> list[dict[str, Any]]:
    """Return ``container[key]`` as a list of objects or fail."""
    items = _items(container, key, where)
    for item in items:
        if not isinstance(item, dict):
            _fail_parse(f"{where}.{key} holds {type(item).__name__}, not an object")
    return items


def parse_probe_vuln_ids(probe_output: str) -> set[str]:
    """Extract vulnerability IDs from osv-scanner JSON output.

    Output whose shape differs from osv-scanner's (for example a top-level
    array) is an error, never an empty scan: missing IDs would make present
    vulnerabilities look resolved and their suppressions would be removed.
    """
    try:
        data = json.loads(probe_output)
    except json.JSONDecodeError as e:
        _fail_parse(str(e))
    if not isinstance(data, dict):
        _fail_parse(f"expected an object, got {type(data).__name__}")

    ids: set[str] = set()
    for result in _objects(data, "results", "output"):
        for pkg in _objects(result, "packages", "results[]"):
            for vuln in _objects(pkg, "vulnerabilities", "packages[]"):
                vid = vuln.get("id")
                if vid:
                    ids.add(str(vid))
            for group in _objects(pkg, "groups", "packages[]"):
                for vid in _items(group, "ids", "groups[]"):
                    ids.add(str(vid))
    return ids


def classify(
    entries: list[SuppressionEntry],
    probe_ids: set[str],
    today: date | None = None,
    *,
    unclassified: frozenset[str] | set[str] = frozenset(),
) -> Classification:
    """Classify suppressions as active, stale, or expired.

    Args:
        entries: Parsed [[IgnoredVulns]] entries.
        probe_ids: Vulnerability IDs still present in the unsuppressed scan.
        today: Reference date for expiry checks (defaults to today).
        unclassified: IDs with a copy that was skipped while reading. Such an
            ID is never reported as stale (a warning says why), so the cleanup
            cannot remove a block nobody classified.

    Returns:
        A Classification splitting IDs into active, stale, and expired, with an
        expired_until map from each expired ID to its ISO ignoreUntil date.
    """
    if today is None:
        today = date.today()

    # An ID listed more than once is reported once, in its first position,
    # under the strictest reading: expired if any copy is expired (with the
    # earliest lapsed date), so a duplicate can never hide an expired
    # suppression or get it removed as stale. Otherwise every copy shares the
    # same probe result, so active or stale is the same for all of them.
    order: dict[str, None] = {}
    lapsed: dict[str, date] = {}
    for entry in entries:
        if entry.id in order:
            print(
                f"WARNING: '{entry.id}' is listed more than once; "
                "reporting it once under its strictest reading",
                file=sys.stderr,
            )
        else:
            order[entry.id] = None
        if entry.ignore_until is not None and today > entry.ignore_until:
            earliest = lapsed.get(entry.id, entry.ignore_until)
            lapsed[entry.id] = min(earliest, entry.ignore_until)

    active: list[str] = []
    stale: list[str] = []
    expired: list[str] = []
    expired_until: dict[str, str] = {}
    for vuln_id in order:
        if vuln_id in lapsed:
            expired.append(vuln_id)
            expired_until[vuln_id] = lapsed[vuln_id].isoformat()
        elif vuln_id in probe_ids:
            active.append(vuln_id)
        elif vuln_id in unclassified:
            print(
                f"WARNING: not reporting '{vuln_id}' as stale: another copy of it "
                "was skipped and could not be classified",
                file=sys.stderr,
            )
        else:
            stale.append(vuln_id)
    return Classification(
        active=active,
        stale=stale,
        expired=expired,
        expired_until=expired_until,
    )


def main() -> None:
    """Entry point."""
    toml_path = Path(os.environ.get("CONFIG_PATH", ".osv-scanner.toml"))
    entries, skipped = read_suppressions(toml_path)

    probe_output = sys.stdin.read()
    if not probe_output.strip():
        print(
            "ERROR: osv-scanner produced no output — cannot classify "
            "suppressions without scan results",
            file=sys.stderr,
        )
        sys.exit(1)

    probe_ids = parse_probe_vuln_ids(probe_output)
    result = classify(entries, probe_ids, unclassified=skipped)
    print(json.dumps(asdict(result)))


if __name__ == "__main__":
    # Unhandled errors already print a traceback and exit non-zero, which is
    # the contract the workflow caller relies on; no broad except needed.
    main()
