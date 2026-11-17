#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Classify vulnerability suppressions as active, stale, or expired.

Standalone version — does not depend on the lintro Python package.
Reads osv-scanner probe output from stdin and the suppression TOML from
CONFIG_PATH (default: .osv-scanner.toml). Outputs a JSON object with stale,
expired, active and not_understood arrays plus an ``expired_until`` map of
expired ID to its ISO date or datetime.

Stale and expired are distinct outcomes: stale means the vulnerability is no
longer present (safe to auto-remove), while expired means the suppression
timebox lapsed and a human must re-evaluate it (flag, do not remove). An
entry the classifier does not fully understand is never stale: it is left
alone and listed in ``not_understood``.

Usage:
    osv-scanner scan --recursive --format json --config <probe-config> . \
        | python3 classify-suppressions.py
    python3 classify-suppressions.py --stale-json < classification.json
    python3 classify-suppressions.py --rows < classification.json
    python3 classify-suppressions.py --check-paths <scan-root>

    check-vuln-suppressions.sh probes with a config that sets
    ``ScanGoModVersion = true`` so osv-scanner 2.4.0 and later still report Go
    toolchain advisories from go.mod, and retries with /dev/null on older
    releases that reject the key.

    ``--stale-json`` prints the ``stale`` array of a classification exactly,
    for the remover. ``--rows`` prints one ``CATEGORY<TAB>text<TAB>date`` row
    per entry for logs and summaries, every value in a printable form (see
    ``shown``); nothing derived from the rows decides what is removed.
    ``--check-paths`` fails when any path under the scan root (the root
    included) has a control character, because osv-scanner prints paths raw
    and such a name could split one of its messages into lines that the
    repository controls.

Suppression file (matches osv-scanner 2.7.1, ``internal/config``):
    An ``[[IgnoredVulns]]`` entry is understood only when every key is one of
    ``id`` and ``reason`` (strings) or ``ignoreUntil`` and ``effectiveUntil``
    (a TOML date or date-time), spelled exactly so, and the ``id`` is a
    non-empty string without surrounding whitespace or characters that are
    not printable. osv-scanner matches key names regardless of case and
    refuses unknown keys, so any other key, a key spelled with other case, a
    value of another type, or a bare time makes the entry "not understood":
    it is reported, never stale, and neither is any ID it might carry (every
    string under a key that is ``id`` regardless of case, and that ID without
    surrounding whitespace or characters that are not printable). A top-level
    key that is ``IgnoredVulns`` in other case holds back every ID.

    The timebox is ``effectiveUntil`` when set, otherwise ``ignoreUntil``. As
    in osv-scanner, an entry stops being in effect at that instant: a date
    means midnight at its start and a date-time without an offset means that
    time, both in the machine's current UTC offset; a date-time with an
    offset is exact. Expired means the instant has passed or is now.

    An ID listed more than once is reported once, in the category of its
    strictest copy (expired before active or stale), with a warning.

Probe output (matches osv-scanner 2.7.1, ``pkg/models/results.go``):
    Only what ``osv-scanner scan --recursive --format json --config <file>``
    can print is accepted; anything else fails the run instead of passing
    for a clean scan. The top level is an object with a ``results`` array (a
    clean scan prints ``"results": []``). Each result has a non-empty
    ``packages`` array. Without licence scanning or deprecation flags a
    package is listed only for its vulnerabilities, so each has a
    ``package`` object, non-empty ``vulnerabilities`` and ``groups`` arrays,
    and its groups list exactly its vulnerability IDs. Every ID and alias is
    a non-empty string. Duplicate keys and ``NaN``/``Infinity`` are refused.
    Every ID and alias counts as present, as osv-scanner matches a
    suppression against every alias in a group.

