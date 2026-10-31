# SPDX-License-Identifier: MIT
"""Actual script-interpreter regressions exercised through scanner jobs."""

from __future__ import annotations

import unittest

from duplication_scan_regression_checks import job_unit
from duplication_scan_support import FixtureCase, model, syntax


class Cases(FixtureCase):
    """An executable's interpreter takes precedence over its filename suffix."""

    def test_python_non_python_suffix_flow(self) -> None:
        """Python in .sh and extensionless files must retain suite boundaries."""
        original = "if False:\n    print('A')\nprint('B')\n"
        changed = "if False:\n    print('A')\n    print('B')\n"
        for path in ("tools/check.sh", "scripts/check", "tools/check.js"):
            for prefix in (
                "python",
                "python3",
                "python3.14 -B",
                "env MODE=test python3",
                "uv run python3",
                "timeout 5 python3",
            ):
                with self.subTest(path=path, prefix=prefix):
                    block = {"steps": [{"run": f"{prefix} {path}"}]}
                    left = job_unit("org/left", block, files={path: original})
                    right = job_unit("org/right", block, files={path: changed})
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_shell_python_suffix(self) -> None:
        """Shell code named .py uses shell normalization and local expansion."""
        path = "tools/check.py"
        nested = "scripts/nested.sh"
        for prefix in ("bash", "sh", "bash -u", "source", ".", "env bash"):
            with self.subTest(prefix=prefix):
                block = {"steps": [{"run": f"{prefix} {path}"}]}
                files = {
                    path: "if true; then\n  bash scripts/nested.sh\nfi\n",
                    nested: "echo build/output\n",
                }
                left = job_unit("org/left", block, files=files)
                right = job_unit(
                    "org/right",
                    block,
                    files={**files, nested: "# comment\necho dist/result\n"},
                )
                self.assertNotIn("<unresolved-", " ".join(left.shape))
                self.assertEqual(left.fingerprint, right.fingerprint)
                self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
                changed = job_unit(
                    "org/right",
                    block,
                    files={**files, nested: "exit 7\n"},
                )
                self.assertEqual(model.clusters([left, changed], [], 0.8), [])

    def test_direct_shebang_parser(self) -> None:
        """A direct shebang selects the parser even when the suffix disagrees."""
        original = "if False:\n    print('A')\nprint('B')\n"
        changed = "if False:\n    print('A')\n    print('B')\n"
        for header in ("#!/usr/bin/python3", "#!/usr/bin/env python3"):
            with self.subTest(header=header):
                path = "tools/check.sh"
                block = {"steps": [{"run": f"./{path}"}]}
                left = job_unit(
                    "org/left",
                    block,
                    files={path: header + "\n" + original},
                )
                right = job_unit(
                    "org/right",
                    block,
                    files={path: header + "\n" + changed},
                )
                self.assertEqual(model.clusters([left, right], [], 0.8), [])
        path = "tools/check.py"
        block = {"steps": [{"run": f"./{path}"}]}
        files = {path: "#!/bin/bash\nif true; then\n  echo build/output\nfi\n"}
        left = job_unit("org/left", block, files=files)
        right = job_unit("org/right", block, files=files)
        self.assertNotIn("<unresolved-", " ".join(left.shape))
        self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
        changed = job_unit(
            "org/right",
            block,
            files={path: files[path].replace("/bin/bash", "/bin/sh")},
        )
        self.assertEqual(model.clusters([left, changed], [], 0.8), [])
        self.assertNotEqual(
            syntax.script_shape(path, files[path], "org/left", {}),
            syntax.script_shape(
                path,
                files[path].replace("/bin/bash", "/bin/sh"),
                "org/right",
                {},
            ),
        )

    def test_interpreter_memoization(self) -> None:
        """Repeated calls to one path must cache independently by interpreter."""
        path = "tools/check.sh"
        original = "if False:\n    print('A')\nprint('B')\n"
        changed = "if False:\n    print('A')\n    print('B')\n"
        for commands in (
            [f"bash {path}", f"python {path}"],
            [f"python {path}", f"bash {path}"],
        ):
            for combined in (True, False):
                with self.subTest(commands=commands, combined=combined):
                    runs = ["; ".join(commands * 2)] if combined else commands * 2
                    block = {"steps": [{"run": run} for run in runs]}
                    left = job_unit("org/left", block, files={path: original})
                    right = job_unit("org/right", block, files={path: changed})
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])
        resolver = syntax.SourceResolver("org/example", {path: original})
        for command in commands * 2:
            self.assertEqual(
                resolver.command(command),
                syntax.command_shape(command, "org/example", {path: original}),
            )
        self.assertEqual(len(resolver.scripts), 2)

    def test_unsupported_script_interpreters(self) -> None:
        """Unsupported languages and ambiguous options cannot establish equality."""
        path = "tools/check.py"
        for prefix in (
            "node",
            "ruby",
            "perl",
            "pwsh",
            "zsh",
            "python -n",
            "python -o pipefail",
        ):
            with self.subTest(prefix=prefix):
                block = {"steps": [{"run": f"{prefix} {path}"}]}
                units = [
                    job_unit(repo, block, files={path: "print(8 / 2)\n"})
                    for repo in ("org/left", "org/right")
                ]
                self.assertEqual(model.clusters(units, [], 0.8), [])
        for header in (
            "#!/usr/bin/node",
            "#!/usr/bin/env python3 -u",
            "#!/usr/bin/env -S python3 -u",
            "#!/custom/python3",
        ):
            with self.subTest(header=header):
                block = {"steps": [{"run": f"./{path}"}]}
                units = [
                    job_unit(repo, block, files={path: header + "\nprint(8 / 2)\n"})
                    for repo in ("org/left", "org/right")
                ]
                self.assertEqual(model.clusters(units, [], 0.8), [])

    def test_interpreter_safe_equivalence(self) -> None:
        """Explicit Python ignores shebangs and still compares safe parameters."""
        path = "tools/check.sh"
        original = "\n".join(
            (
                "#!/bin/bash",
                "if True:",
                "    print('build/output')",
                "    print(8 // 2)",
                "",
            )
        )
        changed = "\n".join(
            (
                "#!/usr/bin/node",
                "# comment",
                "if True:",
                "  print( 'dist/result' )",
                "  print(8 // 2)",
                "",
            )
        )
        for prefix in ("python", "python3 -B", "uv run python3"):
            with self.subTest(prefix=prefix):
                block = {"steps": [{"run": f"{prefix} {path}"}]}
                left = job_unit("org/left", block, files={path: original})
                right = job_unit("org/right", block, files={path: changed})
                self.assertNotIn("<unresolved-", " ".join(left.shape))
                self.assertEqual(left.fingerprint, right.fingerprint)
                self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)


if __name__ == "__main__":
    unittest.main()
