# SPDX-License-Identifier: MIT
"""Deprecation, known-consumer and exception checks of the catalog (#1082).

``validate.py`` runs these after its entry checks:

- every ``deprecations`` record is well formed and names entries that still
  expose the input, output or secret it retires (or, for ``kind: entry``,
  entries of tier ``deprecated``), whose description says so; every item
  whose description says it is deprecated or inert, and every deprecated
  entry, is covered by a record;
- ``catalog/consumers.yml`` and ``catalog/deprecation-exceptions.yml`` are
  well formed. Registry rows naming entries or items lgtm-ci no longer has,
  or pinning a floating ref, get a NOTICE.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

# catalog_lib lives next to this module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_lib  # noqa: E402  # pylint: disable=wrong-import-position
from catalog_lib import (  # noqa: E402  # pylint: disable=wrong-import-position
    CATALOG,
    FULL_SHA,
    REPOSITORY,
    SCHEMA_VERSION,
    DeprecationKind,
    Kind,
    Report,
    Tier,
    is_one_line,
)

DEPRECATION_KEYS = frozenset(
    {"id", "kind", "name", "entries", "since", "issue", "replacement"},
)
SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CONSUMER_KEYS = frozenset(
    {
        "repository",
        "tracking-issues",
        "last-verified",
        "pins",
        "uses",
        "deprecated-in-use",
    },
)
EXCEPTION_KEYS = frozenset({"removal", "issue", "reason"})
REMOVAL_KEY = re.compile(
    r"^[\w.-]+:(?:entry|(?:input|output|secret|required|required-secret):[\w-]+)$",
)
REFRESH = "refresh with scripts/ci/catalog/check-deprecations.sh scan --write"


def load_surfaces(
    entries: list[dict[str, Any]],
    repo_root: Path,
) -> dict[str, dict[DeprecationKind, dict[str, str]]]:
    """Read the inputs and outputs of every entry whose file exists.

    Args:
        entries: Catalog entries.
        repo_root: Repository root.

    Returns:
        Entry id to its ``catalog_lib.interface()``; unreadable files are left
        out (the coverage and schema checks already report them).
    """
    surfaces: dict[str, dict[DeprecationKind, dict[str, str]]] = {}
    for entry in entries:
        try:
            kind = Kind(entry.get("kind"))
            path = repo_root / catalog_lib.entry_path(kind=kind, entry_id=entry["id"])
            document = catalog_lib.yaml.safe_load(path.read_text(encoding="utf-8"))
        except (KeyError, OSError, ValueError, catalog_lib.yaml.YAMLError):
            continue
        surfaces[str(entry["id"])] = catalog_lib.interface(kind=kind, document=document)
    return surfaces


def check_deprecation_shape(
    report: Report,
    record: dict[str, Any],
    ids: set[str],
) -> bool:
    """Validate one deprecation record's fields.

    Args:
        report: Findings sink.
        record: Entry of ``deprecations``.
        ids: Every catalog entry id.

    Returns:
        False when the record cannot be checked against the repository.
    """
    where = f"deprecations[{record.get('id', '?')}]"
    before = len(report.errors)
    for key in sorted(set(record) - DEPRECATION_KEYS):
        report.error(where, f"unknown key `{key}`")
    if not SLUG.fullmatch(str(record.get("id", ""))):
        report.error(where, "`id` must be a lower-case kebab-case slug")
    try:
        kind = DeprecationKind(record.get("kind"))
    except ValueError:
        kinds = ", ".join(k.value for k in DeprecationKind)
        report.error(where, f"`kind` must be one of {kinds}")
        return False
    if kind is DeprecationKind.ENTRY and "name" in record:
        report.error(where, "`name` is only for an input, output or secret")
    if kind is not DeprecationKind.ENTRY and not is_one_line(record.get("name")):
        report.error(where, f"a {kind.value} deprecation needs the `name` it retires")
    if not VERSION.fullmatch(str(record.get("since", ""))):
        report.error(
            where,
            "`since` must be the X.Y.Z release that first marked it deprecated",
        )
    issue = record.get("issue")
    if not isinstance(issue, int) or isinstance(issue, bool) or issue < 1:
        report.error(where, "`issue` must be the number of the issue tracking it")
    if not is_one_line(record.get("replacement")):
        report.error(where, "`replacement` must be a one-line migration instruction")
    entries = record.get("entries")
    if not isinstance(entries, list) or not entries:
        report.error(where, "`entries` must be a non-empty list of catalog ids")
        return False
    names = [str(e) for e in entries]
    if names != sorted(set(names)):
        report.error(where, "`entries` must be sorted and list each id once")
    for entry_id in sorted(set(names) - ids):
        report.error(where, f"`{entry_id}` is not a catalog entry")
    return len(report.errors) == before


def check_deprecation_targets(
    report: Report,
    record: dict[str, Any],
    tiers: dict[str, str],
    surfaces: dict[str, dict[DeprecationKind, dict[str, str]]],
) -> None:
    """Require every entry a record names to expose what it retires.

    Args:
        report: Findings sink.
        record: Shape-checked deprecation record.
        tiers: Entry id to tier.
        surfaces: Entry id to its inputs and outputs.
    """
    where = f"deprecations[{record['id']}]"
    kind = DeprecationKind(record["kind"])
    for entry_id in record["entries"]:
        if kind is DeprecationKind.ENTRY:
            if tiers.get(entry_id) != Tier.DEPRECATED.value:
                report.error(where, f"`{entry_id}` must have tier `deprecated`")
            continue
        surface = surfaces.get(entry_id, {}).get(kind, {})
        name = record["name"]
        if name not in surface:
            report.error(
                where,
                f"`{entry_id}` has no {kind.value} `{name}`; once it is gone, drop "
                "the entry from this record (the removal gate checks consumers)",
            )
        elif not catalog_lib.DEPRECATION_MARKER.search(surface[name]):
            report.error(
                where,
                f"`{entry_id}` {kind.value} `{name}`: its description must say it "
                "is deprecated so callers see it in their editor and the docs",
            )


def check_deprecations(
    report: Report,
    catalog: dict[str, Any],
    entries: list[dict[str, Any]],
    repo_root: Path,
) -> set[str]:
    """Validate ``deprecations`` and require it to cover every marked item.

    Args:
        report: Findings sink.
        catalog: Parsed catalog.
        entries: Catalog entries.
        repo_root: Repository root.

    Returns:
        The removal keys the records cover.
    """
    records = catalog.get("deprecations", [])
    if not isinstance(records, list) or not all(isinstance(r, dict) for r in records):
        report.error(CATALOG, "`deprecations` must be a list of mappings")
        return set()
    ids = {str(e.get("id")) for e in entries}
    tiers = {str(e.get("id")): str(e.get("tier")) for e in entries}
    surfaces = load_surfaces(entries=entries, repo_root=repo_root)
    record_ids = [str(r.get("id")) for r in records]
    if record_ids != sorted(record_ids):
        report.error("deprecations", "records must be sorted by id")
    for record_id in sorted({i for i in record_ids if record_ids.count(i) > 1}):
        report.error("deprecations", f"`{record_id}` is listed more than once")
    covered: set[str] = set()
    for record in records:
        if not check_deprecation_shape(report=report, record=record, ids=ids):
            continue
        check_deprecation_targets(
            report=report,
            record=record,
            tiers=tiers,
            surfaces=surfaces,
        )
        keys = catalog_lib.deprecation_keys(record=record)
        for key in sorted(keys & covered):
            report.error(f"deprecations[{record['id']}]", f"`{key}` is already covered")
        covered |= keys
    check_marked_items(report=report, surfaces=surfaces, tiers=tiers, covered=covered)
    return covered


def check_marked_items(
    report: Report,
    surfaces: dict[str, dict[DeprecationKind, dict[str, str]]],
    tiers: dict[str, str],
    covered: set[str],
) -> None:
    """Require a record for every item marked deprecated and every deprecated entry.

    Args:
        report: Findings sink.
        surfaces: Entry id to its inputs, outputs and secrets.
        tiers: Entry id to tier.
        covered: Removal keys the records cover.
    """
    for entry_id, surface in sorted(surfaces.items()):
        marked = [
            catalog_lib.removal_key(entry_id=entry_id, kind=kind, name=name)
            for kind, items in surface.items()
            for name, description in items.items()
            if catalog_lib.DEPRECATION_MARKER.search(description)
        ]
        whole = catalog_lib.removal_key(entry_id=entry_id, kind=DeprecationKind.ENTRY)
        if tiers.get(entry_id) == Tier.DEPRECATED.value:
            marked.append(whole)
        if whole in covered:
            # Retiring the entry point retires everything it exposes.
            continue
        for key in sorted(set(marked) - covered):
            report.error(
                entry_id,
                f"`{key}` is marked deprecated but no `deprecations` record covers "
                "it; add one (since, issue, replacement) so removal is gated",
            )


def load_optional_mapping(
    report: Report,
    repo_root: Path,
    relpath: Path,
    list_key: str,
) -> list[dict[str, Any]] | None:
    """Load a ``schema-version: 1`` file holding one list of mappings.

    Args:
        report: Findings sink.
        repo_root: Repository root.
        relpath: File to read.
        list_key: Top-level key of the list.

    Returns:
        The list, or None when the file is unusable (an error is recorded).
    """
    where = str(relpath)
    try:
        data = catalog_lib.load_catalog(path=repo_root / relpath)
    except (OSError, ValueError, catalog_lib.yaml.YAMLError) as exc:
        report.error(where, f"unreadable ({exc})")
        return None
    for key in sorted(set(data) - {"schema-version", list_key}):
        report.error(where, f"unknown top-level key `{key}`")
    if data.get("schema-version") != SCHEMA_VERSION:
        report.error(where, f"`schema-version` must be {SCHEMA_VERSION}")
    rows = data.get(list_key)
    if rows is None:
        return []
    if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
        report.error(where, f"`{list_key}` must be a list of mappings")
        return None
    return rows


def is_issue_list(
    value: Any,
) -> bool:
    """Return whether a value is a list of positive issue numbers.

    Args:
        value: Value to test.

    Returns:
        True for a list of positive ints (bools excluded).
    """
    return isinstance(value, list) and all(
        isinstance(v, int) and not isinstance(v, bool) and v > 0 for v in value
    )


def check_consumer(
    report: Report,
    row: dict[str, Any],
    ids: set[str],
    covered: set[str],
) -> None:
    """Validate one known-consumer row.

    Args:
        report: Findings sink.
        row: Entry of ``consumers``.
        ids: Every catalog entry id.
        covered: Removal keys the deprecation records cover.
    """
    where = f"consumers[{row.get('repository', '?')}]"
    for key in sorted(set(row) - CONSUMER_KEYS):
        report.error(where, f"unknown key `{key}`")
    for key in sorted(CONSUMER_KEYS - set(row)):
        report.error(where, f"missing required key `{key}`")
    if not REPOSITORY.fullmatch(str(row.get("repository", ""))):
        report.error(where, "`repository` must be owner/name")
    if not is_issue_list(row.get("tracking-issues", [])):
        report.error(where, "`tracking-issues` must be a list of issue numbers")
    # PyYAML reads an unquoted date as datetime.date; str() gives ISO either way.
    if not ISO_DATE.fullmatch(str(row.get("last-verified", ""))):
        report.error(where, "`last-verified` must be a YYYY-MM-DD date")
    for key in ("pins", "uses", "deprecated-in-use"):
        value = row.get(key, [])
        if not isinstance(value, list) or not all(is_one_line(v) for v in value):
            report.error(where, f"`{key}` must be a list of one-line strings")
            return
        if value != sorted(set(value)):
            report.error(where, f"`{key}` must be sorted and list each value once")
    for pin in row.get("pins", []):
        if not FULL_SHA.fullmatch(pin):
            report.notices.append(
                f"{where}: pins lgtm-ci at `{pin}`, a floating ref; consumers "
                "should pin an exact commit SHA (docs/governance.md#pinning)",
            )
    stale = [e for e in row.get("uses", []) if e not in ids]
    stale += [k for k in row.get("deprecated-in-use", []) if k not in covered]
    if stale:
        report.notices.append(
            f"{where}: still uses {', '.join(stale)}, which lgtm-ci no longer "
            f"lists or deprecates (removed); its next pin bump breaks, or {REFRESH}",
        )


def check_consumers(
    report: Report,
    repo_root: Path,
    ids: set[str],
    covered: set[str],
) -> None:
    """Validate the known-consumer registry.

    Args:
        report: Findings sink.
        repo_root: Repository root.
        ids: Every catalog entry id.
        covered: Removal keys the deprecation records cover.
    """
    rows = load_optional_mapping(
        report=report,
        repo_root=repo_root,
        relpath=catalog_lib.CONSUMERS_RELPATH,
        list_key="consumers",
    )
    if rows is None:
        return
    repos = [str(r.get("repository")) for r in rows]
    if repos != sorted(set(repos), key=str.lower) or len(repos) != len(set(repos)):
        report.error(
            str(catalog_lib.CONSUMERS_RELPATH),
            "consumers must be sorted by repository (case-insensitive), each once",
        )
    for row in rows:
        check_consumer(report=report, row=row, ids=ids, covered=covered)


def check_exceptions(
    report: Report,
    repo_root: Path,
) -> None:
    """Validate the removal exceptions file.

    Args:
        report: Findings sink.
        repo_root: Repository root.
    """
    rows = load_optional_mapping(
        report=report,
        repo_root=repo_root,
        relpath=catalog_lib.EXCEPTIONS_RELPATH,
        list_key="exceptions",
    )
    if rows is None:
        return
    seen: set[str] = set()
    for row in rows:
        removal = str(row.get("removal", ""))
        where = f"exceptions[{removal or '?'}]"
        for key in sorted(set(row) ^ EXCEPTION_KEYS):
            state = "unknown" if key in row else "missing required"
            report.error(where, f"{state} key `{key}`")
        if not REMOVAL_KEY.fullmatch(removal):
            kinds = "input|output|secret|required|required-secret"
            report.error(
                where,
                f"`removal` must be <entry>:entry or <entry>:<{kinds}>:<name>",
            )
        if removal in seen:
            report.error(where, "listed more than once")
        seen.add(removal)
        if not is_issue_list([row.get("issue")]):
            report.error(where, "`issue` must name the issue that approved the removal")
        if not is_one_line(row.get("reason")):
            report.error(where, "`reason` must be one line")