Probe run (set by check-vuln-suppressions.sh):
    PROBE_EXIT         osv-scanner's exit status (0 or 1). It must be the
                       status the output implies: 1 when a vulnerability is
                       called and not unimportant, 0 otherwise.
    PROBE_STDERR_FILE  File holding osv-scanner's stderr. osv-scanner prints
                       every message there without a level, and keeps exit
                       status 1 when an extractor or enricher failed. The
                       scan is trusted only when every non-empty line, on
                       its own, has a form a complete scan prints and that
                       cannot mean a package or file went unchecked
                       (``_HEALTHY_LINES``); any other line fails the run,
                       quoted in the error so it can be reported and the
                       list extended. The caller runs the probe without
                       call analysis (``--no-call-analysis=all``) and checks
                       paths first (``--check-paths``), so no message spans
                       lines.

Environment:
    CONFIG_PATH  Path to suppression TOML (default: .osv-scanner.toml)

Exit codes:
    0 - Success (JSON or rows printed to stdout)
    1 - Error, with one ERROR line: empty, malformed or incomplete probe
        output, a suppression file that cannot be read or does not hold an
        array of tables, an unusable classification, or an unknown argument
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import json
import os
import re
import sys
import tomllib
import unicodedata
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from datetime import time as clock
from pathlib import Path
from typing import Any, NamedTuple, NoReturn

_PLAIN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:+-]*")
_SAFE_TEXT = re.compile(r"[ !\"$&'()*+,./0-9:;<=>?@A-Z\[\\\]^_a-z{}~-]*")
_DISPLAY_LIMIT = 200
_TABLE = "IgnoredVulns"
_UNUSABLE_ID = "its id has surrounding whitespace or a character that is not printable"
_TEXT_KEYS = ("id", "reason")
_TIME_KEYS = ("ignoreUntil", "effectiveUntil")
# Every stderr line a complete `osv-scanner scan --recursive --format json
# --no-call-analysis=all --config <file> .` prints at v2.7.1 (osv-scalibr
# c80efcc25cd9) that cannot mean a package or file went unchecked, and only
# those. Each prefix starts exactly one message in either codebase, and every
# variable part is a number, a duration, a %q-quoted path or a parsed URL, or
# a path that --check-paths has made sure holds no control character:
#   osv-scanner pkg/osvscanner/scan.go:248: the walk starts (always ".")
#   osv-scanner pkg/osvscanner/stats.go:44: a file was read without error
#     (an extractor error skips this line); output.Form gives "1 package"
#   osv-scalibr extractor/filesystem/filesystem.go:318, :343, :762: the walk
#     starts, ends, and reports progress
#   osv-scalibr enricher/transitivedependency/pomxml/pomxml.go:168: a notice
#     printed before Maven resolution, whose failures are separate lines
#   osv-scalibr clients/datasource/maven_registry.go:267: a pom.xml names its
#     own repository; printed only after the URL parsed
# Not listed, so they fail the run: anything about filtered or unqueryable
# packages (osv-scanner internal/scalibrannotator/filter/filter.go), whose
# vulnerabilities are never looked up, and every error or warning.
_UNIT = r"(?:ns|µs|us|ms|s|m|h)"
_DURATION = rf"(?:[0-9][0-9.]*{_UNIT})+"
_PACKAGES = r"(?:1 package|(?:[02-9]|[1-9]\d+) packages)"
_RATE = r"\d+\.\d inodes/s"
_QUOTED = r'path: ".*"'
_HEALTHY_LINES = (
    re.compile(r"Scanning dir \."),
    re.compile(rf"Scanned \S.* file and found {_PACKAGES}"),
    re.compile(r"Starting filesystem walk for root: \S.*"),
    re.compile(
        r"End status: \d+ dirs visited, \d+ inodes visited, \d+ Extract calls, "
        rf"{_DURATION} elapsed, {_DURATION} wall time",
    ),
    re.compile(rf"Status: new inodes: \d+, {_RATE}, new extract calls: \d+, {_QUOTED}"),
    re.compile(
        r"Warning: enricher transitivedependency/pomxml may be risky when run on "
        r"untrusted artifacts\. Please ensure you trust the source code and "
        r"artifacts\.",
    ),
    re.compile(r"The default Maven registry is being overwritten from \S+ to \S+"),
)


