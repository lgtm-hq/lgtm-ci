# SPDX-License-Identifier: MIT
"""``deprecations.py report`` (#1082): who still uses each deprecated item.

Maintainers read this report before removing a deprecated input or entry
point, so it must name every consumer that still uses one, count only real
usage, and flag consumers that pin lgtm-ci to something other than a commit.
"""

from __future__ import annotations

from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from governance_helpers import set_consumers  # pylint: disable=import-error

SHA = "0123456789abcdef0123456789abcdef01234567"


def test_report_lists_each_deprecation_with_its_consumers(
    deprecations: ModuleType,
    catalog_tree: Path,
) -> None:
    """Item-level usage and calls to a deprecated entry both count."""
    set_consumers(
        catalog_tree,
        [
            {
                "repository": "o/b",
                "pins": [SHA],
                "uses": ["reusable-legacy"],
            },
            {
                "repository": "o/a",
                "pins": [SHA],
                "uses": ["reusable-demo"],
                "deprecated-in-use": ["reusable-demo:input:old"],
            },
            {"repository": "o/c", "pins": [SHA], "uses": ["reusable-demo"]},
        ],
    )
    assert_that(deprecations.deprecation_report(repo_root=catalog_tree)).is_equal_to(
        [
            "demo-old (#9, since 1.0.0): 1 consumer(s)",
            "  - o/a: reusable-demo",
            "legacy (#10, since 1.0.0): 1 consumer(s)",
            "  - o/b: reusable-legacy",
        ],
    )


def test_report_flags_floating_pins(
    deprecations: ModuleType,
    catalog_tree: Path,
) -> None:
    """Branch, tag and short-SHA pins are listed per consumer; full SHAs are not."""
    set_consumers(
        catalog_tree,
        [
            {"repository": "o/a", "pins": [SHA, "main", "v1"]},
            {"repository": "o/b", "pins": [SHA[:7]]},
            {"repository": "o/c", "pins": [SHA]},
        ],
    )
    assert_that(deprecations.deprecation_report(repo_root=catalog_tree)).is_equal_to(
        [
            "demo-old (#9, since 1.0.0): no known consumer",
            "legacy (#10, since 1.0.0): no known consumer",
            "floating pin(s) in o/a: main, v1",
            f"floating pin(s) in o/b: {SHA[:7]}",
        ],
    )


def test_report_subcommand_prints_the_report(
    deprecations: ModuleType,
    catalog_tree: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``report`` reads only local files and exits 0."""
    set_consumers(
        catalog_tree,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    status = deprecations.main(argv=["report", "--repo-root", str(catalog_tree)])
    out = capsys.readouterr().out
    assert_that(status).is_zero()
    assert_that(out).starts_with("demo-old (#9, since 1.0.0): 1 consumer(s)\n")
    assert_that(out).contains("  - o/a: reusable-demo\n")


def test_report_subcommand_fails_cleanly_on_a_broken_registry(
    deprecations: ModuleType,
    catalog_tree: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Unparseable YAML is an error line and exit 1, not a traceback."""
    (catalog_tree / "catalog" / "consumers.yml").write_text(
        "consumers: [\n",
        encoding="utf-8",
    )
    status = deprecations.main(argv=["report", "--repo-root", str(catalog_tree)])
    assert_that(status).is_equal_to(1)
    assert_that(capsys.readouterr().err).starts_with("ERROR: ")
