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
    python3 classify-suppressions.py --stale-json < classification.json
    python3 classify-suppressions.py --rows < classification.json

    check-vuln-suppressions.sh probes with a config that sets
    ``ScanGoModVersion = true`` so osv-scanner 2.4.0 and later still report Go
    toolchain advisories from go.mod, and retries with /dev/null on older
    releases that reject the key.

    ``--stale-json`` prints the ``stale`` array of a classification exactly,
    for the remover's ``REMOVE_IDS_JSON``. ``--rows`` prints one
    ``CATEGORY<TAB>id<TAB>ignoreUntil`` row per ID for logs and summaries,
    with each ID in a printable form (see ``shown``); nothing derived from
    the rows decides what is removed.

Probe output:
    Only the shape osv-scanner 2.x writes (``pkg/models/results.go``) is
    accepted; anything else fails the run instead of passing for a clean
    scan. The top level is an object whose ``results`` array is present (a
    clean scan prints ``"results": []``). Each result has a non-empty
    ``packages`` array. ``vulnerabilities`` and ``groups`` are absent or
    non-empty arrays. Every vulnerability has an ``id`` and may have a
    non-empty ``aliases`` array. Every group has ``ids`` and ``aliases``
    arrays, which may be ``null`` (Go writes an empty slice that way). Every
    ID and alias is a non-empty string, and all of them count as present,
    because osv-scanner matches a suppression against every alias in a
    group.

Suppression file:
    An ID listed more than once is reported once, in the category of its
    strictest copy (expired before active or stale), with a warning on
    stderr. An entry is skipped with a warning when its ``ignoreUntil`` is
    not a date, or when its ID has leading or trailing whitespace or a
    character that is not printable. An ID with a skipped entry is never
    reported as stale, and neither is the ID that entry would have with that
    whitespace and those characters taken out, so the cleanup cannot remove a
    block the classifier did not fully read.

Environment:
    CONFIG_PATH  Path to suppression TOML (default: .osv-scanner.toml)

Exit codes:
    0 - Success (JSON or rows printed to stdout)
    1 - Error, with one ERROR line: empty probe output, probe output that is
        not JSON in osv-scanner's shape, a suppression file that cannot be
        read or is not valid TOML, an unusable classification, or an unknown
        argument
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import json
import os
import re
import sys
import tomllib
from dataclasses import asdict, dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Any, NoReturn

_PLAIN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]*")


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


def shown(vuln_id: str) -> str:
    """Return ``vuln_id`` in a form that is safe to print.

    A plain ID (letters, digits, ``.``, ``_``, ``:``, ``-``) is printed as is.
    Anything else is JSON-quoted with backticks, pipes and percent signs
    escaped too, so it is one ASCII line that cannot break a log line, a
    Markdown code span or table, or a workflow command.
    """
    if _PLAIN_ID.fullmatch(vuln_id):
        return vuln_id
    quoted = json.dumps(vuln_id)
    for char in "`|%":
        quoted = quoted.replace(char, f"\\u{ord(char):04x}")
    return quoted


def _fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def _load_config(toml_path: Path) -> dict[str, Any]:
    """Parse the suppression file, or fail with one ERROR line."""
    try:
        with toml_path.open("rb") as f:
            return tomllib.load(f)
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        _fail(f"cannot read suppression file {toml_path}: {exc}")
    except RecursionError:
        _fail(f"cannot read suppression file {toml_path}: nested too deeply")


def _unusable_id_variants(vuln_id: str) -> set[str] | None:
    """Return the IDs to hold back for an unusable ID, or None if it is usable.

    An ID with surrounding whitespace or a character that is not printable (a
    control, format or separator character other than the ASCII space) cannot
    be matched safely. It is held back together with the IDs it would have
    with that whitespace and those characters taken out.
    """
    if vuln_id == vuln_id.strip() and vuln_id.isprintable():
        return None
    printable = "".join(char for char in vuln_id if char.isprintable())
    return {vuln_id, vuln_id.strip(), printable.strip()}