@dataclass(frozen=True)
class SuppressionEntry:
    """A single understood [[IgnoredVulns]] entry from .osv-scanner.toml."""

    id: str
    ignore_until: date | None
    reason: str
    effective_until: date | None = None


@dataclass(frozen=True)
class Classification:
    """Result of classifying suppressions into their handling categories.

    Attributes:
        active: IDs whose vulnerability is still present and not expired.
        stale: IDs whose vulnerability is resolved (safe to auto-remove).
        expired: IDs past their timebox (flag for manual review).
        expired_until: Map of expired ID to its ISO timebox.
        not_understood: One printable description per entry left alone.
    """

    active: list[str]
    stale: list[str]
    expired: list[str]
    expired_until: dict[str, str]
    not_understood: list[str] = field(default_factory=list)


class Suppressions(NamedTuple):
    """What the suppression file holds, as far as it is understood."""

    entries: list[SuppressionEntry]
    held_back: set[str]
    not_understood: list[str]


class Probe(NamedTuple):
    """The IDs a probe reports, and the exit status its output implies."""

    ids: set[str]
    expected_exit: int


def shown(text: str) -> str:
    """Return ``text`` in a form that is safe to print.

    A plain ID (letters, digits, ``.``, ``_``, ``:``, ``+``, ``-``, without
    ``::``) is printed as is. Anything else is JSON-quoted with backticks,
    pipes, percent signs, number signs and colons escaped too, so it is one
    ASCII line that cannot break a log line, a Markdown code span or table,
    or act as a runner command (``::cmd::`` or ``##[cmd]``).
    """
    if _PLAIN_ID.fullmatch(text) and "::" not in text:
        return text
    quoted = json.dumps(text)
    for char in "`|%#:":
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
    except (OSError, ValueError) as exc:  # TOMLDecodeError is a ValueError
        _fail(f"cannot read suppression file {toml_path}: {exc}")
    except RecursionError:
        _fail(f"cannot read suppression file {toml_path}: nested too deeply")


def same_name(name: str, key: str) -> bool:
    """Return whether osv-scanner's TOML decoder may read ``key`` as ``name``.

    BurntSushi/toml matches field names with ``strings.EqualFold`` (Unicode
    simple case folding), so ``ID``, ``ignoreuntil`` or ``IgnoredVulnſ`` (long
    s) count. ``str.casefold`` folds every pair EqualFold does; it also folds a
    few more (``ß`` and ``ss``, ligatures), which only changes how a key that
    is not understood anyway is described.
    """
    return name.casefold() == key.casefold()


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


def _held_ids(item: dict[str, Any]) -> set[str]:
    """Return every ID an entry might carry for osv-scanner, and its twins."""
    held: set[str] = set()
    for key, value in item.items():
        if key.casefold() == "id" and isinstance(value, str):
            held |= _unusable_id_variants(value) or {value}
    return held


def _time_problem(key: str, value: object) -> str | None:
    """Describe why a timebox value is not understood, or return None."""
    if not isinstance(value, date):
        return f"{key} is {_kind(value)}, not a date or date-time"
    if value.year == 1:
        return f"{key} is in year 1, which osv-scanner reads as unset"
    return None


def _key_problem(key: str, value: object) -> str | None:
    """Describe why one key of an entry is not understood, or return None."""
    known = _TEXT_KEYS + _TIME_KEYS
    if key not in known:
        twin = next((name for name in known if same_name(name, key)), None)
        if twin is not None:
            return f"key '{shown(key)}' differs from '{twin}' only by case"
        return f"unknown key '{shown(key)}'"
    if key in _TIME_KEYS:
        return _time_problem(key, value)
    if isinstance(value, str):
        return None
    return f"{key} is {_kind(value)}, not a string"


