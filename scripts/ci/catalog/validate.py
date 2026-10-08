#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate ``catalog/catalog.yml`` against the repository (#1079).

Checks, each reported with the entry it concerns:

1. Coverage: every ``.github/workflows/reusable-*.yml`` and
   ``.github/actions/*/action.yml`` has exactly one entry, and every entry
   names a file that exists. Entries are sorted by kind, then id.
2. Schema: known keys only, ``tier`` in stable|preview|internal|deprecated,
   ``reason`` on every non-stable entry, ``replacement`` on (and only on)
   deprecated entries, known package managers, one-line strings.
3. Permissions: a workflow's ``permissions`` equals the caller-facing union
   computed by ``scripts/ci/docs/validate-caller-permissions.py`` (the #735
   validator, reused rather than reimplemented). An action's covers any
   requirement that validator derives for it (``detect-changes``, #669).
4. Check names and runners: a workflow's ``check-names`` equal the job
   display names derived from its YAML (input defaults applied), so a rename
   shows up as a catalog diff; ``runners`` include every default runner.
5. Evidence: ``stable`` requires ``evidence`` with the fixture workflow, the
   40-character lgtm-ci commit the run was pinned to, and the run URL in the
   fixture repository. That commit must be an ancestor of both the default
   branch (``--main-ref``, default ``origin/main``) and ``HEAD``, so a
   squash-merged PR head never counts; shallow clones need
   ``git fetch --unshallow`` first (or ``--skip-ancestry`` for a structural
   check only). A stable entry whose file changed after its evidence commit
   gets a NOTICE: evidence is a point-in-time claim.
6. Generated docs: ``docs/catalog.md`` and the README index match
   ``scripts/ci/catalog/render.py`` output.

Usage:
    validate.py [--repo-root DIR] [--main-ref REF] [--skip-ancestry]
"""

# pylint: disable=invalid-name  # CLI script; the path is the contract

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# catalog_lib and render live next to this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_lib  # noqa: E402  # pylint: disable=wrong-import-position
import render  # noqa: E402  # pylint: disable=wrong-import-position
from catalog_lib import (  # noqa: E402  # pylint: disable=wrong-import-position
    Kind,
    Tier,
)

SCHEMA_VERSION = 1
CATALOG = str(catalog_lib.CATALOG_RELPATH)
TOP_LEVEL_KEYS = frozenset({"schema-version", "fixture-repository", "entries"})
REQUIRED_KEYS = frozenset(
    {
        "id",
        "kind",
        "tier",
        "permissions",
        "runners",
        "package-managers",
        "prerequisites",
        "limitations",
    },
)
OPTIONAL_KEYS = frozenset({"reason", "replacement", "evidence", "results"})
WORKFLOW_ONLY_KEYS = frozenset({"check-names"})
LIST_KEYS = (
    "runners",
    "package-managers",
    "prerequisites",
    "limitations",
    "check-names",
)
EVIDENCE_KEYS = frozenset({"fixture", "last-green", "run"})
PACKAGE_MANAGERS = frozenset({"bun", "bundler", "cargo", "npm", "pnpm", "uv"})
FIXTURE_FILE = re.compile(r"^[\w.-]+\.ya?ml$")
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[\w.-]+/[\w.-]+$")
REGENERATE = "regenerate with python3 scripts/ci/catalog/render.py --write"


@dataclass
class Report:
    """Accumulated validation findings.

    Attributes:
        errors: Messages that fail the run.
        notices: Informational messages.
    """

    errors: list[str] = field(default_factory=list)
    notices: list[str] = field(default_factory=list)

    def error(
        self,
        where: str,
        message: str,
    ) -> None:
        """Record a failure.

        Args:
            where: Entry id or file the message concerns.
            message: What is wrong.
        """
        self.errors.append(f"{where}: {message}")


def is_one_line(
    value: Any,
) -> bool:
    """Return whether a value is a non-empty single-line string.

    Args:
        value: Value to test.

    Returns:
        True for a non-blank string without newlines.
    """
    return isinstance(value, str) and bool(value.strip()) and "\n" not in value


def entry_keys(
    kind: Kind,
) -> tuple[frozenset[str], frozenset[str]]:
    """Return the required and allowed keys for an entry kind.

    Args:
        kind: Entry kind.

    Returns:
        ``(required, allowed)`` key sets.
    """
    extra = WORKFLOW_ONLY_KEYS if kind is Kind.REUSABLE_WORKFLOW else frozenset()
    required = REQUIRED_KEYS | extra
    return required, required | OPTIONAL_KEYS


def check_tier_rules(
    report: Report,
    entry: dict[str, Any],
    tier: Tier,
    ids: set[str],
) -> None:
    """Apply the ``reason`` and ``replacement`` rules of a tier.

    Args:
        report: Findings sink.
        entry: Catalog entry.
        tier: The entry's tier.
        ids: Every entry id in the catalog.
    """
    where = str(entry["id"])
    if tier is Tier.STABLE and "reason" in entry:
        report.error(
            where,
            "`reason` is for non-stable entries; stable is explained by its evidence",
        )
    if tier is not Tier.STABLE and not is_one_line(entry.get("reason")):
        report.error(where, f"tier `{tier.value}` requires a one-line `reason`")
    if tier is Tier.DEPRECATED:
        replacement = entry.get("replacement")
        if replacement not in ids or replacement == where:
            report.error(
                where,
                "deprecated entries need a `replacement` naming another entry",
            )
    elif "replacement" in entry:
        report.error(where, "`replacement` is only valid on deprecated entries")


def check_field_types(
    report: Report,
    entry: dict[str, Any],
    tier: Tier,
) -> None:
    """Check the type of every list and mapping field.

    Args:
        report: Findings sink.
        entry: Catalog entry.
        tier: The entry's tier.
    """
    where = str(entry["id"])
    if "results" in entry and not is_one_line(entry["results"]):
        report.error(where, "`results` must be a one-line string")
    if not isinstance(entry.get("permissions"), dict):
        report.error(where, "`permissions` must be a mapping of scope to read|write")
    for key in LIST_KEYS:
        value = entry.get(key, [])
        if not isinstance(value, list) or not all(is_one_line(v) for v in value):
            report.error(where, f"`{key}` must be a list of one-line strings")
    managers = entry.get("package-managers")
    known = ", ".join(sorted(PACKAGE_MANAGERS))
    for manager in managers if isinstance(managers, list) else []:
        if manager not in PACKAGE_MANAGERS:
            report.error(where, f"unknown package manager `{manager}` (known: {known})")
    if tier is Tier.STABLE and not entry.get("runners"):
        report.error(where, "stable entries must list the runners they are proven on")


def check_schema(
    report: Report,
    entry: dict[str, Any],
    ids: set[str],
) -> bool:
    """Validate an entry's shape and tier rules.

    Args:
        report: Findings sink.
        entry: Catalog entry.
        ids: Every entry id in the catalog (for ``replacement``).

    Returns:
        False when the entry has schema errors; the repository checks then
        skip it rather than fail on missing fields.
    """
    where = str(entry.get("id", "<entry without id>"))
    before = len(report.errors)
    try:
        kind = Kind(entry.get("kind"))
        tier = Tier(entry.get("tier"))
    except ValueError:
        kinds = ", ".join(k.value for k in Kind)
        tiers = ", ".join(t.value for t in Tier)
        report.error(where, f"`kind` must be one of {kinds} and `tier` one of {tiers}")
        return False
    required, allowed = entry_keys(kind=kind)
    for key in sorted(set(entry) - allowed):
        report.error(where, f"unknown key `{key}` for a {kind.value}")
    for key in sorted(required - set(entry)):
        report.error(where, f"missing required key `{key}`")
    if len(report.errors) > before:
        return False
    check_tier_rules(report=report, entry=entry, tier=tier, ids=ids)
    check_field_types(report=report, entry=entry, tier=tier)
    return len(report.errors) == before


def check_permissions(
    report: Report,
    entry: dict[str, Any],
    workflows_dir: Path,
    validator: Any,
) -> None:
    """Compare an entry's permissions with what the repository declares.

    Args:
        report: Findings sink.
        entry: Catalog entry (schema-checked).
        workflows_dir: ``.github/workflows`` of the checkout.
        validator: The loaded caller-permissions validator module.
    """
    where = entry["id"]
    declared: dict[str, str] = entry["permissions"]
    invalid = [
        f"{scope}: {level}"
        for scope, level in sorted(declared.items())
        if scope not in validator.ALL_SCOPES or level not in ("read", "write")
    ]
    for pair in invalid:
        report.error(where, f"invalid permission `{pair}`")
    if invalid:
        # Comparing against the union would only repeat the same mistake.
        return
    if Kind(entry["kind"]) is Kind.REUSABLE_WORKFLOW:
        check_workflow_union(
            report=report,
            where=where,
            declared=declared,
            workflows_dir=workflows_dir,
            validator=validator,
        )
        return
    needed: dict[str, str] = validator.ACTION_REQUIREMENTS.get(where, {})
    rank = validator.LEVEL_RANK
    for scope, level in sorted(needed.items()):
        if rank.get(declared.get(scope, "none"), 0) < rank[level]:
            report.error(
                where,
                f"`permissions` must include `{scope}: {level}` (derived)",
            )


def check_workflow_union(
    report: Report,
    where: str,
    declared: dict[str, str],
    workflows_dir: Path,
    validator: Any,
) -> None:
    """Require a workflow entry's permissions to equal its caller union.

    Args:
        report: Findings sink.
        where: Entry id (the workflow file stem).
        declared: The entry's permissions.
        workflows_dir: ``.github/workflows`` of the checkout.
        validator: The loaded caller-permissions validator module.
    """
    try:
        union = validator.workflow_union(
            name=f"{where}.yml",
            workflows_dir=workflows_dir,
        )
    except ValueError as exc:
        report.error(where, f"cannot compute the permission union ({exc})")
        return
    if union != declared:
        expected = validator.format_scopes(union or {})
        actual = validator.format_scopes(declared)
        report.error(
            where,
            f"`permissions` must equal the workflow's caller union "
            f"{{{expected}}}; catalog has {{{actual}}}",
        )


def check_workflow_facts(
    report: Report,
    entry: dict[str, Any],
    workflows_dir: Path,
) -> None:
    """Compare check names and runners with the workflow's YAML.

    Args:
        report: Findings sink.
        entry: Reusable-workflow entry (schema-checked).
        workflows_dir: ``.github/workflows`` of the checkout.
    """
    where = entry["id"]
    try:
        facts = catalog_lib.workflow_facts(
            workflows_dir=workflows_dir,
            name=f"{where}.yml",
        )
    except (OSError, ValueError, catalog_lib.yaml.YAMLError) as exc:
        report.error(where, f"cannot derive check names ({exc})")
        return
    if list(facts.check_names) != entry["check-names"]:
        derived = ", ".join(repr(name) for name in facts.check_names)
        report.error(
            where,
            f"`check-names` must match the workflow's job names ({derived}); a "
            "rename changes required-check names, so update the catalog with it",
        )
    missing = ", ".join(sorted(set(facts.runners) - set(entry["runners"])))
    if missing:
        report.error(where, f"`runners` must include the default runner(s) {missing}")


@dataclass(frozen=True)
class History:
    """Git history the evidence rules are checked against.

    Attributes:
        repo_root: Git work tree.
        main_ref: Ref of the default branch evidence must be on.
        skip: Do not consult git at all (structural check only).
    """

    repo_root: Path
    main_ref: str
    skip: bool

    def git(
        self,
        *args: str,
    ) -> subprocess.CompletedProcess[str]:
        """Run a read-only git command in the work tree.

        Args:
            *args: Git arguments.

        Returns:
            The completed process (never raises on a non-zero exit).
        """
        return subprocess.run(
            ["git", "-C", str(self.repo_root), *args],
            capture_output=True,
            check=False,
            text=True,
        )

    def has_commit(
        self,
        rev: str,
    ) -> bool:
        """Return whether ``rev`` names a commit in the local history.

        Args:
            rev: Commit SHA or ref.

        Returns:
            True when git can resolve it to a commit.
        """
        return self.git("cat-file", "-e", f"{rev}^{{commit}}").returncode == 0

    def is_ancestor(
        self,
        commit: str,
        rev: str,
    ) -> bool:
        """Return whether ``commit`` is an ancestor of (or equal to) ``rev``.

        Args:
            commit: Full commit SHA.
            rev: Descendant candidate.

        Returns:
            True when ``commit`` is in ``rev``'s history.

        Raises:
            RuntimeError: When git cannot answer (exit status other than 0
                or 1), for example a history cut short by a shallow fetch.
        """
        result = self.git("merge-base", "--is-ancestor", commit, rev)
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr.strip() or f"exit {result.returncode}")
        return result.returncode == 0

    def changes_since(
        self,
        commit: str,
        path: Path,
    ) -> list[str]:
        """List commits after ``commit`` on ``HEAD`` that touched ``path``.

        Args:
            commit: Evidence commit.
            path: Repository-relative file.

        Returns:
            Short SHAs, newest first.
        """
        log = self.git("log", "--format=%h", f"{commit}..HEAD", "--", path.as_posix())
        return log.stdout.split() if log.returncode == 0 else []


def check_ancestry(
    report: Report,
    entry: dict[str, Any],
    commit: str,
    history: History,
) -> None:
    """Require an evidence commit on the default branch and in ``HEAD``.

    A PR head that was squash-merged is an ancestor of the PR branch but not
    of the default branch, so it would turn red the moment the PR lands.

    Args:
        report: Findings sink.
        entry: Catalog entry with evidence.
        commit: Full evidence commit SHA.
        history: Git history to check against.
    """
    where = entry["id"]
    if not history.has_commit(rev=history.main_ref):
        report.error(
            where,
            f"cannot check evidence: `{history.main_ref}` is not a local commit; "
            "fetch it or pass --main-ref / --skip-ancestry",
        )
        return
    if not history.has_commit(rev=commit):
        report.error(
            where,
            f"evidence commit {commit[:12]} is not in the local history; fetch it "
            "(git fetch --unshallow origin) or pass --skip-ancestry",
        )
        return
    for rev in (history.main_ref, "HEAD"):
        try:
            ancestor = history.is_ancestor(commit=commit, rev=rev)
        except RuntimeError as exc:
            report.error(where, f"git cannot compare {commit[:12]} with {rev} ({exc})")
            return
        if not ancestor:
            report.error(
                where,
                f"evidence commit {commit[:12]} is not an ancestor of {rev}; "
                "evidence must come from a commit on the default branch",
            )
            return
    path = catalog_lib.entry_path(kind=Kind(entry["kind"]), entry_id=where)
    newer = history.changes_since(commit=commit, path=path)
    if newer:
        report.notices.append(
            f"{where}: evidence at {commit[:8]} predates {len(newer)} change(s) to "
            f"{path} ({', '.join(newer[:3])}); re-run the fixture and refresh it",
        )


def check_evidence(
    report: Report,
    entry: dict[str, Any],
    fixture_repository: str,
    history: History,
) -> None:
    """Validate an entry's evidence block.

    Args:
        report: Findings sink.
        entry: Catalog entry (schema-checked).
        fixture_repository: ``owner/name`` of the fixture.
        history: Git history to check ancestry against.
    """
    where = entry["id"]
    evidence = entry.get("evidence")
    if evidence is None:
        if Tier(entry["tier"]) is Tier.STABLE:
            report.error(
                where,
                "tier `stable` requires `evidence` (fixture, last-green, run)",
            )
        return
    if not isinstance(evidence, dict) or set(evidence) != EVIDENCE_KEYS:
        report.error(
            where,
            "`evidence` must have exactly `fixture`, `last-green` and `run`",
        )
        return
    if not FIXTURE_FILE.fullmatch(str(evidence["fixture"])):
        report.error(where, "`evidence.fixture` must be a workflow file name")
    runs = f"https://github.com/{fixture_repository}/actions/runs/"
    if not re.fullmatch(rf"{re.escape(runs)}\d+", str(evidence["run"])):
        report.error(where, f"`evidence.run` must be {runs}<id>")
    commit = str(evidence["last-green"])
    if not FULL_SHA.fullmatch(commit):
        report.error(
            where,
            "`evidence.last-green` must be a full 40-character lgtm-ci commit SHA",
        )
        return
    if not history.skip:
        check_ancestry(report=report, entry=entry, commit=commit, history=history)


def check_coverage(
    report: Report,
    entries: list[dict[str, Any]],
    repo_root: Path,
) -> None:
    """Require exactly one entry per entry point, in sorted order.

    Args:
        report: Findings sink.
        entries: Catalog entries.
        repo_root: Repository root.
    """
    points = catalog_lib.discover_entry_points(repo_root=repo_root)
    expected = {(ep.kind.value, ep.id) for ep in points}
    seen: dict[tuple[str, str], int] = {}
    for entry in entries:
        key = (str(entry.get("kind")), str(entry.get("id")))
        seen[key] = seen.get(key, 0) + 1
    for kind, entry_id in sorted(expected - set(seen)):
        path = catalog_lib.entry_path(kind=Kind(kind), entry_id=entry_id)
        report.error(entry_id, f"{path} has no catalog entry")
    for kind, entry_id in sorted(set(seen) - expected):
        report.error(entry_id, f"no {kind} file for this entry")
    for (_kind, entry_id), count in sorted(seen.items()):
        if count > 1:
            report.error(entry_id, f"listed {count} times; list each entry point once")
    check_spellings(report=report, repo_root=repo_root)
    check_order(report=report, entries=entries)


def check_spellings(
    report: Report,
    repo_root: Path,
) -> None:
    """Reject ``.yaml`` entry points, which discovery would otherwise skip.

    Args:
        report: Findings sink.
        repo_root: Repository root.
    """
    workflows = repo_root / catalog_lib.WORKFLOWS_RELDIR
    actions = repo_root / catalog_lib.ACTIONS_RELDIR
    odd = [*workflows.glob("reusable-*.yaml"), *actions.glob("*/action.yaml")]
    for path in sorted(odd):
        report.error(
            str(path.relative_to(repo_root)),
            "use the .yml spelling; the catalog only covers .yml",
        )


