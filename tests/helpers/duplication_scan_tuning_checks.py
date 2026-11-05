# SPDX-License-Identifier: MIT
"""Script size gate and below-threshold near-miss reporting (#1237 tuning)."""

from __future__ import annotations

import contextlib
import io
import os
import unittest
from unittest.mock import patch

from duplication_scan_support import FakeGitHub, model, offline_cli, scan

FAIL_AUDIT = """#!/usr/bin/env bash
# Fail the CI job when the security audit found vulnerabilities or errors.
set -euo pipefail

echo "::error::Security audit found vulnerabilities or failed."
exit 1
"""
PYTHON_SCRIPT = """\"\"\"Doc.\"\"\"
import sys
from os import path
print(path.sep)
sys.exit(0)
"""
PACKAGE = """#!/usr/bin/env bash
set -eu
mkdir -p out
cp a out/
tar -czf out.tgz out
"""


NAMES = ("left", "right")


def shingled(repository: str, path: str, tokens: str) -> model.Unit:
    """Build a public script unit with one shape token per character."""
    return model.Unit(repository, path, "", False, "script", tuple(tokens), "")


def script(repository: str, path: str, source: str) -> model.Unit:
    """Build one real script unit through the production parser."""
    return model.units(repository, False, {path: source})[0]


def repositories(source: str) -> list[dict[str, object]]:
    """Two public repositories carrying an identical script copy."""
    return [
        {
            "full_name": f"org/{name}",
            "private": False,
            "archived": False,
            "files": {"scripts/ci/helper.sh": source},
        }
        for name in ("left", "right")
    ]


def run_cli(source: str, *arguments: str) -> tuple[str, FakeGitHub]:
    """Run the dry-run CLI offline over two copies of ``source``."""
    api = FakeGitHub(repositories=repositories(source))
    output = io.StringIO()
    with (
        offline_cli(True, *arguments),
        patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}),
        patch.object(scan, "GitHub", return_value=api),
        contextlib.redirect_stdout(output),
    ):
        assert scan.main() == 0
    return output.getvalue(), api


class Cases(unittest.TestCase):
    """Select one tuning scenario by its BATS case name."""

    def test_script_size_counts_operative_statements(self) -> None:
        """Shebang, set, echo/printf and exit lines are boilerplate."""
        fail = script("org/a", "scripts/ci/fail-audit.sh", FAIL_AUDIT)
        package = script("org/a", "scripts/ci/package.sh", PACKAGE)
        self.assertEqual(model.unit_size(fail), 0)
        self.assertEqual(model.unit_size(package), 3)
        python = script(
            "org/a",
            "scripts/ci/check.py",
            PYTHON_SCRIPT,
        )
        self.assertEqual(model.unit_size(python), 2)

    def test_tiny_script_cannot_create_an_issue(self) -> None:
        """An exact tiny copy is gated; a large-enough copy still clusters."""
        tiny = [
            script(f"org/{name}", "scripts/ci/fail-audit.sh", FAIL_AUDIT)
            for name in ("left", "right")
        ]
        path = "scripts/ci/package.sh"
        large = [script(f"org/{name}", path, PACKAGE) for name in NAMES]
        self.assertEqual(tiny[0].fingerprint, tiny[1].fingerprint)
        self.assertEqual(model.clusters(tiny, [], 0.8, 3), [])
        self.assertEqual(len(model.clusters(tiny, [], 0.8, 0)), 1)
        self.assertEqual(len(model.clusters(large, [], 0.8, 3)), 1)
        # A catalog match on its own no longer qualifies a tiny helper either.
        reference = model.Unit(
            "lgtm-hq/lgtm-ci",
            "scripts/ci/security/fail-audit.sh",
            "",
            False,
            "script",
            tiny[0].shape,
            FAIL_AUDIT,
            reference="reusable-security-audit",
        )
        self.assertEqual(model.clusters(tiny[:1], [reference], 0.8, 3), [])
        self.assertEqual(len(model.clusters(tiny[:1], [reference], 0.8, 0)), 1)

    def test_cli_default_gates_tiny_scripts(self) -> None:
        """The tuned CLI default reports no issue for an exact tiny copy."""
        output, api = run_cli(FAIL_AUDIT, "--min-script-statements=3")
        self.assertIn("0 qualifying clusters", output)
        self.assertIn("at least 3 operative statements", output)
        self.assertEqual(api.writes, [])
        output, _ = run_cli(PACKAGE, "--min-script-statements=3")
        self.assertIn("1 qualifying clusters", output)

    def test_near_misses_report_below_threshold(self) -> None:
        """Top-N scores below the threshold are listed; zero scores are not."""
        left = shingled("org/left", "scripts/a.sh", "abcdefghij")
        right = model.Unit(
            "org/right", "scripts/a.sh", "", False, "script", tuple("abcdefghiZ"), ""
        )
        other = shingled("org/other", "scripts/b.sh", "vwxyz")
        hidden = model.Unit(
            "org/hidden", "scripts/a.sh", "", True, "script", tuple("abcdefghiZ"), ""
        )
        misses = model.near_misses([left, right, other, hidden], [], 0.8, 10)
        self.assertEqual(
            [(m[0].repository, m[1].repository) for m in misses],
            [
                ("org/left", "org/right"),
            ],
        )
        self.assertAlmostEqual(misses[0][2], 0.778, places=3)
        self.assertEqual(model.near_matches([left, right], [], 0.8), [])
        self.assertEqual(model.near_misses([left, right], [], 0.7, 10), [])
        self.assertEqual(model.near_misses([left, right], [], 0.8, 0), [])
        # Gated scripts are excluded from the near-miss evidence as well.
        tiny = [
            script(f"org/{name}", "scripts/ci/fail.sh", FAIL_AUDIT.replace("1", n))
            for name, n in (("left", "1"), ("right", "2"))
        ]
        self.assertEqual(len(model.near_misses(tiny, [], 0.99, 10, 0)), 1)
        self.assertEqual(model.near_misses(tiny, [], 0.99, 10, 3), [])

    def test_cli_reports_near_misses(self) -> None:
        """The report always carries a near-miss section unless disabled."""
        output, _ = run_cli(PACKAGE)
        self.assertIn("## Top public near misses below 0.800", output)
        output, _ = run_cli(PACKAGE, "--near-misses=0")
        self.assertNotIn("near misses below", output)


if __name__ == "__main__":
    unittest.main()