def _entry_problems(item: dict[str, Any]) -> list[str]:
    """List why an entry is not understood; empty when it is understood."""
    problems = [
        problem
        for problem in (_key_problem(key, value) for key, value in item.items())
        if problem is not None
    ]
    vuln_id = item.get("id")
    if vuln_id is None or vuln_id == "":
        problems.append("it has no id")
    elif isinstance(vuln_id, str) and _unusable_id_variants(vuln_id) is not None:
        problems.append(_UNUSABLE_ID)
    return problems


def _describe(number: int, item: dict[str, Any], problems: list[str]) -> str:
    vuln_id = item.get("id")
    name = f", id '{shown(vuln_id)}'" if isinstance(vuln_id, str) else ""
    return f"entry {number}{name}: {'; '.join(problems)}"


def _case_twin_tables(data: dict[str, Any]) -> list[str]:
    return [key for key in data if same_name(key, _TABLE) and key != _TABLE]


def read_suppressions(toml_path: Path) -> Suppressions:
    """Read [[IgnoredVulns]] entries from .osv-scanner.toml.

    Returns:
        The understood entries; the IDs that must never be reported as stale
        because an entry that might carry them is not understood; and one
        description per entry (or file problem) not understood.
    """
    if not toml_path.is_file():
        return Suppressions([], set(), [])

    data = _load_config(toml_path)
    table = data.get(_TABLE, [])
    if not isinstance(table, list) or not all(isinstance(i, dict) for i in table):
        _fail(f"suppression file {toml_path}: {_TABLE} must be an array of tables")

    entries: list[SuppressionEntry] = []
    held: set[str] = set()
    not_understood: list[str] = []
    for number, item in enumerate(table, start=1):
        problems = _entry_problems(item)
        if problems:
            not_understood.append(_describe(number, item, problems))
            held |= _held_ids(item)
            continue
        entries.append(
            SuppressionEntry(
                id=item["id"],
                ignore_until=item.get("ignoreUntil"),
                reason=item.get("reason", ""),
                effective_until=item.get("effectiveUntil"),
            ),
        )

    for key in _case_twin_tables(data):
        not_understood.append(
            f"top-level key '{shown(key)}' differs from '{_TABLE}' only by case; "
            "no entry is reported stale",
        )
        held |= {entry.id for entry in entries}
        other = data[key]
        for item in other if isinstance(other, list) else []:
            held |= _held_ids(item) if isinstance(item, dict) else set()

    for description in not_understood:
        print(f"WARNING: left alone, not understood: {description}", file=sys.stderr)
    return Suppressions(entries, held, not_understood)


def parse_suppressions(toml_path: Path) -> list[SuppressionEntry]:
    """Parse the understood [[IgnoredVulns]] entries from .osv-scanner.toml."""
    return read_suppressions(toml_path).entries


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
    optional: bool = False,
    allow_empty: bool = False,
) -> list[Any]:
    """Return ``container[key]`` as osv-scanner writes it, or fail.

    Args:
        container: The JSON object holding the array.
        key: The array's key.
        where: The container's path, for the error message.
        optional: The field has ``omitempty``, so it may be absent.
        allow_empty: The array may be empty (only ``results``).

    Returns:
        The array's items.
    """
    path = f"{where}.{key}"
    if key not in container:
        if not optional:
            _fail_parse(f"{path} is missing")
        return []
    value = container[key]
    if not isinstance(value, list):
        _fail_parse(f"{path} is {_kind(value)}, not an array")
    if not value and not allow_empty:
        _fail_parse(f"{path} is an empty array, which osv-scanner never writes")
    return value


def _objects(container: dict[str, Any], key: str, where: str) -> list[dict[str, Any]]:
    """Return a required, non-empty ``container[key]`` of objects, or fail."""
    items = _array(container, key, where)
    for item in items:
        if not isinstance(item, dict):
            _fail_parse(f"{where}.{key} holds {_kind(item)}, not an object")
    return items