def check_order(
    report: Report,
    entries: list[dict[str, Any]],
) -> None:
    """Require entries sorted by kind (workflows first), then id.

    Args:
        report: Findings sink.
        entries: Catalog entries.
    """
    rank = {kind.value: index for index, kind in enumerate(Kind)}
    keys = []
    for entry in entries:
        kind_rank = rank.get(str(entry.get("kind")), len(rank))
        keys.append((kind_rank, str(entry.get("id"))))
    if keys != sorted(keys):
        report.error("entries", "must be sorted by kind (workflows first), then id")


def check_top_level(
    report: Report,
    catalog: dict[str, Any],
) -> tuple[str, list[dict[str, Any]]] | None:
    """Validate the catalog's top-level keys.

    Args:
        report: Findings sink.
        catalog: Parsed catalog.

    Returns:
        ``(fixture_repository, entries)``, or None when unusable.
    """
    for key in sorted(set(catalog) - TOP_LEVEL_KEYS):
        report.error(CATALOG, f"unknown top-level key `{key}`")
    if catalog.get("schema-version") != SCHEMA_VERSION:
        report.error(CATALOG, f"`schema-version` must be {SCHEMA_VERSION}")
    fixture_repository = catalog.get("fixture-repository")
    entries = catalog.get("entries")
    if not isinstance(fixture_repository, str) or not REPOSITORY.fullmatch(
        fixture_repository,
    ):
        report.error(CATALOG, "`fixture-repository` must be owner/name")
        return None
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        report.error(CATALOG, "`entries` must be a list of mappings")
        return None
    return fixture_repository, entries


