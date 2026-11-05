# SPDX-License-Identifier: MIT
"""Script size gate and below-threshold near-miss reporting (#1237 tuning)."""

from __future__ import annotations

import contextlib
import io
import os
import sys
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
CASE_ARMS = """#!/bin/bash
case x in
 a) echo a ;;
 b) echo b ;;
 c) echo c ;;
esac
"""
PYTHON_WRAPPER = """import sys


def main():
    print("::error::x")
    return 1


if __name__ == "__main__":
    sys.exit(main())
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
        self.assertEqual(model.unit_size(python), 0)

    def test_script_size_resists_wrappers_and_chaining(self) -> None:
        """Structure cannot inflate the size; chained commands are each counted."""
        sizes = {
            "if-wrapper": (
                '#!/bin/bash\nif [ -z "x" ]; then\n  echo ::error::a\nelse\n'
                "  echo ok\nfi\nexit 1\n",
                0,
            ),
            "function-wrapper": (
                '#!/bin/bash\nfail() {\n  echo "$1"\n  exit 1\n}\nfail x\n',
                1,
            ),
            "semicolons": ("#!/bin/bash\necho hi; rm -rf x; cp a b; tar x\n", 3),
            "case-arms": (
                CASE_ARMS,
                0,
            ),
            "case-arm-work": (
                "#!/bin/bash\ncase x in\n a) mkdir a ;;\n b) cp a b;;\nesac\n",
                2,
            ),
            "and-or": ("#!/bin/bash\necho start && mkdir a || cp a b\n", 2),
            "one-line-package": (
                "#!/usr/bin/env bash\nmkdir -p out; cp a out/; tar -czf out.tgz out\n",
                3,
            ),
        }
        for name, (source, expected) in sizes.items():
            with self.subTest(name=name):
                unit = script("org/a", "scripts/ci/x.sh", source)
                self.assertEqual(model.unit_size(unit), expected)
        python = {
            "main-guard": (PYTHON_WRAPPER, 0),
            "semicolons": ("x = f(); y = g(); z = h(x, y)\n", 3),
            "try": (
                "try:\n    a = f()\nexcept ValueError:\n    pass\nelse:\n"
                "    b = g()\nfinally:\n    c = h()\n",
                3,
            ),
        }
        for name, (source, expected) in python.items():
            with self.subTest(name=f"python-{name}"):
                unit = script("org/a", "scripts/ci/x.py", source)
                self.assertEqual(model.unit_size(unit), expected)

    def test_opaque_scripts_are_never_undersized(self) -> None:
        """Uninspected logic is not hidden by the gate; it stays repo-keyed."""
        source = '#!/bin/bash\nX="${1:-${Y:-1}}"\n'
        left, right = (script(f"org/{n}", "scripts/ci/x.sh", source) for n in NAMES)
        self.assertTrue(any(t.startswith("<unresolved-") for t in left.shape))
        self.assertTrue(model.large_enough(left, model.MIN_SCRIPT_STATEMENTS))
        self.assertNotEqual(left.fingerprint, right.fingerprint)
        self.assertEqual(model.clusters([left, right], [], 0.8, 3), [])

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
        # No size flag at all: the real CLI default must gate the copy.
        default_api = FakeGitHub(repositories=repositories(FAIL_AUDIT))
        stream = io.StringIO()
        with (
            patch.object(scan, "references", return_value=[]),
            patch.object(scan, "load_exceptions", return_value=[]),
            patch.object(sys, "argv", ["scan", "--dry-run=true"]),
            patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}),
            patch.object(scan, "GitHub", return_value=default_api),
            contextlib.redirect_stdout(stream),
        ):
            self.assertEqual(scan.main(), 0)
        self.assertIn("0 qualifying clusters", stream.getvalue())
        self.assertIn("at least 3 operative", stream.getvalue())
        self.assertEqual(default_api.writes, [])
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