def _id(value: object, path: str) -> str:
    """Return ``value`` if it is a non-empty string, or fail."""
    if not isinstance(value, str) or not value:
        _fail_parse(f"{path} is {_kind(value)}, not a non-empty string")
    return value


def _ids(
    container: dict[str, Any],
    key: str,
    where: str,
    *,
    optional: bool,
) -> list[str]:
    """Return an array of IDs; every item must be a non-empty string."""
    items = _array(container, key, where, optional=optional)
    return [_id(item, f"{where}.{key}[]") for item in items]


def _group_is_important(group: dict[str, Any]) -> bool:
    """Return whether a group makes osv-scanner exit 1 (``GroupInfo``).

    A group counts unless its ``experimental_analysis`` says no ID is called,
    or that one is unimportant.
    """
    analysis = group.get("experimental_analysis", {})
    if not isinstance(analysis, dict) or not all(
        isinstance(item, dict) for item in analysis.values()
    ):
        _fail_parse("groups[].experimental_analysis is not an object of objects")
    names = ("called", "unimportant")
    flags = [item.get(name, False) for item in analysis.values() for name in names]
    if not all(isinstance(flag, bool) for flag in flags):
        _fail_parse("groups[].experimental_analysis holds a flag that is not a boolean")
    called = not analysis or any(item.get("called") for item in analysis.values())
    unimportant = any(item.get("unimportant") for item in analysis.values())
    return called and not unimportant


def _package_ids(pkg: dict[str, Any]) -> tuple[set[str], bool]:
    """Return a package's IDs and aliases, and whether it is important."""
    if not isinstance(pkg.get("package"), dict):
        _fail_parse("packages[].package is missing or not an object")
    for extra in ("licenses", "license_violations"):
        if extra in pkg:
            _fail_parse(f"packages[].{extra} is present, but no licences are scanned")
    if "deprecated" in pkg["package"]:
        _fail_parse("packages[].package.deprecated is present, but it is not requested")
    ids: set[str] = set()
    vuln_ids: set[str] = set()
    for vuln in _objects(pkg, "vulnerabilities", "packages[]"):
        vuln_ids.add(_id(vuln.get("id"), "vulnerabilities[].id"))
        ids.update(_ids(vuln, "aliases", "vulnerabilities[]", optional=True))
    group_ids: set[str] = set()
    important = False
    for group in _objects(pkg, "groups", "packages[]"):
        group_ids.update(_ids(group, "ids", "groups[]", optional=False))
        ids.update(_ids(group, "aliases", "groups[]", optional=False))
        important = _group_is_important(group) or important
    if group_ids != vuln_ids:
        _fail_parse("packages[].groups do not list the package's vulnerability IDs")
    return ids | vuln_ids, important


def _unique_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            _fail_parse(f"duplicate key '{shown(key)}'")
        seen.add(key)
    return dict(pairs)


def _no_constant(name: str) -> NoReturn:
    _fail_parse(f"{name} is not a JSON value osv-scanner writes")


def parse_probe(probe_output: str) -> Probe:
    """Read osv-scanner JSON output: its IDs and the exit status it implies.

    Output whose shape differs from osv-scanner's (see the module docstring)
    is an error, never an empty scan: missing IDs would make present
    vulnerabilities look resolved and their suppressions would be removed.
    """
    try:
        data = json.loads(
            probe_output,
            object_pairs_hook=_unique_keys,
            parse_constant=_no_constant,
        )
    except ValueError as e:  # JSONDecodeError, or an integer too long to read
        _fail_parse(str(e))
    except RecursionError:
        _fail_parse("nested too deeply to read")
    if not isinstance(data, dict):
        _fail_parse(f"expected an object, got {_kind(data)}")

    ids: set[str] = set()
    important = False
    results = _array(data, "results", "output", allow_empty=True)
    for result in results:
        if not isinstance(result, dict):
            _fail_parse(f"output.results holds {_kind(result)}, not an object")
        for pkg in _objects(result, "packages", "results[]"):
            package_ids, package_important = _package_ids(pkg)
            ids |= package_ids
            important = package_important or important
    return Probe(ids, 1 if important else 0)


