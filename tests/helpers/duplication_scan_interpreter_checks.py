# SPDX-License-Identifier: MIT
"""Actual script-interpreter regressions exercised through scanner jobs."""

from __future__ import annotations

import unittest

from duplication_scan_regression_checks import job_unit
from duplication_scan_support import FixtureCase, model, syntax


class Cases(FixtureCase):
    """An executable's interpreter takes precedence over its filename suffix."""

    def assert_bare_runner_changes_distinct(self, original: str, changed: str) -> None:
        """Exercise runner entrypoints, wrappers and recursive shell calls."""
        path = "scripts/check.py"
        for runner in ("uv run", "bun run"):
            for wrapper in (
                "{}",
                "env MODE=test {}",
                "sudo {}",
                "if true; then {}; fi",
            ):
                command = wrapper.format(f"{runner} {path}")
                files = {path: original, "scripts/wrapper.sh": command}
                for run in (command, "bash scripts/wrapper.sh"):
                    with self.subTest(command=command, run=run):
                        block = {"steps": [{"run": run}]}
                        left = job_unit("org/left", block, files=files)
                        right = job_unit(
                            "org/right",
                            block,
                            files={**files, path: changed},
                        )
                        self.assertNotEqual(left.fingerprint, right.fingerprint)
                        self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_bare_runner_python_flow(self) -> None:
        """Bare runners must not erase changed Python conditional membership."""
        self.assert_bare_runner_changes_distinct(
            "if False:\n    print('A')\nprint('B')\n",
            "if False:\n    print('A')\n    print('B')\n",
        )

    def test_bare_runner_python_operators(self) -> None:
        """Bare runners must not erase different Python floor-divisor operands."""
        self.assert_bare_runner_changes_distinct(
            "value = 8 // 2\nprint(value)\n",
            "value = 8 // 3\nprint(value)\n",
        )

    def test_runner_execution_opaque(self) -> None:
        """Runner dispatch cannot prove a language or inspect package scripts."""
        repos = ("org/left", "org/right")
        for command, path in (
            ("uv run {path}", "scripts/check.py"),
            ("uv run {path}", "scripts/check.sh"),
            ("uv run {path}", "tools/check"),
            ("bun run {path}", "scripts/check.py"),
            ("bun run {path}", "scripts/check.ts"),
            ("bun run {path}", "scripts/check.js"),
            ("bun run python3 {path}", "scripts/check.py"),
            ("bun run bash {path}", "scripts/check.sh"),
            ("uv run --project app {path}", "scripts/check.py"),
            ("uv run python3 -X dev {path}", "scripts/check.py"),
            ("bun run --bun {path}", "scripts/check.js"),
            ("custom-runner {path}", "scripts/check.py"),
        ):
            for header in ("", "#!/usr/bin/python3\n", "#!/bin/bash\n"):
                with self.subTest(command=command, path=path, header=header):
                    block = {"steps": [{"run": command.format(path=path)}]}
                    files = {path: header + "print('build/output')\n"}
                    units = [job_unit(repo, block, files=files) for repo in repos]
                    self.assertEqual(model.clusters(units, [], 0.8), [])

    def test_runner_execution_memoization(self) -> None:
        """A shared path keeps runner and direct execution caches independent."""
        path = "scripts/check.py"
        files = {path: "#!/bin/bash\nprint('build/output')\n"}
        commands = [
            f"bash {path}",
            f"uv run {path}",
            f"bun run {path}",
            f"python3 {path}",
            f"uv run python3 {path}",
        ]
        for ordered in (commands, list(reversed(commands))):
            resolver = syntax.SourceResolver("org/example", files)
            for command in ordered * 2:
                self.assertEqual(
                    resolver.command(command),
                    syntax.command_shape(command, "org/example", files),
                )
            self.assertEqual(len(resolver.scripts), len(commands))
            for repo in ("org/left", "org/right"):
                # Warm a supported shell entry before revisiting opaque runners.
                resolver = syntax.SourceResolver(repo, files)
                resolver.command(f"bash {path}")
                for command in commands[1:3]:
                    self.assertNotEqual(
                        resolver.command(command),
                        syntax.command_shape(command, "org/other", files),
                    )

    def test_runner_nested_actions_and_dependencies(self) -> None:
        """Recursive actions preserve explicit Python and opaque dependency guards."""
        action = ".github/actions/check/action.yml"
        nested = ".github/actions/nested/action.yml"
        path = "scripts/check.py"
        block = {"steps": [{"uses": "./.github/actions/check"}]}
        repos = ("org/left", "org/right")
        for command, source, comparable in (
            (f"uv run python3 {path}", "print('build/output')\n", True),
            (f"uv run {path}", "print('build/output')\n", False),
            (f"bun run {path}", "print('build/output')\n", False),
            (f"uv run python3 {path}", "import helper\nhelper.check()\n", False),
        ):
            with self.subTest(command=command, source=source):
                files = {
                    action: "runs:\n  using: composite\n  steps:\n"
                    "    - uses: ./.github/actions/nested\n",
                    nested: "runs:\n  using: composite\n  steps:\n"
                    f"    - shell: bash\n      run: {command}\n",
                    path: source,
                    "scripts/helper.py": "def check():\n    print('check')\n",
                }
                units = [job_unit(repo, block, files=files) for repo in repos]
                self.assertEqual(len(model.clusters(units, [], 0.8)), int(comparable))

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
                self.assert_units_equivalent(left, right)
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
                self.assert_units_equivalent(left, right)


if __name__ == "__main__":
    unittest.main()
