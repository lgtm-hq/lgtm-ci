#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Gate removals on known-consumer migration evidence (#1082).

Three subcommands, all driven by ``catalog/catalog.yml`` (its
``deprecations`` records), ``catalog/consumers.yml`` (the known-consumer
registry) and ``catalog/deprecation-exceptions.yml``:

``scan`` (``consumer_scan.py``)
    Read every registry repository's default branch with ``gh`` (workflow
    files and composite ``action.yml`` files), find each
    ``lgtm-hq/lgtm-ci/...@<ref>`` call, and recompute the row: the refs it
    pins, the entries it uses and the deprecated items it still uses (inputs
    it passes, outputs it reads, deprecated entry points it calls). Prints
    the per-deprecation report; ``--write`` stores the rows with today's
    date. Needs a token that can read the consumers.

``report``
    Print, from the registry alone, which consumers still use each
    deprecated item.

``gate`` (default; what CI runs)
    Compare the catalog and entry-point files at ``--base-ref`` with the
    work tree and list every input, output, secret and entry point the
    change removes, and every input it makes required. The evidence is the
    base registry merged with the work tree's: a change can add consumers
    and usage but never drop them or move ``last-verified`` forward, so a
    refresh that clears a consumer lands on the default branch first. Only
    exceptions the change itself adds count. A removal fails unless such an
    exception names it, or:

    * it was deprecated at the base (a ``deprecations`` record covered it),
      no registry consumer still uses it, and every consumer row was
      verified within ``--max-age-days``; time since the deprecation never
      counts; or
    * its entry was ``preview`` or ``internal`` and the item was never
      deprecated: those tiers may change without a migration (a NOTICE lists
      registry consumers of the entry). Removing a never-deprecated item
      from a ``stable`` or ``deprecated`` entry always fails, and so does
      making an optional input of such an entry required.