def parse_probe_vuln_ids(probe_output: str) -> set[str]:
    """Extract every vulnerability ID and alias from osv-scanner JSON output."""
    return parse_probe(probe_output).ids


def stderr_problem(stderr: str) -> str | None:
    """Return the first stderr line a complete scan does not print, or None.

    Every non-empty physical line must match one of ``_HEALTHY_LINES`` on its
    own; no message is accepted across lines.
    """
    for raw in stderr.split("\n"):
        line = raw.rstrip()
        if line and not any(form.fullmatch(line) for form in _HEALTHY_LINES):
            return line
    return None


def control_path(root: str) -> str | None:
    """Return the first path under ``root`` with a control character, or None.

    The root itself is checked too. Symbolic links are not followed (the
    scanner does not read them), but their names are checked; nothing else is
    skipped, so this checks at least every path the scanner reads.
    """
    paths = [root]
    for directory, dirs, files in os.walk(root, onerror=_unlistable):
        paths.extend(os.path.join(directory, name) for name in dirs + files)
    for path in paths:
        if any(unicodedata.category(char) == "Cc" for char in path):
            return path
    return None


def _unlistable(error: OSError) -> NoReturn:
    _fail(f"cannot list {shown(str(error.filename))} to check paths: {error.strerror}")


def check_probe_run(probe: Probe) -> None:
    """Fail when the probe run says the scan may be incomplete.

    Uses ``PROBE_EXIT`` and ``PROBE_STDERR_FILE`` when they are set (see the
    module docstring).
    """
    exit_text = os.environ.get("PROBE_EXIT")
    if exit_text is not None:
        if exit_text not in ("0", "1"):
            _fail(f"PROBE_EXIT must be 0 or 1, not {shown(exit_text)}")
        if int(exit_text) != probe.expected_exit:
            _fail(
                f"osv-scanner exited {exit_text} but its output implies "
                f"{probe.expected_exit}; the scan is inconsistent, so nothing "
                "is classified",
            )
    stderr_path = os.environ.get("PROBE_STDERR_FILE")
    if stderr_path is None:
        return
    try:
        lines = Path(stderr_path).read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        _fail(f"cannot read PROBE_STDERR_FILE {shown(stderr_path)}: {exc.strerror}")
    line = stderr_problem(lines)
    if line is not None:
        _fail(
            "osv-scanner printed a line that a complete scan does not print, "
            "so the scan may be incomplete and nothing is classified or "
            f"removed: {_display(line)}. If the line is harmless, report it so "
            "the list of known osv-scanner messages can be extended.",
        )


def _lapse(value: date, now: datetime) -> datetime:
    """Return the instant a timebox ends, as osv-scanner reads it."""
    if isinstance(value, datetime):
        return value if value.tzinfo is not None else value.replace(tzinfo=now.tzinfo)
    return datetime.combine(value, clock(), tzinfo=now.tzinfo)


