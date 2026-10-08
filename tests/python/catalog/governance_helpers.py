# SPDX-License-Identifier: MIT
"""Shared fixture data and helpers for the governance tests (#1082)."""

from __future__ import annotations

import datetime as dt
import re
import subprocess
from pathlib import Path
from types import ModuleType
from typing import Any

TODAY = dt.date(2026, 10, 8)


PROJECT_ROOT = Path(__file__).resolve().parents[3]


STABLE_WORKFLOW = """---
name: Reusable Demo
on:
  workflow_call:
    inputs:
      keep:
        description: "Still supported"
        type: string
        default: ""
      old:
        description: "DEPRECATED (#9), accepted but inert. Use keep."
        type: string
        default: ""
    outputs:
      out:
        description: "Result"
        value: ${{ jobs.demo.outputs.out }}
jobs:
  demo:
    runs-on: ubuntu-24.04
    steps:
      - run: echo demo
"""


PREVIEW_WORKFLOW = """---
name: Reusable Preview
on:
  workflow_call:
    inputs:
      knob:
        description: "Experimental knob"
        type: string
        default: ""
jobs:
  preview:
    runs-on: ubuntu-24.04
    steps:
      - run: echo preview
"""


LEGACY_WORKFLOW = """---
name: Reusable Legacy (deprecated)
on:
  workflow_call:
jobs:
  legacy:
    runs-on: ubuntu-24.04
    steps:
      - run: echo legacy
"""


CATALOG = """---
schema-version: 1
fixture-repository: example/fixture
entries:
  - {id: reusable-demo, kind: reusable-workflow, tier: stable}
  - {id: reusable-legacy, kind: reusable-workflow, tier: deprecated,
     reason: "Wrapper", replacement: reusable-demo}
  - {id: reusable-preview, kind: reusable-workflow, tier: preview, reason: "New"}
deprecations:
  - id: demo-old
    kind: input
    name: old
    since: "1.0.0"
    issue: 9
    replacement: "Use keep"
    entries: [reusable-demo]
  - id: legacy
    kind: entry
    since: "1.0.0"
    issue: 10
    replacement: "Call reusable-demo"
    entries: [reusable-legacy]
"""


def consumers_yaml(
    rows: list[dict[str, Any]],
) -> str:
    """Render a registry file.

    Args:
        rows: Registry rows.

    Returns:
        YAML text.
    """
    lines = ["---", "schema-version: 1", "consumers:"]
    if not rows:
        lines[-1] = "consumers: []"
    for row in rows:
        lines.append(f"  - repository: {row['repository']}")
        for key in ("tracking-issues", "pins", "uses", "deprecated-in-use"):
            values = ", ".join(f'"{v}"' for v in row.get(key, []))
            lines.append(f"    {key}: [{values}]")
        verified = row.get("last-verified", TODAY.isoformat())
        lines.append(f'    last-verified: "{verified}"')
    return "\n".join(lines) + "\n"


def git(
    root: Path,
    *args: str,
) -> None:
    """Run git with a throwaway identity.

    Args:
        root: Work tree.
        *args: Git arguments.
    """
    subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "-c",
            "user.name=governance-test",
            "-c",
            "user.email=governance-test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "tag.gpgsign=false",
            *args,
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def edit(
    root: Path,
    relpath: str,
    old: str,
    new: str,
) -> None:
    """Replace text in a work-tree file.

    Args:
        root: Repository root.
        relpath: File to edit.
        old: Text that must be present.
        new: Replacement.
    """
    path = root / relpath
    text = path.read_text(encoding="utf-8")
    assert old in text, old
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def drop_old_input(
    root: Path,
) -> None:
    """Remove the deprecated ``old`` input and its record, as a removal PR does."""
    remove_demo_input(root, "old")
    edit(
        root,
        "catalog/catalog.yml",
        """  - id: demo-old
    kind: input
    name: old
    since: "1.0.0"
    issue: 9
    replacement: "Use keep"
    entries: [reusable-demo]
""",
        "",
    )


def set_consumers(
    root: Path,
    rows: list[dict[str, Any]],
) -> None:
    """Replace the work-tree registry.

    Args:
        root: Repository root.
        rows: Registry rows.
    """
    (root / "catalog" / "consumers.yml").write_text(
        consumers_yaml(rows),
        encoding="utf-8",
    )


def commit_consumers(
    root: Path,
    rows: list[dict[str, Any]],
) -> None:
    """Put a registry on ``main`` so later work-tree edits are a change.

    Args:
        root: Repository root.
        rows: Registry rows.
    """
    set_consumers(root, rows)
    git(root, "commit", "-qam", "registry")


def run_gate(
    deprecations: ModuleType,
    root: Path,
) -> Any:
    """Run the gate against ``main`` as of ``TODAY``.

    Args:
        deprecations: Loaded module.
        root: Repository root.

    Returns:
        The verdict.
    """
    return deprecations.gate(
        repo_root=root,
        base_ref="main",
        max_age_days=14,
        today=TODAY,
    )


def check_deprecations(
    governance: ModuleType,
    root: Path,
) -> Any:
    """Run the deprecation check on the work tree.

    Args:
        governance: Loaded ``governance_checks`` module.
        root: Repository root.

    Returns:
        The report.
    """
    catalog = governance.catalog_lib.load_catalog(path=root / "catalog" / "catalog.yml")
    report = governance.Report()
    governance.check_deprecations(
        report=report,
        catalog=catalog,
        entries=catalog["entries"],
        repo_root=root,
    )
    return report


def remove_demo_input(
    root: Path,
    name: str,
) -> None:
    """Delete one input block from the demo stable workflow.

    Args:
        root: Repository root.
        name: Input to delete.
    """
    path = root / ".github" / "workflows" / "reusable-demo.yml"
    text = path.read_text(encoding="utf-8")
    pattern = rf"^      {re.escape(name)}:\n(?:        .*\n)+"
    new, count = re.subn(pattern, "", text, count=1, flags=re.M)
    assert count == 1, name
    path.write_text(new, encoding="utf-8")


def consumer_check(
    governance: ModuleType,
    root: Path,
    ids: set[str],
    covered: set[str],
) -> Any:
    """Run the registry check on the work tree.

    Args:
        governance: Loaded ``governance_checks`` module.
        root: Repository root.
        ids: Catalog entry ids.
        covered: Removal keys the deprecation records cover.

    Returns:
        The report.
    """
    report = governance.Report()
    governance.check_consumers(report=report, repo_root=root, ids=ids, covered=covered)
    return report