def _date_problem(ignore_until: object) -> str | None:
    """Describe why ``ignoreUntil`` is unusable, or return None."""
    if isinstance(ignore_until, datetime):
        return f"ignoreUntil must be a date, not datetime ({ignore_until!r})"
    if ignore_until is None or isinstance(ignore_until, date):
        return None
    kind = type(ignore_until).__name__
    return f"ignoreUntil has unsupported type {kind} ({ignore_until!r})"


def read_suppressions(toml_path: Path) -> tuple[list[SuppressionEntry], set[str]]:
    """Read [[IgnoredVulns]] entries from .osv-scanner.toml.

    Returns:
        The usable entries, and the IDs that must never be reported as stale
        because an entry for them was skipped: its ``ignoreUntil`` is not a
        date, or its ID is unusable (see :func:`_unusable_id_variants`).
        Entries without a string ID are dropped from both.
    """
    if not toml_path.is_file():
        return [], set()

    data = _load_config(toml_path)
    entries: list[SuppressionEntry] = []
    skipped: set[str] = set()
    for item in data.get("IgnoredVulns", []):
        if not isinstance(item, dict):
            continue
        vuln_id = item.get("id")
        if not isinstance(vuln_id, str) or not vuln_id:
            continue
        variants = _unusable_id_variants(vuln_id)
        if variants is not None:
            print(
                f"WARNING: skipping '{shown(vuln_id)}': the id has leading or "
                "trailing whitespace or a character that is not printable",
                file=sys.stderr,
            )
            skipped |= variants
            continue
        ignore_until = item.get("ignoreUntil")
        problem = _date_problem(ignore_until)
        if problem is not None:
            print(f"WARNING: skipping '{shown(vuln_id)}': {problem}", file=sys.stderr)
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
    _fail(f"failed to parse osv-scanner JSON output: {detail}")


def _kind(value: object) -> str:
    if value == "":
        return "an empty string"
    return "null" if value is None else type(value).__name__


def _array(
    container: dict[str, Any],
    key: str,
    where: str,
    *,
    required: bool = False,
    nullable: bool = False,
) -> list[Any]:
    """Return ``container[key]`` as osv-scanner writes it, or fail.

    Args:
        container: The JSON object holding the array.
        key: The array's key.
        where: The container's path, for the error message.
        required: The field has no ``omitempty``, so the key is always
            written; a missing key is an error. An optional field is never
            written as an empty array.
        nullable: ``null`` stands for an empty array, as Go writes a nil
            slice in a field without ``omitempty``.

    Returns:
        The array's items.
    """
    path = f"{where}.{key}"
    if key not in container:
        if required:
            _fail_parse(f"{path} is missing")
        return []
    value = container[key]
    if value is None and nullable:
        return []
    if not isinstance(value, list):
        _fail_parse(f"{path} is {_kind(value)}, not an array")
    if not value and not required:
        _fail_parse(f"{path} is an empty array, which osv-scanner never writes")
    return value


def _objects(
    container: dict[str, Any],
    key: str,
    where: str,
    *,
    required: bool = False,
) -> list[dict[str, Any]]:
    """Return ``container[key]`` as a list of objects or fail."""
    items = _array(container, key, where, required=required)
    for item in items:
        if not isinstance(item, dict):
            _fail_parse(f"{where}.{key} holds {_kind(item)}, not an object")
    return items


def _id(value: object, path: str) -> str:
    """Return ``value`` if it is a non-empty string, or fail."""
    if not isinstance(value, str) or not value:
        _fail_parse(f"{path} is {_kind(value)}, not a non-empty string")
    return value


def _ids(container: dict[str, Any], key: str, where: str, *, group: bool) -> list[str]:
    """Return an array of IDs; every item must be a non-empty string.

    A group always writes ``ids`` and ``aliases`` (``null`` when empty); a
    vulnerability omits an empty ``aliases``.
    """
    items = _array(container, key, where, required=group, nullable=group)
    return [_id(item, f"{where}.{key}[]") for item in items]