def classify(
    entries: list[SuppressionEntry],
    probe_ids: set[str],
    now: datetime | None = None,
    *,
    unclassified: frozenset[str] | set[str] = frozenset(),
    not_understood: list[str] | None = None,
) -> Classification:
    """Classify suppressions as active, stale, or expired.

    Args:
        entries: Understood [[IgnoredVulns]] entries.
        probe_ids: Vulnerability IDs and aliases still present in the
            unsuppressed scan.
        now: Reference instant for expiry checks, with a UTC offset
            (defaults to now in the machine's current offset).
        unclassified: IDs held back while reading (see
            :func:`read_suppressions`). Such an ID is never reported as stale
            (a warning says why), so the cleanup cannot remove a block nobody
            classified.
        not_understood: Descriptions of the entries left alone.

    Returns:
        A Classification splitting IDs into active, stale, and expired, with an
        expired_until map from each expired ID to its ISO timebox.
    """
    if now is None:
        now = datetime.now().astimezone()

    # An ID listed more than once is reported once, in its first position,
    # under the strictest reading: expired if any copy is expired (with the
    # earliest lapse), so a duplicate can never hide an expired suppression
    # or get it removed as stale. Otherwise every copy shares the same probe
    # result, so active or stale is the same for all of them.
    order: dict[str, None] = {}
    lapsed: dict[str, tuple[datetime, str]] = {}
    for entry in entries:
        if entry.id in order:
            print(
                f"WARNING: '{shown(entry.id)}' is listed more than once; "
                "reporting it once under its strictest reading",
                file=sys.stderr,
            )
        else:
            order[entry.id] = None
        until = entry.effective_until or entry.ignore_until
        if until is not None and now >= _lapse(until, now):
            candidate = (_lapse(until, now), until.isoformat())
            lapsed[entry.id] = min(lapsed.get(entry.id, candidate), candidate)

    active: list[str] = []
    stale: list[str] = []
    expired: list[str] = []
    expired_until: dict[str, str] = {}
    for vuln_id in order:
        if vuln_id in lapsed:
            expired.append(vuln_id)
            expired_until[vuln_id] = lapsed[vuln_id][1]
        elif vuln_id in probe_ids:
            active.append(vuln_id)
        elif vuln_id in unclassified:
            print(
                f"WARNING: not reporting '{shown(vuln_id)}' as stale: an entry "
                "that might carry this id is not understood",
                file=sys.stderr,
            )
        else:
            stale.append(vuln_id)
    return Classification(
        active=active,
        stale=stale,
        expired=expired,
        expired_until=expired_until,
        not_understood=list(not_understood or []),
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
        not_understood=_string_list(data, "not_understood"),
    )


def _display(text: str) -> str:
    """Return ``text`` printable (see ``shown``) and at most a few hundred long."""
    safe = text if _SAFE_TEXT.fullmatch(text) and "::" not in text else shown(text)
    if len(safe) <= _DISPLAY_LIMIT:
        return safe
    return f"{safe[:_DISPLAY_LIMIT]}... ({len(safe) - _DISPLAY_LIMIT} more characters)"


def shell_rows(result: Classification) -> list[str]:
    """Return ``CATEGORY<TAB>text<TAB>date`` rows, every value printable."""
    rows = [f"STALE\t{_display(shown(vuln_id))}\t" for vuln_id in result.stale]
    rows += [f"ACTIVE\t{_display(shown(vuln_id))}\t" for vuln_id in result.active]
    for vuln_id in result.expired:
        until = result.expired_until.get(vuln_id, "")
        rows.append(f"EXPIRED\t{_display(shown(vuln_id))}\t{_display(until)}")
    rows += [f"NOT_UNDERSTOOD\t{_display(text)}\t" for text in result.not_understood]
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
    if len(mode) == 2 and mode[0] == "--check-paths":
        path = control_path(mode[1])
        if path is not None:
            _fail(
                "a path under the scan root holds a control character, so "
                "osv-scanner's messages about it cannot be read safely and "
                f"nothing is classified or removed: {_display(path)}",
            )
        return
    if mode:
        _fail(
            f"unknown arguments {mode!r}; expected none, --rows, --stale-json "
            "or --check-paths <root>",
        )

    toml_path = Path(os.environ.get("CONFIG_PATH", ".osv-scanner.toml"))
    suppressions = read_suppressions(toml_path)

    probe_output = sys.stdin.read()
    if not probe_output.strip():
        _fail(
            "osv-scanner produced no output — cannot classify suppressions "
            + "without scan results",
        )

    probe = parse_probe(probe_output)
    check_probe_run(probe)
    result = classify(
        suppressions.entries,
        probe.ids,
        unclassified=suppressions.held_back,
        not_understood=suppressions.not_understood,
    )
    print(json.dumps(asdict(result)))


if __name__ == "__main__":
    main()
