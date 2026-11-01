# SPDX-License-Identifier: MIT
"""Offline escaped-command, assignment and binary-comparison regressions."""

from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from duplication_scan_regression_checks import ACTION, WORKFLOW
from duplication_scan_selection_checks import SelectionCase
from duplication_scan_support import FakeGitHub, model, offline_cli, scan, syntax


class Cases(SelectionCase):
    """Exercise actual resolution, inventory, catalog matching and dry-run CLI."""

    def test_assignment_escape_directory_inventory(self) -> None:
        """Escaped assignment separators cannot hide the executed app script."""
        for command in (
            r"X=a\ b cd app",
            r"X=a\ b \cd app",
            r"X=a\;b cd app",
            r"X=a\ b pushd app",
            "echo \\;\n" + r"X=a\ b cd app",
        ):
            source = command + "\nbash scripts/check.sh"
            files = {
                **self._runner_path_files(source),
                "scripts/check.sh": "#!/bin/sh\necho root\n",
                "app/scripts/check.sh": "#!/bin/sh\nrm -rf build\n",
            }
            right = {**files, "app/scripts/check.sh": "#!/bin/sh\necho ok\n"}
            with self.subTest(source=source):
                self.assert_matching_paths(files, right, {"scripts/check.sh"})
                self.assertNotEqual(
                    syntax.command_shape(source, "org/left", files),
                    syntax.command_shape(source, "org/right", right),
                )

    def test_assignment_escape_selection_inventory(self) -> None:
        """Assignment escapes cannot conceal PATH writes or module dispatch."""
        for source in (r"X=a\ b read PATH" + "\nhelper", r"X=a\ b python -m check"):
            files = {
                **self._runner_path_files(source),
                "check.py": "print('left')\n",
            }
            right = {
                **files,
                "tools/release/bin/helper": "#!/bin/sh\necho different\n",
                "check.py": "raise SystemExit(7)\n",
            }
            for caller in (self.assert_inventory_opaque, self.assert_cli_opaque):
                with self.subTest(source=source, caller=caller.__name__):
                    caller(files, right)

    def test_assignment_escape_guards(self) -> None:
        """Stop before lookup at bounded prefix, wrapper and control positions."""
        for assignment in (
            r"X=a\ b",
            r"X=a\;b",
            r"X=a\&b",
            r"X=a\|b",
            r"X=a\\\ b",
            "X=a\\\tb",
        ):
            for prefix in (
                "",
                "Y= ",
                "env ",
                "command ",
                "if true; then ",
                "{ ",
                "echo \\;\n",
            ):
                source = prefix + assignment + " cd app\nbash scripts/check.sh"
                with (
                    self.subTest(source=source),
                    patch.object(
                        syntax.SourceResolver,
                        "script",
                        side_effect=AssertionError,
                    ),
                ):
                    shape = syntax.command_shape(
                        source, "org/left", {"scripts/check.sh": "echo root\n"}
                    )
                    self.assertIn("<unresolved-", shape)

    def test_assignment_escape_data_controls(self) -> None:
        """Ordinary assignment escapes and inert prefix-like arguments qualify."""
        for source in (
            r"X=a\b echo tools/release/bin",
            r"X=a\\b echo tools/release/bin",
            r"X=a\\ echo tools/release/bin",
            r"echo X=a\ b tools/release/bin",
            r"echo 'X=a\ b cd app' tools/release/bin",
            r'echo "X=a\;b cd app" tools/release/bin',
            "# X=a\\ b cd app\necho tools/release/bin",
            r"echo \; X=a\ b cd app; echo tools/release/bin",
        ):
            files = self._runner_path_files(source)
            right = self._runner_path_files(source.replace("release", "check"))
            with self.subTest(source=source):
                self.assert_matching_paths(
                    files,
                    right,
                    {WORKFLOW, ACTION, "scripts/prepare.sh", "scripts/mutate.sh"},
                )

    def test_find_exec_terminator_controls(self) -> None:
        """An escaped find terminator is data; a later escaped command is not."""
        find = r"find . -exec rm {} \;"
        files = self._runner_path_files(find + "\necho tools/release/bin")
        right = self._runner_path_files(find + "\necho tools/check/bin")
        with self.subTest(control="data"):
            self.assert_matching_paths(
                files,
                right,
                {WORKFLOW, ACTION, "scripts/prepare.sh", "scripts/mutate.sh"},
            )
        for command in (r"\cd app", r"\python -m check", r"c\d app"):
            source = find + "\n" + command + "\nbash scripts/check.sh"
            files = {
                **self._runner_path_files(source),
                "scripts/check.sh": "#!/bin/sh\necho root\n",
                "app/scripts/check.sh": "#!/bin/sh\nrm -rf build\n",
            }
            right = {**files, "app/scripts/check.sh": "#!/bin/sh\necho ok\n"}
            with self.subTest(control=command):
                self.assert_matching_paths(files, right, {"scripts/check.sh"})

    def assert_matching_paths(
        self, files: dict[str, str], right: dict[str, str], expected: set[str]
    ) -> None:
        """Only the known comparable units may qualify, including in CLI output."""
        left, other, catalog = (
            model.units(repo, False, inventory, reference)
            for repo, inventory, reference in (
                ("org/left", files, ""),
                ("org/right", right, ""),
                ("lgtm-hq/lgtm-ci", files, "check"),
            )
        )
        for caller, groups in (
            ("inventory", model.clusters([*left, *other], [], 0.8)),
            ("catalog", model.clusters(other, catalog, 0.8)),
        ):
            with self.subTest(caller=caller):
                self.assertEqual(
                    {u.path for members, _, _ in groups for u in members},
                    expected,
                )
        api = FakeGitHub(
            repositories=[
                {
                    "full_name": repo,
                    "private": False,
                    "archived": False,
                    "files": source,
                }
                for repo, source in (("org/left", files), ("org/right", right))
            ]
        )
        output = io.StringIO()
        with (
            offline_cli(True),
            patch.object(scan, "references", return_value=catalog),
            patch.object(scan, "GitHub", return_value=api),
            patch.object(scan.subprocess, "run", side_effect=AssertionError),
            redirect_stdout(output),
        ):
            self.assertEqual(scan.main(), 0)
        report = output.getvalue().split("## Public near matches", 1)[0]
        for path in {unit.path for unit in left}:
            self.assertEqual(f"`{path}`" in report, path in expected, report)
        self.assertEqual(api.writes, [])

    def test_escaped_directory_inventory(self) -> None:
        """Identical root scripts cannot conceal different executed subdir scripts."""
        for source in (
            "\\cd subdir\nbash scripts/check.sh",
            "c\\d subdir\nbash scripts/check.sh",
            "X= command \\cd subdir\nbash scripts/check.sh",
            "if true; then \\cd subdir; fi\nbash scripts/check.sh",
            "( \\cd subdir; bash scripts/check.sh )",
        ):
            files = {
                **self._runner_path_files(source),
                "scripts/check.sh": "#!/bin/sh\necho root\n",
                "subdir/scripts/check.sh": "#!/bin/sh\nexit 7\n",
            }
            right = {**files, "subdir/scripts/check.sh": "#!/bin/sh\necho ok\n"}
            with self.subTest(source=source):
                self.assertNotEqual(
                    syntax.command_shape(source, "org/left", files),
                    syntax.command_shape(source, "org/right", right),
                )
                self.assert_matching_paths(files, right, {"scripts/check.sh"})

    def test_escaped_executable_guards(self) -> None:
        """Escaped builtins, interpreters and wrappers stop before script lookup."""
        for command in (
            r"\pushd subdir",
            r"po\pd",
            r"\read PATH",
            r"\bash scripts/check.sh",
            r"ba\sh scripts/check.sh",
            r"\python -m check",
            r"\env python -m check",
            r"env \python -m check",
            r"uv run \python -m check",
            r"timeout 5 \bash scripts/check.sh",
            r"X= Y=z builtin \cd subdir",
            r"if true; then \command python -m check; fi",
            r"true && \exec python -m check",
            r"{ \cd subdir; }",
        ):
            source = command + "\nbash scripts/check.sh"
            with self.subTest(source=source):
                with patch.object(
                    syntax.SourceResolver,
                    "script",
                    side_effect=AssertionError,
                ):
                    shape = syntax.command_shape(
                        source, "org/left", {"scripts/check.sh": "echo root\n"}
                    )
                self.assertIn("<unresolved-", shape)
                files = self._runner_path_files(command)
                self.assert_inventory_opaque(files, files)
                self.assert_cli_opaque(files, files)

    def test_escaped_data_controls(self) -> None:
        """Literal escapes in arguments, assignments and comments remain data."""
        for source in (
            r"echo \cd tools/release/bin",
            r"echo 'note; \cd subdir' tools/release/bin",
            r'echo "note; \bash check" tools/release/bin',
            r"printf '%s\n' '\python -m check' tools/release/bin",
            "# \\cd subdir\necho tools/release/bin",
            r"echo \; \cd; echo tools/release/bin",
            r"echo \& \bash; echo tools/release/bin",
            r"X=a\b echo tools/release/bin",
        ):
            files = self._runner_path_files(source)
            right = self._runner_path_files(source.replace("release", "check"))
            with self.subTest(source=source):
                self.assert_data_equivalent(source, source.replace("release", "check"))
                self.assert_matching_paths(
                    files,
                    right,
                    {WORKFLOW, ACTION, "scripts/prepare.sh", "scripts/mutate.sh"},
                )

    def test_quoted_assignment_caller(self) -> None:
        """Concatenated-word opacity already protects the reviewed cwd example."""
        source = 'FOO="a b" cd subdir\nbash scripts/check.sh'
        files = {
            **self._runner_path_files(source),
            "scripts/check.sh": "#!/bin/sh\necho root\n",
            "subdir/scripts/check.sh": "#!/bin/sh\nexit 7\n",
        }
        right = {**files, "subdir/scripts/check.sh": "#!/bin/sh\necho ok\n"}
        with patch.object(syntax.SourceResolver, "script", side_effect=AssertionError):
            shape = syntax.command_shape(source, "org/left", files)
        self.assertIn("<unresolved-shell-word:", shape)
        self.assert_matching_paths(files, right, {"scripts/check.sh"})
        control = self._runner_path_files("echo 'FOO=\"a b\" cd subdir'")
        self.assert_matching_paths(
            control,
            control,
            {WORKFLOW, ACTION, "scripts/prepare.sh", "scripts/mutate.sh"},
        )

    def test_binary_file_comparison_inventory(self) -> None:
        """True/false file identity and age conditions must not normalize alike."""
        for operator, first, second in (
            ("-ef", "tools/present/file", "tools/present/file"),
            ("-nt", "tools/present/file", "tools/missing/file"),
            ("-ot", "tools/missing/file", "tools/present/file"),
        ):
            # -ef is true for the same file; -nt/-ot distinguish present/missing
            # operands. Reverse the age tests, or use a missing file for -ef,
            # to build the false control without executing any shell source.
            false_operands = second, first
            if operator == "-ef":
                false_operands = first, "tools/missing/file"
            for spelling in (
                operator,
                f"'{operator}'",
                "\\" + operator,
                "-\\" + operator[1:],
            ):
                for template in ("test {}", "[ {} ]", "[[ {} ]]", "X= command test {}"):
                    if template.startswith("[[") and spelling != operator:
                        continue  # [[ requires a literal, unquoted binary operator.
                    source = template.format(f"{first} {spelling} {second}")
                    changed = template.format(
                        f"{false_operands[0]} {spelling} " f"{false_operands[1]}"
                    )
                    files, right = (
                        {
                            **self._runner_path_files(text),
                            "tools/present/file": "fixture",
                        }
                        for text in (source, changed)
                    )
                    with self.subTest(source=source):
                        self.assert_inventory_opaque(files, right)
                        self.assert_cli_opaque(files, right)

    def test_binary_file_comparison_controls(self) -> None:
        """Unary predicates and inert binary-comparison arguments still qualify."""
        for source in (
            "test -f tools/release/file",
            "[ -d tools/release/bin ]",
            "[ -e tools/release/file ]",
            "X= test -r tools/release/file",
            "echo 'test a/b -ef c/d' tools/release/bin",
            'echo "[ a/b -nt c/d ]" tools/release/bin',
            "# test a/b -ot c/d\ncat tools/release/file",
        ):
            files = self._runner_path_files(source)
            right = self._runner_path_files(source.replace("release", "check"))
            with self.subTest(source=source):
                self.assert_matching_paths(
                    files,
                    right,
                    {WORKFLOW, ACTION, "scripts/prepare.sh", "scripts/mutate.sh"},
                )


if __name__ == "__main__":
    unittest.main()
