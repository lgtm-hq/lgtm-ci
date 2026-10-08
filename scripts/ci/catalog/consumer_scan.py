#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read the known consumers' lgtm-ci usage for the registry (#1082).

``deprecations.py scan`` drives this module: for every repository in
``catalog/consumers.yml`` it reads the default branch with ``gh`` (workflow
files and composite ``action.yml`` files), finds each
``lgtm-hq/lgtm-ci/...@<ref>`` call and rebuilds the row: the refs it pins,
the entries it calls and the deprecated (or already removed) items it still
uses: inputs it passes, outputs it reads, secrets it passes and deprecated
entry points it calls. Needs a token that can read the consumers.
"""

# pylint: disable=invalid-name  # module name mirrors its CLI siblings

from __future__ import annotations

import datetime as dt
import json
import re
import subprocess
import sys
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# catalog_lib lives next to this module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_lib  # noqa: E402  # pylint: disable=wrong-import-position
from catalog_lib import (  # noqa: E402  # pylint: disable=wrong-import-position
    DeprecationKind,
    entry_of,
    load_rows,
    snapshot,
)

LGTM_CI_USES = re.compile(
    r"^lgtm-hq/lgtm-ci/\.github/(?:workflows/(?P<workflow>[\w.-]+)\.ya?ml"
    r"|actions/(?P<action>[\w.-]+))@(?P<ref>\S+)$",
    # GitHub resolves owner and repository names case-insensitively.
    re.IGNORECASE,
)
WORKFLOW_FILE = re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")
ACTION_FILE = re.compile(r"(?:^|/)action\.ya?ml$")
REGISTRY_HEADER_END = "---\n"
EVERY = "*"


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
    ref = urllib.parse.quote(branch, safe="")
    tree = json.loads(gh("api", f"repos/{repository}/git/trees/{ref}?recursive=1"))
    if tree.get("truncated"):
        # A partial listing would under-report usage and let a removal pass.
        raise RuntimeError("the git tree listing is truncated")
    paths = [
        str(item["path"])
        for item in tree.get("tree", [])
        if item.get("type") == "blob"
        and (WORKFLOW_FILE.search(item["path"]) or ACTION_FILE.search(item["path"]))
    ]
    return {
        path: gh(
            "api",
            "-H",
            "Accept: application/vnd.github.raw",
            f"repos/{repository}/contents/{urllib.parse.quote(path)}?ref={ref}",
        )
        for path in paths
    }


def record_call(
    usage: Usage,
    uses: str,
    passed: Any,
    reads: list[str],
    secrets: Any = None,
) -> None:
    """Record one ``uses:`` of an lgtm-ci entry point.

    Args:
        usage: Accumulator for the repository.
        uses: The ``uses:`` value.
        passed: The ``with:`` mapping.
        reads: Output names the file reads from this call; ``*`` for all.
        secrets: The job's ``secrets:`` mapping, or ``inherit`` (all).
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
    names = [EVERY] if secrets == "inherit" else list(secrets or {})
    for name in names if isinstance(secrets, (dict, str)) else []:
        usage.keys.add(
            catalog_lib.removal_key(
                entry_id=entry_id,
                kind=DeprecationKind.SECRET,
                name=str(name),
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
        Output names; ``*`` when the whole ``outputs`` object is read.
    """
    if not ident:
        return []
    name = re.escape(str(ident))
    owner = rf"(?:\.{name}\b|\[\s*['\"]{name}['\"]\s*\])"
    output = r"(?:\.([\w-]+)|\[\s*['\"]([\w-]+)['\"]\s*\])"
    pattern = rf"\b{context}{owner}\s*(?:\.outputs|\[\s*['\"]outputs['\"]\s*\])"
    found = re.findall(pattern + rf"\s*{output}", text)
    names = {dotted or quoted for dotted, quoted in found}
    # `toJSON(needs.x.outputs)` and the like read every output at once.
    if re.search(pattern + r"(?!\s*[.\[\w])", text):
        names.add(EVERY)
    return sorted(names)


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
                secrets=job.get("secrets"),
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
    live: set[str],
    today: dt.date,
) -> dict[str, Any]:
    """Return a registry row rebuilt from a scan.

    A key is kept when the catalog deprecates it or its whole entry, or when
    lgtm-ci no longer exposes it at all: a removal PR drops the record before
    it refreshes the registry, and that usage is exactly what the gate needs.

    Args:
        row: Current row (keeps its repository and tracking issues).
        usage: Scan result.
        deprecated: Removal keys the catalog deprecates.
        live: Removal keys the work tree still exposes.
        today: Verification date.

    Returns:
        The new row.
    """
    keys = set()
    for key in usage.keys:
        if not key.endswith(f":{EVERY}"):
            keys.add(key)
            continue
        # `secrets: inherit` or a whole-`outputs` read uses every such item.
        prefix = key[: -len(EVERY)]
        keys |= {k for k in live | deprecated if k.startswith(prefix)}
    kept = {
        key
        for key in keys
        if key in deprecated
        or catalog_lib.removal_key(entry_of(key), DeprecationKind.ENTRY) in deprecated
        or key not in live
    }
    return {
        "repository": row["repository"],
        "tracking-issues": list(row.get("tracking-issues") or []),
        "last-verified": today.isoformat(),
        "pins": sorted(usage.pins),
        "uses": sorted(usage.entries),
        "deprecated-in-use": sorted(kept),
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


def refresh_rows(
    rows: list[dict[str, Any]],
    repositories: list[str],
    head: catalog_lib.Snapshot | None,
    today: dt.date,
) -> tuple[list[dict[str, Any]], int]:
    """Rescan the selected rows; leave the others and unreadable ones as they are.

    Args:
        rows: Registry rows, sorted.
        repositories: Rows to scan; empty scans every row.
        head: Work-tree snapshot (deprecated and live keys).
        today: Verification date.

    Returns:
        ``(rows, number of repositories that could not be read)``.
    """
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
        new = refreshed_row(
            row=row,
            usage=usage,
            deprecated=head.deprecated if head else set(),
            live=head.keys if head else set(),
            today=today,
        )
        print(
            f"{repository}: {len(new['uses'])} entr(y/ies), "
            f"pins {flow_list(new['pins'])}, "
            f"deprecated in use {flow_list(new['deprecated-in-use'])}",
        )
        refreshed.append(new)
    return refreshed, failed


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
    refreshed, failed = refresh_rows(
        rows=rows,
        repositories=repositories,
        head=snapshot(repo_root=repo_root, ref=None),
        today=today,
    )
    if write:
        write_registry(repo_root=repo_root, rows=refreshed)
        print(f"wrote {catalog_lib.CONSUMERS_RELPATH}")
    return 1 if failed else 0
