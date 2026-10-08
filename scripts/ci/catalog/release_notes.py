#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Turn the support-catalog diff between two revisions into changelog bullets.

``generate-changelog.sh`` calls this when ``CATALOG_RELEASE_NOTES`` is true
(lgtm-ci's own version PR, #1082), so every release lists what changed for
callers: entries added or removed and tier changes (``catalog/catalog.yml``),
items newly deprecated (its ``deprecations`` records), and every input,
output and secret removed from an entry point, deprecated first or not
(the same interface diff the removal gate checks). The output
uses Keep a Changelog section headings and is merged into the generated
release section; it is empty when the catalog did not change, or when either
revision has no catalog.

Usage:
    release_notes.py --base REF [--head REF] [--repo-root DIR]
"""

# pylint: disable=invalid-name  # CLI script; the path is the contract

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import Any

# catalog_lib lives next to this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_lib  # noqa: E402  # pylint: disable=wrong-import-position
import deprecations  # noqa: E402  # pylint: disable=wrong-import-position

SCOPE = "**catalog**"
SECTIONS = ("Added", "Changed", "Deprecated", "Removed")


def catalog_at(
    repo_root: Path,
    ref: str,
) -> dict[str, Any] | None:
    """Parse ``catalog/catalog.yml`` at a revision.

    Args:
        repo_root: Repository root.
        ref: Revision.

    Returns:
        The catalog, or None when the revision has none.
    """
    shown = subprocess.run(
        ["git", "-C", str(repo_root), "show", f"{ref}:{catalog_lib.CATALOG_RELPATH}"],
        capture_output=True,
        check=False,
        text=True,
    )
    if shown.returncode != 0:
        return None
    data = catalog_lib.yaml.safe_load(shown.stdout)
    return data if isinstance(data, dict) else None


def code_list(
    values: list[str],
) -> str:
    """Render ids as inline code, collapsing long lists to a count.

    Args:
        values: Entry ids.

    Returns:
        Markdown fragment.
    """
    if len(values) > 4:
        return f"{len(values)} entries"
    return ", ".join(f"`{value}`" for value in values)


def retired(
    record: dict[str, Any],
) -> str:
    """Describe what a deprecation record retires.

    Args:
        record: Deprecation record.

    Returns:
        ``input `x```, ``output `x``` or ``entry point``.
    """
    if record["kind"] == catalog_lib.DeprecationKind.ENTRY:
        return "entry point"
    return f"{record['kind']} `{record['name']}`"


def entry_notes(
    base: dict[str, Any],
    head: dict[str, Any],
) -> dict[str, list[str]]:
    """Compare the entries of two catalogs.

    Args:
        base: Catalog at the previous release.
        head: Catalog at the new release.

    Returns:
        Section name to bullets.
    """
    notes: dict[str, list[str]] = {section: [] for section in SECTIONS}
    old = {e["id"]: e for e in base.get("entries") or []}
    new = {e["id"]: e for e in head.get("entries") or []}
    for entry_id in sorted(new.keys() - old.keys()):
        tier = new[entry_id]["tier"]
        notes["Added"].append(f"- {SCOPE}: `{entry_id}` added as `{tier}`")
    for entry_id in sorted(old.keys() - new.keys()):
        tier = old[entry_id]["tier"]
        notes["Removed"].append(f"- {SCOPE}: `{entry_id}` removed (was `{tier}`)")
    for entry_id in sorted(old.keys() & new.keys()):
        before, after = old[entry_id]["tier"], new[entry_id]["tier"]
        if before != after:
            notes["Changed"].append(
                f"- {SCOPE}: `{entry_id}` tier `{before}` → `{after}`",
            )
    return notes


def deprecation_notes(
    base: dict[str, Any],
    head: dict[str, Any],
    notes: dict[str, list[str]],
) -> None:
    """Add bullets for deprecations started.

    Args:
        base: Catalog at the previous release.
        head: Catalog at the new release.
        notes: Section name to bullets, extended in place.
    """
    old = {r["id"]: r for r in base.get("deprecations") or []}
    new = {r["id"]: r for r in head.get("deprecations") or []}
    for record_id in sorted(new):
        record = new[record_id]
        before = set(old.get(record_id, {}).get("entries", []))
        added = sorted(set(record["entries"]) - before)
        if not added:
            continue
        what = f"{retired(record=record)} on {code_list(values=added)}"
        if record["kind"] == catalog_lib.DeprecationKind.ENTRY:
            what = f"{code_list(values=added)} deprecated"
        notes["Deprecated"].append(
            f"- {SCOPE}: {what} (#{record['issue']}): {record['replacement']}",
        )


def removal_notes(
    base: dict[str, Any],
    removed: list[str],
    notes: dict[str, list[str]],
) -> None:
    """Add a bullet per input, output or secret removed, grouped by name.

    Args:
        base: Catalog at the previous release (for the deprecation issue).
        removed: Removal keys from ``deprecations.removed_keys``; entry keys
            are skipped because ``entry_notes`` lists removed entries.
        notes: Section name to bullets, extended in place.
    """
    issues: dict[str, int] = {}
    for record in base.get("deprecations") or []:
        for key in catalog_lib.deprecation_keys(record=record):
            issues[key] = record["issue"]
    groups: dict[tuple[str, str], list[str]] = {}
    for key in removed:
        entry_id, kind, *rest = key.split(":")
        if kind != catalog_lib.DeprecationKind.ENTRY:
            groups.setdefault((kind, rest[0]), []).append(entry_id)
    for (kind, name), entries in sorted(groups.items()):
        keys = [f"{entry_id}:{kind}:{name}" for entry_id in entries]
        cited = sorted({issues[key] for key in keys if key in issues})
        state = "not deprecated first"
        if cited:
            state = f"deprecated (#{', #'.join(map(str, cited))})"
        notes["Removed"].append(
            f"- {SCOPE}: {kind} `{name}` removed from "
            f"{code_list(values=sorted(entries))}; {state}",
        )


def render(
    base: dict[str, Any] | None,
    head: dict[str, Any] | None,
    removed: list[str] | None = None,
) -> str:
    """Render the Keep a Changelog sections for a catalog diff.

    Args:
        base: Catalog at the previous release.
        head: Catalog at the new release.
        removed: Removal keys between the two releases.

    Returns:
        Markdown, or an empty string when there is nothing to report.
    """
    if base is None or head is None:
        return ""
    notes = entry_notes(base=base, head=head)
    deprecation_notes(base=base, head=head, notes=notes)
    removal_notes(base=base, removed=removed or [], notes=notes)
    blocks = []
    for section, bullets in notes.items():
        if bullets:
            blocks.append("\n".join([f"### {section}", "", *bullets]))
    return "\n\n".join(blocks)


def main(
    argv: list[str],
) -> int:
    """Print the release notes for a catalog diff.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Process exit code.
    """
    parser = argparse.ArgumentParser(description="Catalog diff as changelog bullets.")
    parser.add_argument("--base", required=True, help="Previous release revision")
    parser.add_argument("--head", default="HEAD", help="New release revision")
    catalog_lib.add_repo_root_argument(parser=parser)
    args = parser.parse_args(argv)
    repo_root: Path = args.repo_root.resolve()
    try:
        before = deprecations.snapshot(repo_root=repo_root, ref=args.base)
        after = deprecations.snapshot(repo_root=repo_root, ref=args.head)
        removed = []
        if before is not None and after is not None:
            removed = deprecations.removed_keys(base=before, head=after)
        text = render(
            base=catalog_at(repo_root=repo_root, ref=args.base),
            head=catalog_at(repo_root=repo_root, ref=args.head),
            removed=removed,
        )
    except (KeyError, TypeError, ValueError, catalog_lib.yaml.YAMLError) as exc:
        print(f"ERROR: catalog diff {args.base}..{args.head}: {exc}", file=sys.stderr)
        return 1
    if text:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