def parse_probe_vuln_ids(probe_output: str) -> set[str]:
    """Extract every vulnerability ID and alias from osv-scanner JSON output.

    Output whose shape differs from osv-scanner's (see the module docstring)
    is an error, never an empty scan: missing IDs would make present
    vulnerabilities look resolved and their suppressions would be removed.
    """
    try:
        data = json.loads(probe_output)
    except ValueError as e:  # JSONDecodeError, or an integer too long to read
        _fail_parse(str(e))
    except RecursionError:
        _fail_parse("nested too deeply to read")
    if not isinstance(data, dict):
        _fail_parse(f"expected an object, got {_kind(data)}")

    ids: set[str] = set()
    for result in _objects(data, "results", "output", required=True):
        packages = _objects(result, "packages", "results[]", required=True)
        if not packages:
            _fail_parse("results[].packages is an empty array")
        for pkg in packages:
            for vuln in _objects(pkg, "vulnerabilities", "packages[]"):
                ids.add(_id(vuln.get("id"), "vulnerabilities[].id"))
                ids.update(_ids(vuln, "aliases", "vulnerabilities[]", group=False))
            for group in _objects(pkg, "groups", "packages[]"):
                ids.update(_ids(group, "ids", "groups[]", group=True))
                ids.update(_ids(group, "aliases", "groups[]", group=True))
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
        probe_ids: Vulnerability IDs and aliases still present in the
            unsuppressed scan.
        today: Reference date for expiry checks (defaults to today).
        unclassified: IDs held back while reading (see
            :func:`read_suppressions`). Such an ID is never reported as stale
            (a warning says why), so the cleanup cannot remove a block nobody
            classified.

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
                f"WARNING: '{shown(entry.id)}' is listed more than once; "
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
                f"WARNING: not reporting '{shown(vuln_id)}' as stale: a "
                "suppression with this id, or with an id that differs from it "
                "only by whitespace or characters that are not printable, "
                "was skipped",
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


def _string_list(data: dict[str, Any], key: str) -> list[str]:
    value = data.get(key)
    if not isinstance(value, list) or not all(isinstance(i, str) for i in value):
        _fail(f"classification JSON: {key} must be an array of strings")
    return value


def load_classification(text: str) -> Classification:
    """Read a classification printed by this script, or fail."""
    try:
        data = json.loads(text)
    except (ValueError, RecursionError) as exc:
        _fail(f"classification JSON is not readable: {type(exc).__name__}")
    if not isinstance(data, dict):
        _fail(f"classification JSON: expected an object, got {_kind(data)}")
    until = data.get("expired_until")
    bad_until = "classification JSON: expired_until must map IDs to strings"
    if not isinstance(until, dict):
        _fail(bad_until)
    if not all(isinstance(value, str) for value in until.values()):
        _fail(bad_until)
    return Classification(
        active=_string_list(data, "active"),
        stale=_string_list(data, "stale"),
        expired=_string_list(data, "expired"),
        expired_until=until,
    )


def shell_rows(result: Classification) -> list[str]:
    """Return ``CATEGORY<TAB>id<TAB>ignoreUntil`` rows with printable IDs."""
    rows = [f"STALE\t{shown(vuln_id)}\t" for vuln_id in result.stale]
    rows += [f"ACTIVE\t{shown(vuln_id)}\t" for vuln_id in result.active]
    for vuln_id in result.expired:
        until = result.expired_until.get(vuln_id, "")
        rows.append(f"EXPIRED\t{shown(vuln_id)}\t{shown(until) if until else ''}")
    return rows


def main() -> None:
    """Entry point."""
    mode = sys.argv[1:]
    if mode in (["--rows"], ["--stale-json"]):
        result = load_classification(sys.stdin.read())
        lines = shell_rows(result) if mode == ["--rows"] else [json.dumps(result.stale)]
        for line in lines:
            print(line)
        return
    if mode:
        _fail(f"unknown arguments {mode!r}; expected none, --rows or --stale-json")

    toml_path = Path(os.environ.get("CONFIG_PATH", ".osv-scanner.toml"))
    entries, skipped = read_suppressions(toml_path)

    probe_output = sys.stdin.read()
    if not probe_output.strip():
        _fail(
            "osv-scanner produced no output — cannot classify suppressions "
            + "without scan results",
        )

    probe_ids = parse_probe_vuln_ids(probe_output)
    result = classify(entries, probe_ids, unclassified=skipped)
    print(json.dumps(asdict(result)))


if __name__ == "__main__":
    main()
