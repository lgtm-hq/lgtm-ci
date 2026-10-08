#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Gate removals on known-consumer migration evidence (#1082).

Three subcommands, all driven by ``catalog/catalog.yml`` (its
``deprecations`` records), ``catalog/consumers.yml`` (the known-consumer
registry) and ``catalog/deprecation-exceptions.yml``:

``scan``
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
    work tree and list every input, output and entry point the change
    removes. A removal fails unless an exception names it, or:

    * it was deprecated at the base (a ``deprecations`` record covered it),
      no registry consumer still uses it, and every consumer row was
      verified within ``--max-age-days``; time since the deprecation never
      counts; or
    * its entry was ``preview`` or ``internal`` and the item was never
      deprecated: those tiers may change without a migration (a NOTICE lists
      registry consumers of the entry). Removing a never-deprecated item
      from a ``stable`` or ``deprecated`` entry always fails.

Usage:
    deprecations.py gate [--base-ref REF] [--max-age-days N] [--today DATE]
    deprecations.py report
    deprecations.py scan [--write] [--repository OWNER/NAME ...] [--today DATE]
"""

# pylint: disable=invalid-name  # CLI script; the path is the contract

from __future__ import annotations

import argparse
import datetime as dt
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# catalog_lib lives next to this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_lib  # noqa: E402  # pylint: disable=wrong-import-position
from catalog_lib import (  # noqa: E402  # pylint: disable=wrong-import-position
    DeprecationKind,
    Kind,
    Tier,
)

LGTM_CI_USES = re.compile(
    r"^lgtm-hq/lgtm-ci/\.github/(?:workflows/(?P<workflow>[\w.-]+)\.ya?ml"
    r"|actions/(?P<action>[\w.-]+))@(?P<ref>\S+)$",
)
WORKFLOW_FILE = re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")
ACTION_FILE = re.compile(r"(?:^|/)action\.ya?ml$")
DEFAULT_MAX_AGE_DAYS = 14
COMMANDS = frozenset({"gate", "report", "scan"})
REGISTRY_HEADER_END = "---\n"


@dataclass
class Usage:
    """What one consumer repository uses from lgtm-ci.

    Attributes:
        pins: Refs after ``@`` in its lgtm-ci ``uses:`` lines.
        entries: Catalog entry ids it calls.
        keys: Removal keys it uses: entries, inputs passed, outputs read.
    """

    pins: set[str] = field(default_factory=set)
    entries: set[str] = field(default_factory=set)
    keys: set[str] = field(default_factory=set)


@dataclass(frozen=True)
class Snapshot:
    """The catalog and entry-point interfaces at one revision.

    Attributes:
        tiers: Entry id to tier.
        keys: Every removal key the entry points expose.
        deprecated: Removal keys covered by a deprecation record.
    """

    tiers: dict[str, str]
    keys: set[str]
    deprecated: set[str]


def git(
    repo_root: Path,
    *args: str,
) -> subprocess.CompletedProcess[str]:
    """Run a read-only git command.

    Args:
        repo_root: Work tree.
        *args: Git arguments.

    Returns:
        The completed process (never raises on a non-zero exit).
    """
    return subprocess.run(
        ["git", "-C", str(repo_root), *args],
        capture_output=True,
        check=False,
        text=True,
    )


def read_at(
    repo_root: Path,
    ref: str | None,
    relpath: Path,
) -> str | None:
    """Read a file from the work tree or from a git revision.

    Args:
        repo_root: Repository root.
        ref: Revision, or None for the work tree.
        relpath: Repository-relative path.

    Returns:
        File text, or None when it does not exist there.
    """
    if ref is None:
        path = repo_root / relpath
        return path.read_text(encoding="utf-8") if path.is_file() else None
    shown = git(repo_root, "show", f"{ref}:{relpath.as_posix()}")
    return shown.stdout if shown.returncode == 0 else None


def snapshot(
    repo_root: Path,
    ref: str | None,
) -> Snapshot | None:
    """Load the catalog and every entry point's interface at a revision.

    Args:
        repo_root: Repository root.
        ref: Revision, or None for the work tree.

    Returns:
        The snapshot, or None when the revision has no catalog.

    Raises:
        ValueError: When the catalog is not a mapping with an entry list.
    """
    text = read_at(repo_root=repo_root, ref=ref, relpath=catalog_lib.CATALOG_RELPATH)
    if text is None:
        return None
    catalog = catalog_lib.yaml.safe_load(text)
    entries = catalog.get("entries") if isinstance(catalog, dict) else None
    if not isinstance(entries, list):
        raise ValueError(f"{catalog_lib.CATALOG_RELPATH} at {ref or 'work tree'}")
    tiers: dict[str, str] = {}
    keys: set[str] = set()
    for entry in entries:
        entry_id = str(entry["id"])
        kind = Kind(entry["kind"])
        tiers[entry_id] = str(entry["tier"])
        source = read_at(
            repo_root=repo_root,
            ref=ref,
            relpath=catalog_lib.entry_path(kind=kind, entry_id=entry_id),
        )
        if source is None:
            # A deleted file is a removal even while its catalog row lingers.
            continue
        document = catalog_lib.yaml.safe_load(source)
        surface = catalog_lib.interface(kind=kind, document=document)
        keys |= catalog_lib.removal_keys(entry_id=entry_id, surface=surface)
    deprecated: set[str] = set()
    for record in catalog.get("deprecations") or []:
        deprecated |= catalog_lib.deprecation_keys(record=record)
    return Snapshot(tiers=tiers, keys=keys, deprecated=deprecated)


def load_rows(
    repo_root: Path,
    relpath: Path,
    list_key: str,
) -> list[dict[str, Any]]:
    """Load the list from the registry or the exceptions file.

    Args:
        repo_root: Repository root.
        relpath: File to read.
        list_key: Top-level key holding the list.

    Returns:
        The rows; empty when the file or the key is missing.
    """
    path = repo_root / relpath
    if not path.is_file():
        return []
    rows = catalog_lib.load_catalog(path=path).get(list_key)
    return rows if isinstance(rows, list) else []


def entry_of(
    key: str,
) -> str:
    """Return the entry id a removal key belongs to.

    Args:
        key: Removal key.

    Returns:
        The part before the first colon.
    """
    return key.split(":", maxsplit=1)[0]


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
    users = users_of(key=key, consumers=consumers)
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
    if base is None or head is None:
        verdict.notices.append(
            "no catalog at one side of the comparison; nothing to gate",
        )
        return verdict
    consumers = load_rows(
        repo_root=repo_root,
        relpath=catalog_lib.CONSUMERS_RELPATH,
        list_key="consumers",
    )
    exceptions = {
        str(row.get("removal")): row
        for row in load_rows(
            repo_root=repo_root,
            relpath=catalog_lib.EXCEPTIONS_RELPATH,
            list_key="exceptions",
        )
    }
    cutoff = today - dt.timedelta(days=max_age_days)
    stale = [
        str(row.get("repository"))
        for row in consumers
        if (verified_on(row=row) or dt.date.min) < cutoff
    ]
    removed = removed_keys(base=base, head=head)
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


def gh(
    *args: str,
) -> str:
    """Run a read-only ``gh`` command.

    Args:
        *args: ``gh`` arguments.

    Returns:
        Standard output.

    Raises:
        RuntimeError: When ``gh`` exits non-zero.
    """
    result = subprocess.run(["gh", *args], capture_output=True, check=False, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"gh exit {result.returncode}")
    return result.stdout


def consumer_files(
    repository: str,
) -> dict[str, str]:
    """Fetch a repository's workflow and composite action files.

    Args:
        repository: ``owner/name``.

    Returns:
        Path to file text on the default branch.
    """
    branch = gh("api", f"repos/{repository}", "--jq", ".default_branch").strip()
    listing = gh(
        "api",
        f"repos/{repository}/git/trees/{branch}?recursive=1",
        "--jq",
        '.tree[] | select(.type == "blob") | .path',
    )
    paths = [
        path
        for path in listing.splitlines()
        if WORKFLOW_FILE.search(path) or ACTION_FILE.search(path)
    ]
    return {
        path: gh(
            "api",
            "-H",
            "Accept: application/vnd.github.raw",
            f"repos/{repository}/contents/{path}?ref={branch}",
        )
        for path in paths
    }


def record_call(
    usage: Usage,
    uses: str,
    passed: Any,
    reads: list[str],
) -> None:
    """Record one ``uses:`` of an lgtm-ci entry point.

    Args:
        usage: Accumulator for the repository.
        uses: The ``uses:`` value.
        passed: The ``with:`` mapping.
        reads: Output names the file reads from this call.
    """
    match = LGTM_CI_USES.match(uses.strip())
    if match is None:
        return
    entry_id = match.group("workflow") or match.group("action")
    usage.pins.add(match.group("ref"))
    usage.entries.add(entry_id)
    usage.keys.add(
        catalog_lib.removal_key(entry_id=entry_id, kind=DeprecationKind.ENTRY),
    )
    for name in passed if isinstance(passed, dict) else {}:
        usage.keys.add(
            catalog_lib.removal_key(
                entry_id=entry_id,
                kind=DeprecationKind.INPUT,
                name=str(name),
            ),
        )
    for name in reads:
        usage.keys.add(
            catalog_lib.removal_key(
                entry_id=entry_id,
                kind=DeprecationKind.OUTPUT,
                name=name,
            ),
        )


def outputs_read(
    text: str,
    context: str,
    ident: Any,
) -> list[str]:
    """List output names a file reads from a job or step.

    Args:
        text: File text.
        context: ``needs`` for a job, ``steps`` for a step.
        ident: Job or step id; None when the step has no id.

    Returns:
        Output names.
    """
    if not ident:
        return []
    pattern = rf"\b{context}\.{re.escape(str(ident))}\.outputs\.([\w-]+)"
    return sorted(set(re.findall(pattern, text)))


def scan_steps(
    usage: Usage,
    steps: Any,
    text: str,
) -> None:
    """Record the lgtm-ci actions a list of steps calls.

    Args:
        usage: Accumulator for the repository.
        steps: A ``steps:`` list.
        text: Text of the file holding the steps.
    """
    for step in steps if isinstance(steps, list) else []:
        if isinstance(step, dict) and isinstance(step.get("uses"), str):
            record_call(
                usage=usage,
                uses=step["uses"],
                passed=step.get("with"),
                reads=outputs_read(text=text, context="steps", ident=step.get("id")),
            )


def scan_file(
    usage: Usage,
    path: str,
    text: str,
) -> None:
    """Record the lgtm-ci calls in one workflow or action file.

    Args:
        usage: Accumulator for the repository.
        path: Repository-relative path.
        text: File text.
    """
    try:
        document = catalog_lib.yaml.safe_load(text)
    except catalog_lib.yaml.YAMLError:
        return
    if not isinstance(document, dict):
        return
    if ACTION_FILE.search(path):
        runs = document.get("runs")
        scan_steps(usage=usage, steps=(runs or {}).get("steps"), text=text)
        return
    jobs = document.get("jobs")
    for job_id, job in (jobs.items() if isinstance(jobs, dict) else []):
        if not isinstance(job, dict):
            continue
        if isinstance(job.get("uses"), str):
            record_call(
                usage=usage,
                uses=job["uses"],
                passed=job.get("with"),
                reads=outputs_read(text=text, context="needs", ident=job_id),
            )
        scan_steps(usage=usage, steps=job.get("steps"), text=text)


def scan_repository(
    repository: str,
) -> Usage:
    """Scan one consumer's default branch.

    Args:
        repository: ``owner/name``.

    Returns:
        What it uses from lgtm-ci.
    """
    usage = Usage()
    for path, text in sorted(consumer_files(repository=repository).items()):
        scan_file(usage=usage, path=path, text=text)
    return usage


def refreshed_row(
    row: dict[str, Any],
    usage: Usage,
    deprecated: set[str],
    today: dt.date,
) -> dict[str, Any]:
    """Return a registry row rebuilt from a scan.

    Args:
        row: Current row (keeps its repository and tracking issues).
        usage: Scan result.
        deprecated: Removal keys the catalog deprecates.
        today: Verification date.

    Returns:
        The new row.
    """
    return {
        "repository": row["repository"],
        "tracking-issues": list(row.get("tracking-issues") or []),
        "last-verified": today.isoformat(),
        "pins": sorted(usage.pins),
        "uses": sorted(usage.entries),
        "deprecated-in-use": sorted(usage.keys & deprecated),
    }


def flow_list(
    values: list[Any],
) -> str:
    """Render a short YAML flow list.

    Args:
        values: Scalars.

    Returns:
        ``[a, b]``.
    """
    return "[" + ", ".join(str(v) for v in values) + "]"


def write_registry(
    repo_root: Path,
    rows: list[dict[str, Any]],
) -> None:
    """Rewrite the registry rows, keeping the file's header comment.

    Args:
        repo_root: Repository root.
        rows: Rows sorted by repository.
    """
    path = repo_root / catalog_lib.CONSUMERS_RELPATH
    text = path.read_text(encoding="utf-8")
    header = text[: text.index(REGISTRY_HEADER_END) + len(REGISTRY_HEADER_END)]
    lines = [header.rstrip("\n"), "schema-version: 1", "consumers:"]
    for row in rows:
        lines += [
            f"  - repository: {row['repository']}",
            f"    tracking-issues: {flow_list(row['tracking-issues'])}",
            f'    last-verified: "{row["last-verified"]}"',
        ]
        for key in ("pins", "uses", "deprecated-in-use"):
            if not row[key]:
                lines.append(f"    {key}: []")
                continue
            lines.append(f"    {key}:")
            lines += [f'      - "{value}"' for value in row[key]]
        lines.append("")
    if not rows:
        lines[-1] = "consumers: []"
    path.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")


def scan(
    repo_root: Path,
    repositories: list[str],
    write: bool,
    today: dt.date,
) -> int:
    """Refresh registry rows from the consumers' default branches.

    Args:
        repo_root: Repository root.
        repositories: Limit to these rows; empty scans every row.
        write: Store the refreshed rows.
        today: Verification date.

    Returns:
        Process exit code: 1 when a repository could not be read.
    """
    rows = load_rows(
        repo_root=repo_root,
        relpath=catalog_lib.CONSUMERS_RELPATH,
        list_key="consumers",
    )
    known = {str(row.get("repository")) for row in rows}
    for repository in repositories:
        if repository not in known:
            rows.append({"repository": repository, "tracking-issues": []})
    rows.sort(key=lambda row: str(row["repository"]).lower())
    head = snapshot(repo_root=repo_root, ref=None)
    deprecated = head.deprecated if head else set()
    failed = 0
    refreshed = []
    for row in rows:
        repository = str(row["repository"])
        if repositories and repository not in repositories:
            refreshed.append(row)
            continue
        try:
            usage = scan_repository(repository=repository)
        except RuntimeError as exc:
            print(f"ERROR: {repository}: cannot read ({exc})", file=sys.stderr)
            failed += 1
            refreshed.append(row)
            continue
        new = refreshed_row(row=row, usage=usage, deprecated=deprecated, today=today)
        print(
            f"{repository}: {len(new['uses'])} entr(y/ies), "
            f"pins {flow_list(new['pins'])}, "
            f"deprecated in use {flow_list(new['deprecated-in-use'])}",
        )
        refreshed.append(new)
    if write:
        write_registry(repo_root=repo_root, rows=refreshed)
        print(f"wrote {catalog_lib.CONSUMERS_RELPATH}")
    for line in deprecation_report(repo_root=repo_root):
        print(line)
    return 1 if failed else 0


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
            return scan(
                repo_root=repo_root,
                repositories=args.repository,
                write=args.write,
                today=today,
            )
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