def validate(
    repo_root: Path,
    history: History,
) -> Report:
    """Run every check.

    Args:
        repo_root: Repository root.
        history: Git history evidence commits are checked against.

    Returns:
        The findings.
    """
    report = Report()
    try:
        catalog = catalog_lib.load_catalog(path=repo_root / catalog_lib.CATALOG_RELPATH)
    except (OSError, ValueError, catalog_lib.yaml.YAMLError) as exc:
        report.error(CATALOG, f"unreadable ({exc})")
        return report
    top = check_top_level(report=report, catalog=catalog)
    if top is None:
        return report
    fixture_repository, entries = top
    check_coverage(report=report, entries=entries, repo_root=repo_root)
    check_entries(
        report=report,
        entries=entries,
        fixture_repository=fixture_repository,
        repo_root=repo_root,
        history=history,
    )
    if report.errors:
        report.notices.append("generated docs not compared: fix the catalog first")
        return report
    check_generated(report=report, repo_root=repo_root)
    counts = ", ".join(
        f"{sum(e['tier'] == tier.value for e in entries)} {tier.value}" for tier in Tier
    )
    report.notices.append(f"{len(entries)} entries: {counts}")
    return report


def check_entries(
    report: Report,
    entries: list[dict[str, Any]],
    fixture_repository: str,
    repo_root: Path,
    history: History,
) -> None:
    """Run the per-entry schema and repository checks.

    Args:
        report: Findings sink.
        entries: Catalog entries.
        fixture_repository: ``owner/name`` of the fixture.
        repo_root: Repository root.
        history: Git history evidence commits are checked against.
    """
    # The union logic is tooling from this checkout; --repo-root only
    # selects the data (workflows, actions, catalog) it is applied to.
    validator = catalog_lib.load_permissions_validator()
    workflows_dir = repo_root / catalog_lib.WORKFLOWS_RELDIR
    ids = {str(e.get("id")) for e in entries}
    discovered = catalog_lib.discover_entry_points(repo_root=repo_root)
    points = {(ep.kind.value, ep.id) for ep in discovered}
    for entry in entries:
        valid = check_schema(report=report, entry=entry, ids=ids)
        if not valid or (entry["kind"], entry["id"]) not in points:
            continue
        check_permissions(
            report=report,
            entry=entry,
            workflows_dir=workflows_dir,
            validator=validator,
        )
        if Kind(entry["kind"]) is Kind.REUSABLE_WORKFLOW:
            check_workflow_facts(
                report=report,
                entry=entry,
                workflows_dir=workflows_dir,
            )
        check_evidence(
            report=report,
            entry=entry,
            fixture_repository=fixture_repository,
            history=history,
        )


