# SPDX-License-Identifier: MIT
"""The coverage.py config behind ci.yml's Python floor (#1450, #1423).

The floor in ci.yml means something only if coverage.py lists every Python file
under scripts/ci, measures branches, and leaves out no file beyond the known
unmeasured set in ``omit``. That set may only shrink.
"""

from __future__ import annotations

import tomllib
from pathlib import Path
from typing import Any

import pytest
from assertpy import assert_that

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE = "scripts/ci"
# The unmeasured files when the floor was set (#1423). `omit` must stay a
# subset of this set, so one entry cannot be swapped for a new file. Remove a
# path here in the change that gives it pytest tests; never add one.
KNOWN_UNMEASURED = frozenset(
    {
        "scripts/ci/actions/classify-lint-timeout.py",
        "scripts/ci/actions/fix-sparse-checkout-scripts.py",
        "scripts/ci/actions/merge-cobertura.py",
        "scripts/ci/maintenance/duplication_core.py",
        "scripts/ci/maintenance/duplication_model.py",
        "scripts/ci/maintenance/duplication_python.py",
        "scripts/ci/maintenance/duplication_scan.py",
        "scripts/ci/maintenance/duplication_shell.py",
        "scripts/ci/maintenance/duplication_sources.py",
        "scripts/ci/maintenance/match-renovate-pins.py",
        "scripts/ci/release/ecosystems/read-rust-toolchain.py",
        "scripts/ci/security/classify-suppressions.py",
        "scripts/ci/security/remove_stale_suppressions.py",
        "scripts/ci/workflows/sync_ai_review_matrix.py",
        "scripts/ci/workflows/validate_comment_history_facades.py",
    },
)
GLOB_CHARS = frozenset("*?[]")


@pytest.fixture(name="coverage_config", scope="module")
def fixture_coverage_config() -> dict[str, Any]:
    """Return the ``[tool.coverage]`` table of pyproject.toml."""
    with (REPO_ROOT / "pyproject.toml").open("rb") as handle:
        config: dict[str, Any] = tomllib.load(handle)["tool"]["coverage"]
    return config


def test_measures_branches(
    coverage_config: dict[str, Any],
) -> None:
    """The floor applies to the combined line and branch total."""
    assert_that(coverage_config["run"].get("branch")).is_true()


def test_measures_scripts_ci_only(
    coverage_config: dict[str, Any],
) -> None:
    """The measured tree is scripts/ci, not the tests."""
    assert_that(coverage_config["run"].get("source")).is_equal_to([SOURCE])


def test_lists_files_no_test_loads(
    coverage_config: dict[str, Any],
) -> None:
    """scripts/ci is not a package; without this, unloaded files go unlisted."""
    report = coverage_config["report"]
    assert_that(report.get("include_namespace_packages")).is_true()


def test_omit_applies_at_report_time_only(
    coverage_config: dict[str, Any],
) -> None:
    """A run-time omit is resolved in each child's directory and leaks files."""
    assert_that(coverage_config["run"]).does_not_contain_key("omit")


def test_omit_names_existing_files_under_scripts_ci(
    coverage_config: dict[str, Any],
) -> None:
    """Each entry is the exact path of a real file, never a glob."""
    omit = coverage_config["report"].get("omit", [])
    for entry in omit:
        assert_that(set(entry) & GLOB_CHARS).described_as(entry).is_empty()
        assert_that(entry).starts_with(f"{SOURCE}/")
        assert_that(str(REPO_ROOT / entry)).is_file()


def test_omit_is_sorted_without_duplicates(
    coverage_config: dict[str, Any],
) -> None:
    """A sorted list keeps additions visible in review."""
    omit = coverage_config["report"].get("omit", [])
    assert_that(omit).is_equal_to(sorted(set(omit)))


def test_omit_only_shrinks(
    coverage_config: dict[str, Any],
) -> None:
    """New scripts must be measured, so the unmeasured list cannot grow."""
    omit = coverage_config["report"].get("omit", [])
    added = sorted(set(omit) - KNOWN_UNMEASURED)
    assert_that(added).described_as(
        "[tool.coverage.report] omit may only shrink: give a new script pytest "
        "tests instead of omitting it (unmeasured files tracked in #1598)",
    ).is_empty()
