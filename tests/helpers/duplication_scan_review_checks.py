# SPDX-License-Identifier: MIT
"""Offline R7 review reproductions, including real inventory and CLI callers."""

from __future__ import annotations

import io
import tokenize
import unittest
from unittest.mock import patch

import yaml
from duplication_scan_regression_checks import ACTION, WORKFLOW
from duplication_scan_selection_checks import SelectionCase
from duplication_scan_support import model, syntax


class Cases(SelectionCase):
    """Reject uninspected behavior while retaining ordinary path parameters."""

    def test_empty_assignment_guards(self) -> None:
        """Empty prefix values must reach every existing command-position guard."""
        resolver = syntax.SourceResolver
        for command, kind in (
            ("IFS= read -r PATH < .p\nhelper", "path"),
            ("X= printf -v PATH %s tools/bin\nhelper", "path"),
            ("X= export PATH=tools/bin\nhelper", "path"),
            ("X= cd app\nbash scripts/check.sh", "directory"),
            ("X= pushd app\nbash scripts/check.sh", "directory"),
            ("X= popd\nbash scripts/check.sh", "directory"),
            ("X= gh api /user/issues", "gh-api"),
            ("X= curl https://example.com/api", "http"),
            ("X= bash -c 'echo ready'", "shell-command"),
            ("X= python -m check", "shell-command"),
        ):
            for prefix in ("", "Y= ", "command "):
                source = prefix + command
                with (
                    self.subTest(source=source),
                    patch.object(resolver, "script", side_effect=AssertionError),
                ):
                    shape = syntax.command_shape(source, "org/left", {})
                    self.assertTrue(shape.startswith(f"<unresolved-{kind}:"), shape)

    def test_empty_assignment_inventory(self) -> None:
        """Wrong cwd/PATH must not qualify inline, nested, action or catalog units."""
        for source in (
            "IFS= read -r PATH < .p\nhelper",
            "X= printf -v PATH %s tools/bin\nhelper",
            "X= export PATH=tools/bin\nhelper",
            "X= cd app\nbash tools/check.sh",
        ):
            files = {
                **self._runner_path_files(source),
                ".p": "tools/release/bin\n",
                "tools/check.sh": "echo root\n",
                "app/tools/check.sh": "rm -rf build\n",
            }
            right = {
                **files,
                ".p": "tools/check/bin\n",
                "app/tools/check.sh": "echo ok\n",
            }
            with self.subTest(source=source):
                self.assert_inventory_opaque(files, right)
                self.assert_cli_opaque(files, right)

    def test_empty_assignment_controls(self) -> None:
        """Empty data prefixes still normalize paths and resolve called bodies."""
        for source in (
            "X= echo tools/release/bin",
            "X= Y= printf '%s' tools/release/bin",
            "X= printf -- -v tools/release/bin",
            "X= echo 'read -r PATH; cd app' tools/release/bin",
            "# X= read PATH\nX= cat tools/release/file",
        ):
            with self.subTest(source=source):
                self.assert_data_equivalent(source, source.replace("release", "check"))
        source = "X= bash scripts/check.sh"
        for directory in ("", "app"):
            path = directory + "/scripts/check.sh" if directory else "scripts/check.sh"
            files = {"scripts/check.sh": "echo root", path: "echo left"}
            shape = syntax.SourceResolver("org/left", files).command(source, directory)
            self.assertIn("<script:", shape)
            self.assertEqual(
                shape,
                syntax.SourceResolver("org/right", files).command(source, directory),
            )
            self.assertNotEqual(
                shape,
                syntax.SourceResolver("org/right", {**files, path: "exit 7"}).command(
                    source, directory
                ),
            )

    @staticmethod
    def action_files(default: str) -> dict[str, str]:
        """A default aliases a runner file, then a later step executes a helper."""
        return {
            ACTION: yaml.safe_dump(
                {
                    "inputs": {"dest": {"default": default}},
                    "runs": {
                        "using": "composite",
                        "steps": [
                            {
                                "shell": "bash",
                                "env": {"D": "${{ inputs.dest }}"},
                                "run": 'echo "$GITHUB_WORKSPACE/tools/bin" >> "$D"',
                            },
                            {"shell": "bash", "run": "helper"},
                        ],
                    },
                }
            ),
            WORKFLOW: yaml.safe_dump(
                {
                    "jobs": {
                        "check": {
                            "runs-on": "ubuntu-26.04",
                            "steps": [
                                {"uses": "./.github/actions/check"},
                                {"run": "helper"},
                            ],
                        }
                    }
                }
            ),
            "tools/bin/helper": "#!/bin/sh\nrm -rf build\n",
        }

    def test_action_input_defaults(self) -> None:
        """Both local expansion and standalone inventory inherit input opacity."""
        expressions = ("${{ github.path }}", "${{ GitHub.ENV }}")
        for expression in (*expressions, "${{ github['path'] }}"):
            files = self.action_files(expression)
            right = {**files, "tools/bin/helper": "#!/bin/sh\necho ok\n"}
            with self.subTest(expression=expression):
                shapes = [
                    syntax.SourceResolver(repo, inventory).action(
                        "./.github/actions/check", frozenset()
                    )
                    for repo, inventory in (("org/left", files), ("org/right", right))
                ]
                self.assertNotEqual(*shapes)
                self.assertIn("<unresolved-execution-context:", str(shapes[0]))
                self.assert_inventory_opaque(files, right)
                self.assert_cli_opaque(files, right)

    def test_action_input_controls(self) -> None:
        """Ordinary defaults and inert expression strings remain comparable."""
        for default in (
            "build/output",
            "github.path",
            "${{ 'github.path' }}",
            "${{ github.workspace }}",
        ):
            files = self.action_files(default)
            left = model.units("org/left", False, files)
            right = model.units("org/right", False, files)
            for first, second in zip(left, right, strict=True):
                with self.subTest(default=default, path=first.path):
                    self.assertNotIn("<unresolved-", " ".join(first.shape))
                    self.assert_units_equivalent(first, second)

    def test_python_literal_token_boundaries(self) -> None:
        """The raw helper must skip only nonsemantic tokens and literal grouping."""
        for expression in (
            '("GITHUB_"\n "PATH")',
            '("GITHUB_" # continuation\n "ENV")',
            '(b"GITHUB_"\n b"PATH")',
            '"GITHUB_" + ("PATH")',
            '("GITHUB_" +\n ("ENV"))',
        ):
            source = f"value = {expression}\n"
            tokens = list(tokenize.generate_tokens(io.StringIO(source).readline))
            with self.subTest(expression=expression):
                self.assertTrue(syntax.runner_file_reference(tokens))
        for source in (
            'a = "GITHUB_"\nb = "PATH"\n',
            'value = ("GITHUB_", "PATH")\n',
            'value = ("GITHUB_" + key + "PATH")\n',
            'value = ("GITHUB_" # inert\n "PATH_BACKUP")\n',
        ):
            tokens = list(tokenize.generate_tokens(io.StringIO(source).readline))
            with self.subTest(control=source):
                self.assertFalse(syntax.runner_file_reference(tokens))

    def test_python_literal_inventory(self) -> None:
        """The real caller guards multiline and grouped keys in all Python paths."""
        for expression in (
            '("GITHUB_"\n "PATH")',
            '("GITHUB_" # continuation\n "ENV")',
            '"GITHUB_" + ("PATH")',
        ):
            access = f"os.environ[{expression}]"
            source = f'import os\nopen({access}, "a").write("tools/release/bin")\n'
            files = {"scripts/runner.py": source}
            steps = [
                {"run": source, "shell": "python"},
                {"run": "python scripts/runner.py"},
            ]
            files[WORKFLOW] = yaml.safe_dump({"jobs": {"check": {"steps": steps}}})
            right = {k: v.replace("release", "check") for k, v in files.items()}
            with self.subTest(expression=expression):
                self.assert_inventory_opaque(files, right)
                self.assert_cli_opaque(files, right)

    def test_python_template_strings(self) -> None:
        """Template interpolation is executable syntax on Python 3.14 too."""
        for prefix in ("t", "tr", "rt", "T"):
            source = f'print({prefix}"{{a/b}}")\n'
            with self.subTest(prefix=prefix):
                shape = syntax.SourceResolver("org/left", {}).python(source)
                self.assertIn("<unresolved-", " ".join(shape))
                other = syntax.SourceResolver("org/right", {}).python(source)
                self.assertNotEqual(shape, other)
                files = {
                    "scripts/template.py": source,
                    WORKFLOW: yaml.safe_dump(
                        {
                            "jobs": {
                                "check": {
                                    "steps": [
                                        {"run": source, "shell": "python"},
                                        {"run": "python scripts/template.py"},
                                    ]
                                }
                            }
                        }
                    ),
                }
                self.assert_inventory_opaque(files, files)
                self.assert_cli_opaque(files, files)

    def test_shell_comparison_inventory(self) -> None:
        """True and false path-looking conditions cannot establish equivalence."""
        for source in (
            "test 'refs/heads/main' = 'refs/heads/main'",
            "[ 'refs/heads/main' = 'refs/heads/main' ]",
            "[[ 'refs/heads/main' == 'refs/heads/main' ]]",
            "X= test 'refs/heads/main' != 'refs/heads/main'",
            "if test 'refs/heads/main' = 'refs/heads/main'; then echo yes; fi",
            "test 'refs/heads/main' \\= 'refs/heads/main'",
        ):
            changed = source.replace("refs/heads/main", "refs/heads/release", 1)
            files, right = (self._runner_path_files(text) for text in (source, changed))
            with self.subTest(source=source):
                self.assert_inventory_opaque(files, right)
                self.assert_cli_opaque(files, right)

    def test_shell_comparison_controls(self) -> None:
        """Filesystem predicates and quoted/commented condition text stay data."""
        for source in (
            "test check = check",
            "[[ check == check ]] && echo ready",
            "test -f tools/release/file",
            "[ -d tools/release/bin ]",
            "X= test -e tools/release/file",
            "echo 'test a/b = a/c' tools/release/bin",
            "# test a/b = a/c\ncat tools/release/file",
        ):
            with self.subTest(source=source):
                self.assert_data_equivalent(source, source.replace("release", "check"))


if __name__ == "__main__":
    unittest.main()
