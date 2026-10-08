# SPDX-License-Identifier: MIT
"""Tests for the catalog's governance checks and outputs (#1082).

Covers ``scripts/ci/catalog/governance_checks.py`` (deprecation records,
registry and exceptions), ``scripts/ci/catalog/release_notes.py``, the
``CATALOG_RELEASE_NOTES`` path of ``generate-changelog.sh`` and
``scripts/ci/docs/validate-doc-pins.py``.
"""

# pytest injects fixtures by parameter name; the shadowing is the mechanism.
# pylint: disable=redefined-outer-name
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import textwrap
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from governance_helpers import (  # pylint: disable=import-error
    PROJECT_ROOT,
    check_deprecations,
    consumer_check,
    edit,
    git,
    remove_demo_input,
    set_consumers,
)


def test_validator_accepts_the_demo_catalog(
    governance: ModuleType,
    repo: Path,
) -> None:
    """The fixture's records are consistent."""
    assert_that(check_deprecations(governance, repo).errors).is_empty()


def test_validator_requires_a_record_for_a_marked_input(
    governance: ModuleType,
    repo: Path,
) -> None:
    """A description saying "deprecated" without a record is an error."""
    edit(
        repo,
        ".github/workflows/reusable-preview.yml",
        "Experimental knob",
        "Deprecated knob",
    )
    errors = check_deprecations(governance, repo).errors
    assert_that(errors).is_length(1)
    assert_that(errors[0]).contains(
        "reusable-preview:input:knob",
        "no `deprecations` record",
    )


def test_validator_requires_the_input_to_say_it_is_deprecated(
    governance: ModuleType,
    repo: Path,
) -> None:
    """A record whose input description is silent is an error."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        "DEPRECATED (#9), accepted but inert. Use keep.",
        "Use keep.",
    )
    errors = check_deprecations(governance, repo).errors
    assert_that(errors[0]).contains("its description must say it is deprecated")


def test_validator_rejects_a_record_for_a_missing_input(
    governance: ModuleType,
    repo: Path,
) -> None:
    """Removing the input without editing the record is caught."""
    remove_demo_input(repo, "old")
    errors = check_deprecations(governance, repo).errors
    assert_that(errors[0]).contains("has no input `old`")


def test_validator_rejects_an_entry_record_on_a_live_tier(
    governance: ModuleType,
    repo: Path,
) -> None:
    """``kind: entry`` needs the entry to be tier ``deprecated``."""
    edit(
        repo,
        "catalog/catalog.yml",
        "entries: [reusable-legacy]",
        "entries: [reusable-preview]",
    )
    errors = check_deprecations(governance, repo).errors
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
    governance: ModuleType,
    repo: Path,
    old: str,
    new: str,
    message: str,
) -> None:
    """Each malformed field is reported."""
    edit(repo, "catalog/catalog.yml", old, new)
    errors = check_deprecations(governance, repo).errors
    assert_that(" ".join(errors)).contains(message)


def test_validator_flags_floating_consumer_pins(
    repo: Path,
    governance: ModuleType,
) -> None:
    """A floating ref is a notice, not an error: consumers own their pins."""
    set_consumers(
        repo,
        [{"repository": "o/a", "pins": ["v0"], "uses": ["reusable-demo"]}],
    )
    report = consumer_check(governance, repo, ids={"reusable-demo"}, covered=set())
    assert_that(report.errors).is_empty()
    assert_that(report.notices[0]).contains("`v0`", "floating ref")


def test_validator_rejects_malformed_consumers_and_exceptions(
    validate: ModuleType,
    repo: Path,
    governance: ModuleType,
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
    governance.check_consumers(report=report, repo_root=repo, ids=set(), covered=set())
    governance.check_exceptions(report=report, repo_root=repo)
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
