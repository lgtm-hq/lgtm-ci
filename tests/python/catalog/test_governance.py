# SPDX-License-Identifier: MIT
"""Tests for the deprecation governance tooling (#1082).

Covers ``scripts/ci/catalog/deprecations.py`` (removal gate, consumer scan
parsing, report), the deprecation, registry and exception checks of
``scripts/ci/catalog/validate.py``, ``scripts/ci/catalog/release_notes.py``,
the ``CATALOG_RELEASE_NOTES`` path of ``generate-changelog.sh`` and
``scripts/ci/docs/validate-doc-pins.py``.

Each gate case builds a throwaway git repository whose ``main`` holds a
stable workflow with one deprecated input, a preview workflow and a
deprecated workflow, then edits the work tree the way a removal PR would.
"""

# pytest injects fixtures by parameter name; the shadowing is the mechanism.
# pylint: disable=redefined-outer-name
from __future__ import annotations

import datetime as dt
import os
import shutil
import subprocess
import sys
import textwrap
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

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


@pytest.fixture(scope="session")
def deprecations(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load ``deprecations.py`` once per session."""
    return load_script("scripts/ci/catalog/deprecations.py")


@pytest.fixture(scope="session")
def validate(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load the catalog ``validate.py`` once per session."""
    return load_script("scripts/ci/catalog/validate.py")


@pytest.fixture(scope="session")
def release_notes(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load ``release_notes.py`` once per session."""
    return load_script("scripts/ci/catalog/release_notes.py")


@pytest.fixture
def repo(
    tmp_path: Path,
) -> Path:
    """Build a repository whose ``main`` has the demo catalog committed."""
    root = tmp_path / "repo"
    workflows = root / ".github" / "workflows"
    workflows.mkdir(parents=True)
    (root / "catalog").mkdir()
    (workflows / "reusable-demo.yml").write_text(STABLE_WORKFLOW, encoding="utf-8")
    (workflows / "reusable-preview.yml").write_text(PREVIEW_WORKFLOW, encoding="utf-8")
    (workflows / "reusable-legacy.yml").write_text(LEGACY_WORKFLOW, encoding="utf-8")
    (root / "catalog" / "catalog.yml").write_text(CATALOG, encoding="utf-8")
    (root / "catalog" / "consumers.yml").write_text(
        consumers_yaml([]),
        encoding="utf-8",
    )
    (root / "catalog" / "deprecation-exceptions.yml").write_text(
        "---\nschema-version: 1\nexceptions: []\n",
        encoding="utf-8",
    )
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    return root


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
    edit(
        root,
        ".github/workflows/reusable-demo.yml",
        """      old:
        description: "DEPRECATED (#9), accepted but inert. Use keep."
        type: string
        default: ""
""",
        "",
    )
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


def test_gate_passes_when_nothing_is_removed(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """An unchanged tree has nothing to gate."""
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices[-1]).starts_with("0 removal(s)")


def test_gate_allows_removal_when_no_consumer_uses_it(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Fresh evidence without users lets a deprecated input go."""
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a", "uses": ["reusable-demo"]}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices).contains(
        "reusable-demo:input:old: removal allowed; no known consumer uses it",
    )


def test_gate_blocks_removal_while_a_consumer_still_passes_it(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A consumer listing the key blocks the removal and is named."""
    drop_old_input(repo)
    set_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("reusable-demo:input:old", "o/a")


def test_gate_blocks_removal_on_stale_evidence(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Age of the deprecation never counts; age of the evidence does."""
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a", "last-verified": "2026-09-01"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("stale", "o/a")


def test_gate_accepts_an_exception_naming_the_issue(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """An exception lets a removal through despite a consumer."""
    drop_old_input(repo)
    set_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    (repo / "catalog" / "deprecation-exceptions.yml").write_text(
        textwrap.dedent(
            """\
            ---
            schema-version: 1
            exceptions:
              - removal: reusable-demo:input:old
                issue: 42
                reason: "Owner accepted the break"
            """,
        ),
        encoding="utf-8",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices[0]).contains("exception (#42)")


def test_gate_rejects_removing_a_never_deprecated_stable_input(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Stable items must go through a deprecation release first."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        """      keep:
        description: "Still supported"
        type: string
        default: ""
""",
        "",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains(
        "reusable-demo:input:keep",
        "without a deprecation release",
    )


def test_gate_rejects_removing_a_never_deprecated_stable_output(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Outputs are part of the stable contract too."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        """    outputs:
      out:
        description: "Result"
        value: ${{ jobs.demo.outputs.out }}
""",
        "",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).starts_with("reusable-demo:output:out:")


def test_gate_only_notes_preview_removals(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Preview may change without a migration; consumers are listed."""
    edit(
        repo,
        ".github/workflows/reusable-preview.yml",
        """      knob:
        description: "Experimental knob"
        type: string
        default: ""
""",
        "",
    )
    set_consumers(repo, [{"repository": "o/a", "uses": ["reusable-preview"]}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices[0]).contains("reusable-preview:input:knob", "o/a")


def test_gate_blocks_deleting_a_deprecated_entry_still_called(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A deprecated entry point is in use when any consumer calls it."""
    (repo / ".github" / "workflows" / "reusable-legacy.yml").unlink()
    set_consumers(repo, [{"repository": "o/a", "uses": ["reusable-legacy"]}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).starts_with("reusable-legacy:entry:")


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


def test_gate_ignores_a_registry_edit_that_erases_a_consumer(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Evidence on the base cannot be dropped by the change being judged."""
    commit_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("o/a")


def test_gate_ignores_a_deleted_registry_row(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Deleting a consumer's row does not delete the consumer."""
    commit_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    drop_old_input(repo)
    set_consumers(repo, [])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("o/a")


def test_gate_keeps_the_base_verification_date(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A change cannot freshen evidence by editing `last-verified`."""
    commit_consumers(repo, [{"repository": "o/a", "last-verified": "2026-09-01"}])
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("stale", "o/a")


def test_gate_treats_a_future_date_as_stale(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """`last-verified` after today is not evidence."""
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a", "last-verified": "2027-01-01"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("stale", "o/a")


def test_gate_ignores_exceptions_already_on_the_base(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """An old exception is audit trail, not approval for a new removal."""
    (repo / "catalog" / "deprecation-exceptions.yml").write_text(
        textwrap.dedent(
            """\
            ---
            schema-version: 1
            exceptions:
              - removal: reusable-demo:input:keep
                issue: 42
                reason: "Approved long ago"
            """,
        ),
        encoding="utf-8",
    )
    git(repo, "commit", "-qam", "old exception")
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        """      keep:
        description: "Still supported"
        type: string
        default: ""
""",
        "",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("reusable-demo:input:keep")


def test_gate_fails_when_the_catalog_is_deleted(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Deleting the catalog must not read as "nothing to gate"."""
    (repo / "catalog" / "catalog.yml").unlink()
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("deleted")


def test_gate_rejects_making_a_stable_input_required(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A new required input fails every caller that does not pass it."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        """      keep:
        description: "Still supported"
        type: string
        default: ""
""",
        """      keep:
        description: "Still supported"
        type: string
        required: true
""",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).starts_with("reusable-demo:required:keep:")


def test_gate_rejects_removing_a_stable_secret(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Callers passing a removed secret fail at startup, so secrets count."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        "    outputs:\n",
        "    secrets:\n      TOKEN:\n        required: false\n    outputs:\n",
    )
    git(repo, "commit", "-qam", "secret")
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        "    secrets:\n      TOKEN:\n        required: false\n",
        "",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).starts_with("reusable-demo:secret:TOKEN:")


def test_scan_records_secrets_case_and_whole_output_reads(
    deprecations: ModuleType,
) -> None:
    """Secrets passed or inherited, any owner casing, and `toJSON(outputs)`."""
    text = textwrap.dedent(
        """\
        jobs:
          a:
            uses: LGTM-HQ/lgtm-ci/.github/workflows/reusable-demo.yml@abc
            secrets:
              TOKEN: ${{ secrets.X }}
          b:
            uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-legacy.yml@abc
            secrets: inherit
          c:
            needs: [a]
            runs-on: ubuntu-24.04
            steps:
              - run: echo '${{ toJSON(needs.a.outputs) }}'
        """,
    )
    usage = deprecations.Usage()
    deprecations.scan_file(usage=usage, path=".github/workflows/ci.yml", text=text)
    assert_that(usage.keys).contains(
        "reusable-demo:secret:TOKEN",
        "reusable-demo:output:*",
        "reusable-legacy:secret:*",
    )
    row = deprecations.refreshed_row(
        row={"repository": "o/a"},
        usage=usage,
        deprecated={"reusable-demo:output:out", "reusable-legacy:secret:OLD"},
        live={
            "reusable-demo:entry",
            "reusable-demo:output:out",
            "reusable-demo:secret:TOKEN",
            "reusable-legacy:entry",
            "reusable-legacy:secret:OLD",
        },
        today=TODAY,
    )
    assert_that(row["deprecated-in-use"]).is_equal_to(
        ["reusable-demo:output:out", "reusable-legacy:secret:OLD"],
    )


def test_gate_fails_on_an_unknown_base_ref(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A missing base must not read as "nothing removed"."""
    verdict = deprecations.gate(
        repo_root=repo,
        base_ref="origin/nope",
        max_age_days=14,
        today=TODAY,
    )
    assert_that(verdict.errors[0]).contains("origin/nope")


def test_scan_file_records_inputs_outputs_and_pins(
    deprecations: ModuleType,
) -> None:
    """Workflow calls, step calls and the outputs read from both are found."""
    text = textwrap.dedent(
        """\
        jobs:
          cov:
            uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-coverage.yml@abc # v1
            with:
              publish-pages: true
          after:
            needs: cov
            runs-on: ubuntu-24.04
            steps:
              - id: setup
                uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v0
                with:
                  python-version: "3.13"
              - run: >-
                  echo ${{ needs.cov.outputs.pages-url }}
                  ${{ steps.setup.outputs.x }}
              - uses: actions/checkout@v6
        """,
    )
    usage = deprecations.Usage()
    deprecations.scan_file(usage=usage, path=".github/workflows/ci.yml", text=text)
    assert_that(sorted(usage.pins)).is_equal_to(["abc", "v0"])
    assert_that(sorted(usage.entries)).is_equal_to(["reusable-coverage", "setup-env"])
    assert_that(usage.keys).contains(
        "reusable-coverage:input:publish-pages",
        "reusable-coverage:output:pages-url",
        "setup-env:input:python-version",
        "setup-env:output:x",
        "setup-env:entry",
    )


def test_scan_file_reads_composite_actions(
    deprecations: ModuleType,
) -> None:
    """A consumer's own composite action counts as usage too."""
    sha = "0123456789abcdef0123456789abcdef01234567"
    text = textwrap.dedent(
        f"""\
        runs:
          using: composite
          steps:
            - uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@{sha}
        """,
    )
    usage = deprecations.Usage()
    deprecations.scan_file(usage=usage, path=".github/actions/x/action.yml", text=text)
    assert_that(usage.entries).is_equal_to({"run-pytest"})


def test_refreshed_row_keeps_only_deprecated_keys(
    deprecations: ModuleType,
) -> None:
    """The registry stores deprecated keys, not every input a consumer passes."""
    usage = deprecations.Usage(
        pins={"b", "a"},
        entries={"reusable-demo"},
        keys={
            "reusable-demo:entry",
            "reusable-demo:input:old",
            "reusable-demo:input:keep",
        },
    )
    row = deprecations.refreshed_row(
        row={"repository": "o/a", "tracking-issues": [7]},
        usage=usage,
        deprecated={"reusable-demo:input:old"},
        live={"reusable-demo:entry", "reusable-demo:input:keep"},
        today=TODAY,
    )
    assert_that(row).is_equal_to(
        {
            "repository": "o/a",
            "tracking-issues": [7],
            "last-verified": "2026-10-08",
            "pins": ["a", "b"],
            "uses": ["reusable-demo"],
            "deprecated-in-use": ["reusable-demo:input:old"],
        },
    )


def test_refreshed_row_keeps_usage_of_items_already_removed(
    deprecations: ModuleType,
) -> None:
    """A removal PR drops the record before refreshing; the usage must stay."""
    usage = deprecations.Usage(
        entries={"reusable-demo", "reusable-legacy"},
        keys={
            "reusable-demo:entry",
            "reusable-demo:input:gone",
            "reusable-legacy:entry",
            "reusable-legacy:input:dir",
        },
    )
    row = deprecations.refreshed_row(
        row={"repository": "o/a"},
        usage=usage,
        deprecated={"reusable-legacy:entry"},
        live={
            "reusable-demo:entry",
            "reusable-legacy:entry",
            "reusable-legacy:input:dir",
        },
        today=TODAY,
    )
    assert_that(row["deprecated-in-use"]).is_equal_to(
        [
            "reusable-demo:input:gone",
            "reusable-legacy:entry",
            "reusable-legacy:input:dir",
        ],
    )


def test_gate_blocks_removal_recorded_after_its_record_was_dropped(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """The refreshed row of a removal PR still names the removed input."""
    drop_old_input(repo)
    usage = deprecations.Usage(
        entries={"reusable-demo"},
        keys={"reusable-demo:entry", "reusable-demo:input:old"},
    )
    head = deprecations.snapshot(repo_root=repo, ref=None)
    row = deprecations.refreshed_row(
        row={"repository": "o/a"},
        usage=usage,
        deprecated=head.deprecated,
        live=head.keys,
        today=TODAY,
    )
    set_consumers(repo, [row])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("reusable-demo:input:old", "o/a")


def test_gate_blocks_partial_removal_from_a_deprecated_entry_in_use(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A wholly deprecated entry's inputs stay while anyone calls the entry."""
    edit(
        repo,
        ".github/workflows/reusable-legacy.yml",
        "on:\n  workflow_call:\n",
        "on:\n  workflow_call:\n    inputs:\n      dir:\n        type: string\n",
    )
    git(repo, "commit", "-qam", "legacy input")
    edit(
        repo,
        ".github/workflows/reusable-legacy.yml",
        "    inputs:\n      dir:\n        type: string\n",
        "",
    )
    set_consumers(
        repo,
        [{"repository": "o/a", "uses": ["reusable-legacy"]}],
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).starts_with("reusable-legacy:input:dir:")


@pytest.mark.parametrize(
    "expression",
    [
        "needs.cov.outputs.pages-url",
        "needs.cov.outputs['pages-url']",
        'needs["cov"].outputs.pages-url',
        "needs['cov']['outputs']['pages-url']",
    ],
)
def test_outputs_read_understands_bracket_access(
    deprecations: ModuleType,
    expression: str,
) -> None:
    """Dotted, bracketed and mixed property access all count as a read."""
    text = f"run: echo ${{{{ {expression} }}}}"
    found = deprecations.outputs_read(text=text, context="needs", ident="cov")
    assert_that(found).is_equal_to(["pages-url"])


def test_write_registry_round_trips_through_the_validator(
    deprecations: ModuleType,
    validate: ModuleType,
    repo: Path,
) -> None:
    """Rows written by ``scan --write`` satisfy the registry schema."""
    deprecations.write_registry(
        repo_root=repo,
        rows=[
            {
                "repository": "o/a",
                "tracking-issues": [7],
                "last-verified": "2026-10-08",
                "pins": ["0123456789abcdef0123456789abcdef01234567"],
                "uses": ["reusable-demo"],
                "deprecated-in-use": ["reusable-demo:input:old"],
            },
        ],
    )
    report = validate.Report()
    validate.check_consumers(
        report=report,
        repo_root=repo,
        ids={"reusable-demo"},
        covered={"reusable-demo:input:old"},
    )
    assert_that(report.errors).is_empty()
    assert_that(report.notices).is_empty()


def check_deprecations(
    validate: ModuleType,
    root: Path,
) -> Any:
    """Run the validator's deprecation check on the work tree.

    Args:
        validate: Loaded validator module.
        root: Repository root.

    Returns:
        The report.
    """
    catalog = validate.catalog_lib.load_catalog(path=root / "catalog" / "catalog.yml")
    report = validate.Report()
    validate.check_deprecations(
        report=report,
        catalog=catalog,
        entries=catalog["entries"],
        repo_root=root,
    )
    return report


def test_validator_accepts_the_demo_catalog(
    validate: ModuleType,
    repo: Path,
) -> None:
    """The fixture's records are consistent."""
    assert_that(check_deprecations(validate, repo).errors).is_empty()


def test_validator_requires_a_record_for_a_marked_input(
    validate: ModuleType,
    repo: Path,
) -> None:
    """A description saying "deprecated" without a record is an error."""
    edit(
        repo,
        ".github/workflows/reusable-preview.yml",
        "Experimental knob",
        "Deprecated knob",
    )
    errors = check_deprecations(validate, repo).errors
    assert_that(errors).is_length(1)
    assert_that(errors[0]).contains(
        "reusable-preview:input:knob",
        "no `deprecations` record",
    )


def test_validator_requires_the_input_to_say_it_is_deprecated(
    validate: ModuleType,
    repo: Path,
) -> None:
    """A record whose input description is silent is an error."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        "DEPRECATED (#9), accepted but inert. Use keep.",
        "Use keep.",
    )
    errors = check_deprecations(validate, repo).errors
    assert_that(errors[0]).contains("its description must say it is deprecated")


def test_validator_rejects_a_record_for_a_missing_input(
    validate: ModuleType,
    repo: Path,
) -> None:
    """Removing the input without editing the record is caught."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        """      old:
        description: "DEPRECATED (#9), accepted but inert. Use keep."
        type: string
        default: ""
""",
        "",
    )
    errors = check_deprecations(validate, repo).errors
    assert_that(errors[0]).contains("has no input `old`")


def test_validator_rejects_an_entry_record_on_a_live_tier(
    validate: ModuleType,
    repo: Path,
) -> None:
    """``kind: entry`` needs the entry to be tier ``deprecated``."""
    edit(
        repo,
        "catalog/catalog.yml",
        "entries: [reusable-legacy]",
        "entries: [reusable-preview]",
    )
    errors = check_deprecations(validate, repo).errors
    assert_that(" ".join(errors)).contains(
        "`reusable-preview` must have tier `deprecated`",
    )


@pytest.mark.parametrize(
    ("old", "new", "message"),
    [
        ('since: "1.0.0"\n    issue: 9', 'since: "soon"\n    issue: 9', "`since`"),
        ("issue: 9", "issue: nine", "`issue`"),
        ("    name: old\n", "", "needs the `name`"),
        ("kind: input", "kind: knob", "`kind` must be one of"),
    ],
)
def test_validator_checks_record_fields(
    validate: ModuleType,
    repo: Path,
    old: str,
    new: str,
    message: str,
) -> None:
    """Each malformed field is reported."""
    edit(repo, "catalog/catalog.yml", old, new)
    errors = check_deprecations(validate, repo).errors
    assert_that(" ".join(errors)).contains(message)


def test_validator_flags_floating_consumer_pins(
    validate: ModuleType,
    repo: Path,
) -> None:
    """A floating ref is a notice, not an error: consumers own their pins."""
    set_consumers(
        repo,
        [{"repository": "o/a", "pins": ["v0"], "uses": ["reusable-demo"]}],
    )
    report = validate.Report()
    validate.check_consumers(
        report=report,
        repo_root=repo,
        ids={"reusable-demo"},
        covered=set(),
    )
    assert_that(report.errors).is_empty()
    assert_that(report.notices[0]).contains("`v0`", "floating ref")


def test_validator_rejects_malformed_consumers_and_exceptions(
    validate: ModuleType,
    repo: Path,
) -> None:
    """Dates, sort order and exception keys are checked."""
    set_consumers(
        repo,
        [
            {"repository": "o/b", "last-verified": "yesterday"},
            {"repository": "o/a"},
        ],
    )
    (repo / "catalog" / "deprecation-exceptions.yml").write_text(
        "---\nschema-version: 1\nexceptions:\n  - {removal: 'demo old', issue: 0}\n",
        encoding="utf-8",
    )
    report = validate.Report()
    validate.check_consumers(report=report, repo_root=repo, ids=set(), covered=set())
    validate.check_exceptions(report=report, repo_root=repo)
    joined = " ".join(report.errors)
    assert_that(joined).contains(
        "sorted by repository",
        "`last-verified` must be a YYYY-MM-DD date",
        "`removal` must be",
        "approved the removal",
        "missing required key `reason`",
    )


def test_release_notes_report_tier_changes_and_deprecations(
    release_notes: ModuleType,
) -> None:
    """Every kind of catalog change lands in its Keep a Changelog section."""
    base = {
        "entries": [
            {"id": "a", "tier": "preview"},
            {"id": "gone", "tier": "deprecated"},
            {"id": "b", "tier": "stable"},
        ],
        "deprecations": [
            {
                "id": "b-x",
                "kind": "input",
                "name": "x",
                "entries": ["b"],
                "issue": 5,
                "replacement": "Drop it",
            },
        ],
    }
    head = {
        "entries": [
            {"id": "a", "tier": "stable"},
            {"id": "b", "tier": "stable"},
            {"id": "new", "tier": "preview"},
        ],
        "deprecations": [
            {
                "id": "a-y",
                "kind": "output",
                "name": "y",
                "entries": ["a"],
                "issue": 6,
                "replacement": "Read z",
            },
        ],
    }
    text = release_notes.render(
        base=base,
        head=head,
        removed=["b:input:x", "a:output:old", "gone:entry"],
    )
    assert_that(text).is_equal_to(
        textwrap.dedent(
            """\
            ### Added

            - **catalog**: `new` added as `preview`

            ### Changed

            - **catalog**: `a` tier `preview` → `stable`

            ### Deprecated

            - **catalog**: output `y` on `a` (#6): Read z

            ### Removed

            - **catalog**: `gone` removed (was `deprecated`)
            - **catalog**: input `x` removed from `b`; deprecated (#5)
            - **catalog**: output `old` removed from `a`; not deprecated first""",
        ),
    )


def test_release_notes_are_empty_without_a_base_catalog(
    release_notes: ModuleType,
) -> None:
    """The first release with a catalog does not list every entry as new."""
    assert_that(release_notes.render(base=None, head={"entries": []})).is_empty()


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
def test_generate_changelog_merges_catalog_notes(
    repo: Path,
) -> None:
    """``CATALOG_RELEASE_NOTES=true`` adds the catalog diff to the section."""
    git(repo, "tag", "v1.0.0")
    edit(repo, "catalog/catalog.yml", 'tier: preview, reason: "New"', "tier: stable")
    git(repo, "commit", "-qam", "feat(catalog): promote preview")
    env = {
        **os.environ,
        "CATALOG_RELEASE_NOTES": "true",
        "PYTHON": sys.executable,
        "VERSION": "1.1.0",
        "GITHUB_OUTPUT": str(repo.parent / "github-output"),
    }
    result = subprocess.run(
        ["bash", str(PROJECT_ROOT / "scripts/ci/release/generate-changelog.sh")],
        cwd=repo,
        env=env,
        capture_output=True,
        check=True,
        text=True,
    )
    assert_that(result.stdout).contains(
        "### Added\n\n- **catalog**: promote preview",
        "### Changed\n\n- **catalog**: `reusable-preview` tier `preview` → `stable`",
    )


def test_doc_pins_accept_only_commits_and_placeholders(
    load_script: Callable[[str], ModuleType],
) -> None:
    """Branches and tags are flagged; SHAs, placeholders and expressions pass."""
    module = load_script("scripts/ci/docs/validate-doc-pins.py")
    base = "lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@"
    text = "\n".join(
        [
            f"uses: {base}0123456789abcdef0123456789abcdef01234567 # v1.0.0",
            f"uses: {base}<sha> # vX.Y.Z",
            f"uses: {base}${{{{ env.REF }}}}",
            f"uses: {base}main",
            f"uses: {base}v0",
            f"uses: {base}v1.2.3",
            f"uses: {base}0123456",
            f"uses: {base}<main>",
            f"uses: {base}<commit-sha>",
        ],
    )
    flagged = [line for line, _ in module.floating_refs(text=text)]
    assert_that(flagged).is_equal_to([4, 5, 6, 7, 8])