def check_generated(
    report: Report,
    repo_root: Path,
) -> None:
    """Require docs/catalog.md and the README index to match the catalog.

    Args:
        report: Findings sink.
        repo_root: Repository root.
    """
    try:
        stale = render.stale_outputs(repo_root=repo_root)
    except (OSError, ValueError, KeyError, catalog_lib.yaml.YAMLError) as exc:
        report.error("generated docs", f"cannot render ({exc})")
        return
    for path in stale:
        report.error(str(path), f"out of date with the catalog; {REGENERATE}")


def parse_args(
    argv: list[str],
) -> argparse.Namespace:
    """Parse CLI arguments.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Parsed arguments.
    """
    parser = argparse.ArgumentParser(description="Validate catalog/catalog.yml.")
    catalog_lib.add_repo_root_argument(parser=parser)
    parser.add_argument(
        "--skip-ancestry",
        action="store_true",
        help="Do not check evidence commits against git history",
    )
    parser.add_argument(
        "--main-ref",
        default="origin/main",
        help="Default-branch ref evidence must be on (default: origin/main)",
    )
    return parser.parse_args(argv)


def main(
    argv: list[str],
) -> int:
    """Run the validator.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Process exit code: 0 when the catalog is consistent.
    """
    args = parse_args(argv=argv)
    repo_root: Path = args.repo_root.resolve()
    history = History(
        repo_root=repo_root,
        main_ref=args.main_ref,
        skip=args.skip_ancestry,
    )
    report = validate(repo_root=repo_root, history=history)
    if args.skip_ancestry:
        print("NOTICE: --skip-ancestry: evidence commits were not checked against git")
    for notice in report.notices:
        print(f"NOTICE: {notice}")
    if report.errors:
        for error in report.errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"ERROR: {len(report.errors)} catalog problem(s)", file=sys.stderr)
        return 1
    print("OK: catalog/catalog.yml is consistent with the repository")
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