Usage:
    deprecations.py gate [--base-ref REF] [--max-age-days N] [--today DATE]
    (CI passes the merge commit's first parent, HEAD^1)
    deprecations.py report
    deprecations.py scan [--write] [--repository OWNER/NAME ...] [--today DATE]
"""

# pylint: disable=invalid-name  # CLI script; the path is the contract

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# catalog_lib lives next to this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_lib  # noqa: E402  # pylint: disable=wrong-import-position
import consumer_scan  # noqa: E402  # pylint: disable=wrong-import-position
from catalog_lib import (  # noqa: E402  # pylint: disable=wrong-import-position
    DeprecationKind,
    Snapshot,
    Tier,
    entry_of,
    git,
    load_rows,
    snapshot,
)

DEFAULT_MAX_AGE_DAYS = 14
COMMANDS = frozenset({"gate", "report", "scan"})


def merged_consumers(
    base: list[dict[str, Any]],
    head: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Combine the base and work-tree registries so a change cannot erase evidence.

    Rows dropped by the change are kept, usage lists are unioned and a row
    already on the base keeps the base ``last-verified``. A refresh that
    clears a consumer therefore takes effect once it is on the base.

    Args:
        base: Registry rows at the base revision.
        head: Registry rows in the work tree.

    Returns:
        Merged rows.
    """
    merged = {str(row.get("repository")): dict(row) for row in head}
    for row in base:
        repository = str(row.get("repository"))
        current = merged.setdefault(repository, dict(row))
        for key in ("pins", "uses", "deprecated-in-use"):
            values = set(current.get(key) or []) | set(row.get(key) or [])
            current[key] = sorted(values)
        current["last-verified"] = row.get("last-verified")
    return list(merged.values())


def removed_keys(
    base: Snapshot,
    head: Snapshot,
) -> list[str]:
    """List what the change removes, one key per removed entry point.

    Args:
        base: Snapshot at the base revision.
        head: Snapshot of the work tree.

    Returns:
        Sorted removal keys; an entry removed whole hides its own inputs and
        outputs.
    """
    gone = base.keys - head.keys
    whole = {entry_of(key) for key in gone if key.endswith(":entry")}
    # An entry removed whole is reported once, not once per input.
    kept = [k for k in gone if entry_of(k) not in whole or k.endswith(":entry")]
    return sorted(kept)


def verified_on(
    row: dict[str, Any],
) -> dt.date | None:
    """Return a registry row's ``last-verified`` date.

    Args:
        row: Registry row.

    Returns:
        The date, or None when missing or malformed.
    """
    value = row.get("last-verified")
    if isinstance(value, dt.date):
        return value
    try:
        return dt.date.fromisoformat(str(value))
    except ValueError:
        return None


def users_of(
    key: str,
    consumers: list[dict[str, Any]],
) -> list[str]:
    """List registry consumers that still use a deprecated item.

    Args:
        key: Removal key.
        consumers: Registry rows.

    Returns:
        Repository names.
    """
    entry_id = entry_of(key)
    whole = key.endswith(":entry")
    return [
        str(row.get("repository"))
        for row in consumers
        if key in (row.get("deprecated-in-use") or [])
        or (whole and entry_id in (row.get("uses") or []))
    ]


@dataclass
class Verdict:
    """Gate findings.

    Attributes:
        errors: Removals that fail the gate.
        notices: Informational lines.
    """

    errors: list[str] = field(default_factory=list)
    notices: list[str] = field(default_factory=list)


def judge_removal(
    verdict: Verdict,
    key: str,
    base: Snapshot,
    consumers: list[dict[str, Any]],
    stale: list[str],
) -> None:
    """Decide one removal that no exception covers.

    Args:
        verdict: Findings sink.
        key: Removal key.
        base: Snapshot at the base revision.
        consumers: Registry rows (work tree).
        stale: Consumers whose evidence is too old to rely on.
    """
    entry_id = entry_of(key)
    whole = catalog_lib.removal_key(entry_id=entry_id, kind=DeprecationKind.ENTRY)
    deprecated = key in base.deprecated or whole in base.deprecated
    tier = base.tiers.get(entry_id, "")
    if not deprecated:
        users = []
        for row in consumers:
            if entry_id in (row.get("uses") or []):
                users.append(str(row.get("repository")))
        if tier in (Tier.PREVIEW.value, Tier.INTERNAL.value):
            note = ""
            if users:
                note = f"; known consumers of `{entry_id}`: {', '.join(users)}"
            verdict.notices.append(
                f"{key}: removed from a {tier} entry without a deprecation{note}",
            )
            return
        verdict.errors.append(
            f"{key}: removed from a {tier} entry without a deprecation release; "
            "deprecate it first (a `deprecations` record and an inert shim that "
            "warns), or add an exception naming the approving issue",
        )
        return
    # Under a whole-entry deprecation the registry records only the entry
    # key, so any consumer still calling the entry blocks each of its items.
    lookup = whole if whole in base.deprecated else key
    users = users_of(key=lookup, consumers=consumers)
    if users:
        verdict.errors.append(
            f"{key}: still used by known consumer(s) {', '.join(users)}; migrate "
            "them first, or add an exception naming the approving issue",
        )
        return
    if stale:
        verdict.errors.append(
            f"{key}: consumer evidence is stale for {', '.join(stale)}; refresh "
            "with scripts/ci/catalog/check-deprecations.sh scan --write",
        )
        return
    verdict.notices.append(f"{key}: removal allowed; no known consumer uses it")


def judge_required(
    verdict: Verdict,
    key: str,
    base: Snapshot,
) -> None:
    """Decide one input that the change makes required.

    Args:
        verdict: Findings sink.
        key: ``<entry>:required:<input>``.
        base: Snapshot at the base revision.
    """
    tier = base.tiers.get(entry_of(key), "")
    if tier in (Tier.PREVIEW.value, Tier.INTERNAL.value):
        verdict.notices.append(f"{key}: input made required on a {tier} entry")
        return
    verdict.errors.append(
        f"{key}: a {tier} entry gains a required input, which fails every caller "
        "that does not pass it; give it a default, or add an exception naming "
        "the approving issue",
    )


def load_evidence(
    repo_root: Path,
    base_ref: str,
    max_age_days: int,
    today: dt.date,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Return the merged registry and the consumers whose evidence is stale.

    Args:
        repo_root: Repository root.
        base_ref: Base revision.
        max_age_days: Oldest ``last-verified`` a removal may rely on.
        today: Date the evidence age is measured from.

    Returns:
        ``(consumers, stale repositories)``.
    """
    consumers = merged_consumers(
        base=load_rows(
            repo_root=repo_root,
            relpath=catalog_lib.CONSUMERS_RELPATH,
            list_key="consumers",
            ref=base_ref,
        ),
        head=load_rows(
            repo_root=repo_root,
            relpath=catalog_lib.CONSUMERS_RELPATH,
            list_key="consumers",
        ),
    )
    cutoff = today - dt.timedelta(days=max_age_days)
    stale = []
    for row in consumers:
        verified = verified_on(row=row) or dt.date.min
        # A date in the future is as untrustworthy as an old one.
        if verified < cutoff or verified > today:
            stale.append(str(row.get("repository")))
    return consumers, stale


def tightened_keys(
    base: Snapshot,
    head: Snapshot,
) -> list[str]:
    """List inputs made required on entries that already existed at the base.

    Args:
        base: Snapshot at the base revision.
        head: Snapshot of the work tree.

    Returns:
        Sorted ``<entry>:required:<input>`` keys.
    """
    added = head.required - base.required
    return sorted(key for key in added if f"{entry_of(key)}:entry" in base.keys)


def gate(
    repo_root: Path,
    base_ref: str,
    max_age_days: int,
    today: dt.date,
) -> Verdict:
    """Check every removal between ``base_ref`` and the work tree.

    Args:
        repo_root: Repository root.
        base_ref: Revision the change is compared with.
        max_age_days: Oldest ``last-verified`` a removal may rely on.
        today: Date the evidence age is measured from.

    Returns:
        The findings.
    """
    verdict = Verdict()
    if git(repo_root, "cat-file", "-e", f"{base_ref}^{{commit}}").returncode != 0:
        verdict.errors.append(
            f"base ref `{base_ref}` is not a local commit; fetch it or pass --base-ref",
        )
        return verdict
    base = snapshot(repo_root=repo_root, ref=base_ref)
    head = snapshot(repo_root=repo_root, ref=None)
    if base is None:
        verdict.notices.append(f"no catalog at {base_ref}; nothing to gate")
        return verdict
    if head is None:
        verdict.errors.append(f"{catalog_lib.CATALOG_RELPATH} was deleted")
        return verdict
    consumers, stale = load_evidence(
        repo_root=repo_root,
        base_ref=base_ref,
        max_age_days=max_age_days,
        today=today,
    )
    exceptions = new_exceptions(repo_root=repo_root, base_ref=base_ref)
    removed = removed_keys(base=base, head=head)
    for key in tightened_keys(base=base, head=head):
        if key in exceptions:
            issue = exceptions[key].get("issue")
            verdict.notices.append(f"{key}: approved by exception (#{issue})")
            continue
        judge_required(verdict=verdict, key=key, base=base)
    for key in removed:
        if key in exceptions:
            issue = exceptions[key].get("issue")
            verdict.notices.append(f"{key}: removal approved by exception (#{issue})")
            continue
        judge_removal(
            verdict=verdict,
            key=key,
            base=base,
            consumers=consumers,
            stale=stale,
        )
    summary = f"{len(removed)} removal(s) against {base_ref}"
    verdict.notices.append(f"{summary}; {len(consumers)} known consumer(s)")
    return verdict


def new_exceptions(
    repo_root: Path,
    base_ref: str,
) -> dict[str, dict[str, Any]]:
    """Return the exceptions the change adds.

    Exceptions already on the base are the audit trail of earlier removals;
    counting them would silently approve the same key if it were re-added
    and removed again.

    Args:
        repo_root: Repository root.
        base_ref: Base revision.

    Returns:
        Removal key to exception row.
    """
    rows = {}
    for ref in (base_ref, None):
        rows[ref] = {
            str(row.get("removal")): row
            for row in load_rows(
                repo_root=repo_root,
                relpath=catalog_lib.EXCEPTIONS_RELPATH,
                list_key="exceptions",
                ref=ref,
            )
        }
    return {key: row for key, row in rows[None].items() if key not in rows[base_ref]}


def deprecation_report(
    repo_root: Path,
) -> list[str]:
    """Render, per deprecation record, the consumers that still use it.

    Args:
        repo_root: Repository root.

    Returns:
        Report lines.
    """
    catalog = catalog_lib.load_catalog(path=repo_root / catalog_lib.CATALOG_RELPATH)
    consumers = load_rows(
        repo_root=repo_root,
        relpath=catalog_lib.CONSUMERS_RELPATH,
        list_key="consumers",
    )
    lines = []
    for record in catalog.get("deprecations") or []:
        users: dict[str, list[str]] = {}
        for key in sorted(catalog_lib.deprecation_keys(record=record)):
            for repo in users_of(key=key, consumers=consumers):
                users.setdefault(repo, []).append(entry_of(key))
        state = "no known consumer" if not users else f"{len(users)} consumer(s)"
        lines.append(
            f"{record['id']} (#{record['issue']}, since {record['since']}): {state}",
        )
        for repo, found in sorted(users.items()):
            lines.append(f"  - {repo}: {', '.join(found)}")
    for row in consumers:
        pins = row.get("pins") or []
        floating = [p for p in pins if not re.fullmatch(r"[0-9a-f]{40}", p)]
        if floating:
            lines.append(
                f"floating pin(s) in {row.get('repository')}: {', '.join(floating)}",
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
    common = argparse.ArgumentParser(add_help=False)
    catalog_lib.add_repo_root_argument(parser=common)
    parser = argparse.ArgumentParser(description="Gate removals on consumer evidence.")
    commands = parser.add_subparsers(dest="command", required=True)
    gate_parser = commands.add_parser(
        "gate",
        parents=[common],
        help="Fail on ungated removals (CI; the default)",
    )
    gate_parser.add_argument(
        "--base-ref",
        default="origin/main",
        help="Revision the work tree is compared with (default: origin/main)",
    )
    gate_parser.add_argument(
        "--max-age-days",
        type=int,
        default=DEFAULT_MAX_AGE_DAYS,
        help="Oldest consumer evidence a removal may rely on",
    )
    commands.add_parser(
        "report",
        parents=[common],
        help="List the consumers still using each deprecation",
    )
    scan_parser = commands.add_parser(
        "scan",
        parents=[common],
        help="Refresh the registry from the consumers' default branches (needs gh)",
    )
    scan_parser.add_argument("--write", action="store_true", help="Store the rows")
    scan_parser.add_argument(
        "--repository",
        action="append",
        default=[],
        help="Scan only this owner/name (repeatable); adds it when new",
    )
    for sub in (gate_parser, scan_parser):
        sub.add_argument(
            "--today",
            type=dt.date.fromisoformat,
            default=None,
            help="Date to measure evidence from (default: today, UTC)",
        )
    if not any(arg in COMMANDS for arg in argv):
        argv = ["gate", *argv]
    return parser.parse_args(argv)


def main(
    argv: list[str],
) -> int:
    """Run a subcommand.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Process exit code.
    """
    args = parse_args(argv=argv)
    repo_root: Path = args.repo_root.resolve()
    today = getattr(args, "today", None) or dt.datetime.now(tz=dt.UTC).date()
    try:
        if args.command == "scan":
            status: int = consumer_scan.scan(
                repo_root=repo_root,
                repositories=args.repository,
                write=args.write,
                today=today,
            )
            for line in deprecation_report(repo_root=repo_root):
                print(line)
            return status
        if args.command == "report":
            for line in deprecation_report(repo_root=repo_root):
                print(line)
            return 0
        verdict = gate(
            repo_root=repo_root,
            base_ref=args.base_ref,
            max_age_days=args.max_age_days,
            today=today,
        )
    except (OSError, ValueError, KeyError, catalog_lib.yaml.YAMLError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for notice in verdict.notices:
        print(f"NOTICE: {notice}")
    if verdict.errors:
        for error in verdict.errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"ERROR: {len(verdict.errors)} ungated removal(s)", file=sys.stderr)
        return 1
    print("OK: every removal is covered by consumer evidence or an exception")
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
