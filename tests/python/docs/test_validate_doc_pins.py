# SPDX-License-Identifier: MIT
"""Which files ``validate-doc-pins.py`` scans and what its CI job reports.

The Doc Pins job in ``ci.yml`` runs ``main`` over the repository. The ref
rules themselves are in ``catalog/test_governance_checks.py``; these tests
cover the file selection (scanned globs, text suffixes, the CHANGELOG
exemption) and the exit code and messages a contributor sees.
"""

# pytest injects fixtures by parameter name; the shadowing is the mechanism.
# pylint: disable=redefined-outer-name
from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

UNPINNED = "uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main\n"
PINNED = (
    "uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml"
    "@0123456789abcdef0123456789abcdef01234567 # v1.0.0\n"
)


@pytest.fixture(scope="module")
def doc_pins(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load ``validate-doc-pins.py`` once per module."""
    return load_script("scripts/ci/docs/validate-doc-pins.py")


def populate(root: Path, files: dict[str, str]) -> None:
    """Write ``files`` (relative path to content) under ``root``."""
    for relative, content in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def test_scans_docs_examples_and_top_level_text_files_only(
    doc_pins: ModuleType,
    tmp_path: Path,
) -> None:
    """Scanned globs and text suffixes decide the file list; CHANGELOG is history."""
    populate(
        tmp_path,
        {
            "README.md": PINNED,
            "SECURITY.md": PINNED,
            "CHANGELOG.md": UNPINNED,
            "docs/guide/usage.md": PINNED,
            "docs/notes.txt": UNPINNED,
            "examples/ci/workflow.yml": PINNED,
            "examples/ci/run.sh": UNPINNED,
            "examples/config.json": PINNED,
            "scripts/other.md": UNPINNED,
        },
    )
    (tmp_path / "examples" / "dir.yml").mkdir()
    scanned = doc_pins.scanned_files(repo_root=tmp_path)
    found = [path.relative_to(tmp_path).as_posix() for path in scanned]
    assert_that(found).is_equal_to(
        [
            "README.md",
            "SECURITY.md",
            "docs/guide/usage.md",
            "examples/ci/workflow.yml",
            "examples/config.json",
        ],
    )


def test_unpinned_references_fail_with_file_and_line(
    doc_pins: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Every floating reference is named with its location, then counted."""
    populate(
        tmp_path,
        {
            "README.md": PINNED + UNPINNED,
            "examples/ci.yml": UNPINNED.replace("@main", "@v1"),
        },
    )
    status = doc_pins.main(argv=["--repo-root", str(tmp_path)])
    err = capsys.readouterr().err
    assert_that(status).is_equal_to(1)
    assert_that(err).contains(
        "ERROR: README.md:2: `lgtm-hq/lgtm-ci/.github/workflows/"
        "reusable-demo.yml@main` is not pinned",
        "ERROR: examples/ci.yml:1:",
        "ERROR: 2 unpinned lgtm-ci reference(s)",
    )
    assert_that(err).does_not_contain("README.md:1:")


def test_pinned_repository_passes_and_reports_file_count(
    doc_pins: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A tree with only commit pins exits 0 and says how much it checked."""
    populate(
        tmp_path,
        {"README.md": PINNED, "docs/a.md": PINNED, "CHANGELOG.md": UNPINNED},
    )
    status = doc_pins.main(argv=["--repo-root", str(tmp_path)])
    captured = capsys.readouterr()
    assert_that(status).is_zero()
    assert_that(captured.err).is_empty()
    assert_that(captured.out).is_equal_to(
        "OK: every lgtm-ci reference in 2 file(s) is pinned to a commit\n",
    )
