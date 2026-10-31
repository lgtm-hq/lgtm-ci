# SPDX-License-Identifier: MIT
"""Bounded shell-lexing regressions exercised by the scanner BATS suite."""

from __future__ import annotations

import unittest

import yaml
from duplication_scan_regression_checks import WORKFLOW, job_unit
from duplication_scan_support import FixtureCase, model, syntax


class ShellCases(FixtureCase):
    """Bounded shell recognition must preserve execution and word identities."""

    def assert_shell_inventory_distinct(
        self,
        source: str,
        changed: str,
        *,
        files: dict[str, str] | None = None,
        other_files: dict[str, str] | None = None,
    ) -> None:
        """Exercise inline runs, called wrappers and standalone shell scripts."""
        for shell in ("sh", "bash", "/bin/sh -e {0}", "bash --noprofile {0}"):
            inventories = []
            for repository, text, dependencies in (
                ("lgtm-hq/a", source, files),
                ("lgtm-hq/b", changed, other_files),
            ):
                workflow = yaml.safe_dump(
                    {
                        "jobs": {
                            name: {
                                "runs-on": "ubuntu-26.04",
                                "steps": [{"run": run, "shell": shell}],
                            }
                            for name, run in (
                                ("inline", text),
                                ("called", f"{shell.split()[0]} scripts/wrapper.sh"),
                            )
                        }
                    }
                )
                inventory = model.units(
                    repository,
                    False,
                    {
                        WORKFLOW: workflow,
                        "scripts/wrapper.sh": "#!/bin/sh\n" + text,
                        **(dependencies or {}),
                    },
                )
                paths = {WORKFLOW, "scripts/wrapper.sh"}
                inventories.append([unit for unit in inventory if unit.path in paths])
            with self.subTest(shell=shell):
                left, right = inventories[0], inventories[1]
                self.assertEqual(len(left), 3)
                self.assertEqual(len(right), 3)
                self.assertFalse(
                    {u.fingerprint for u in left} & {u.fingerprint for u in right},
                )
                self.assertEqual(model.clusters([*left, *right], [], 0.8), [])

    def test_parameter_hash_heredocs(self) -> None:
        """A parameter's whitespace-# must not hide a subsequent heredoc."""
        for prefix in ("echo ${x:- #}", "key=${line%% #*}"):
            source = prefix + " ; cat <<EOF\n#alpha\nEOF\n"
            changed = source.replace("#alpha", "#beta")
            with self.subTest(prefix=prefix):
                self.assertNotEqual(
                    syntax.command_shape(source, "lgtm-hq/a", {}),
                    syntax.command_shape(changed, "lgtm-hq/b", {}),
                )
                self.assert_shell_inventory_distinct(source, changed)

    def test_parameter_hash_executables(self) -> None:
        """Commands and called bodies after parameter expansions stay significant."""
        for prefix in ("echo ${x:- #}", "key=${line%% #*}"):
            with self.subTest(prefix=prefix):
                source = prefix + "; bash scripts/a.sh"
                left = {"scripts/a.sh": "rm -rf build\n"}
                right = {"scripts/a.sh": "echo ok\n"}
                self.assertNotEqual(
                    syntax.command_shape(source, "lgtm-hq/a", left),
                    syntax.command_shape(source, "lgtm-hq/b", right),
                )
                self.assert_shell_inventory_distinct(
                    source,
                    source,
                    files=left,
                    other_files=right,
                )
                self.assert_shell_inventory_distinct(
                    prefix + "; rm -rf build", prefix + "; echo ok"
                )

    def test_parameter_substitutions_opaque(self) -> None:
        """Bounded expansions must not conceal substitutions or nested syntax."""
        for source in (
            "echo ${x:- #$(bash scripts/a.sh)}",
            "echo ${x:- #`bash scripts/a.sh`}",
            "echo ${x:-${line%% #*}}; bash scripts/a.sh",
            "echo ${x:-\n #}; bash scripts/a.sh",
        ):
            with self.subTest(source=source):
                left = {"scripts/a.sh": "echo alpha\n"}
                right = {"scripts/a.sh": "echo beta\n"}
                self.assertNotEqual(
                    syntax.command_shape(source, "lgtm-hq/a", left),
                    syntax.command_shape(source, "lgtm-hq/b", right),
                )
                self.assert_shell_inventory_distinct(
                    source,
                    source,
                    files=left,
                    other_files=right,
                )

    def test_posix_nested_subshell_heredocs(self) -> None:
        """Bare (( can be nested sh subshells; only $(( proves arithmetic."""
        source = "((cat <<EOF))\n#alpha\nEOF\n"
        changed = source.replace("#alpha", "#beta")
        self.assertNotEqual(
            syntax.command_shape(source, "lgtm-hq/a", {}),
            syntax.command_shape(changed, "lgtm-hq/b", {}),
        )
        self.assert_shell_inventory_distinct(source, changed)

    def test_escaped_quotes_heredocs(self) -> None:
        """Quote-mask desync must still trigger the adjacent-word opacity guard."""
        for prefix in (r"echo \'", r"echo \"", r"echo $'a\'b'"):
            source = prefix + " ; cat <<EOF\n#alpha\nEOF\n"
            changed = source.replace("#alpha", "#beta")
            with self.subTest(prefix=prefix):
                shape = syntax.command_shape(source, "lgtm-hq/a", {})
                self.assertTrue(shape.startswith("<unresolved-"))
                self.assertNotEqual(
                    shape,
                    syntax.command_shape(changed, "lgtm-hq/b", {}),
                )
                self.assert_shell_inventory_distinct(source, changed)

    def test_shell_comment_words_executables(self) -> None:
        """C-style comment markers are shell arguments, including separators."""
        for prefix, suffix in (
            ("echo ok // note; ", ""),
            ("echo ok /* note; ", " # */"),
        ):
            source = prefix + "./tools/release" + suffix
            changed = prefix + "./tools/check" + suffix
            left = {"tools/release": "#!/bin/sh\necho release\n"}
            right = {"tools/check": "#!/bin/sh\necho check\n"}
            with self.subTest(prefix=prefix):
                self.assertNotEqual(
                    syntax.command_shape(source, "lgtm-hq/a", left),
                    syntax.command_shape(changed, "lgtm-hq/b", right),
                )
                self.assert_shell_inventory_distinct(
                    source,
                    changed,
                    files=left,
                    other_files=right,
                )
                # A shared inspected implementation still compares equal
                # when its executable path differs between repositories.
                same = {"tools/check": left["tools/release"]}
                self.assertEqual(
                    syntax.command_shape(source, "lgtm-hq/a", left),
                    syntax.command_shape(changed, "lgtm-hq/b", same),
                )
                self.assert_units_equivalent(
                    job_unit("lgtm-hq/a", {"steps": [{"run": source}]}, files=left),
                    job_unit("lgtm-hq/b", {"steps": [{"run": changed}]}, files=same),
                )

    def test_continued_directory_commands(self) -> None:
        """Split command names cannot resolve scripts from the root directory."""
        left = {
            "scripts/check.sh": "echo identical root\n",
            "subdir/scripts/check.sh": "echo alpha\n",
        }
        right = {**left, "subdir/scripts/check.sh": "echo beta\n"}
        for directory in ("c\\\nd subdir", "pu\\\nshd subdir", "cd\\\n subdir"):
            source = directory + "\nbash scripts/check.sh"
            with self.subTest(directory=directory):
                self.assertNotEqual(
                    syntax.command_shape(source, "lgtm-hq/a", left),
                    syntax.command_shape(source, "lgtm-hq/b", right),
                )
                self.assert_shell_inventory_distinct(
                    source,
                    source,
                    files=left,
                    other_files=right,
                )

    def test_shell_lexing_controls(self) -> None:
        """Ordinary shell data/arithmetic and non-shell comments keep semantics."""
        for source in (
            "echo ${x:- #}",
            "key=${line%% #*}; echo ok",
            "echo $((1 << 2))",
            "echo ok // note; echo done",
            "echo ok /* note */; echo done",
            "echo 'c d subdir'; echo done # cd somewhere",
            r"echo \ #data",
        ):
            with self.subTest(source=source):
                left = syntax.command_shape(source, "lgtm-hq/a", {})
                self.assertNotIn("<unresolved-", left)
                self.assertEqual(left, syntax.command_shape(source, "lgtm-hq/b", {}))
                self.assert_units_equivalent(
                    job_unit("lgtm-hq/a", {"steps": [{"run": source}]}),
                    job_unit("lgtm-hq/b", {"steps": [{"run": source}]}),
                )
        self.assertEqual(
            syntax.normalize("// comment\nconsole.log(1)", "org/a"),
            "console.log(1)",
        )
        self.assertEqual(
            syntax.normalize("/* comment */console.log(1)", "org/a"),
            "console.log(1)",
        )

    def test_heredoc_command_shapes(self) -> None:
        """Literal payload comments must not disappear from command identities."""
        for header, indent in (
            ("cat <<EOF", ""),
            ("cat <<'EOF'", ""),
            ('cat <<"EOF"', ""),
            ("cat <<\\EOF", ""),
            ("cat <<-EOF", "\t"),
            ("cat <<-'EOF'", "\t"),
            ("cat <\\\n<EOF", ""),
            ("cat /dev/stdin // <<EOF", ""),
            ("cat /dev/stdin /* <<EOF", ""),
            ("echo ready # comment \\\ncat <<EOF", ""),
            ("cat /dev/stdin \\ #data <<EOF", ""),
        ):
            source = f"{header}\n{indent}#alpha\n{indent}EOF\n"
            changed = source.replace("#alpha", "#beta")
            with self.subTest(header=header):
                shape = syntax.command_shape(source, "lgtm-hq/a", {})
                for repository, text in (
                    ("lgtm-hq/b", changed),
                    ("lgtm-hq/a", changed),
                    ("lgtm-hq/b", source),
                ):
                    other = syntax.command_shape(text, repository, {})
                    self.assertNotEqual(shape, other)
                self.assertTrue(shape.startswith("<unresolved-"))
                self.assertNotIn("#alpha", shape)

    def test_heredoc_inventory(self) -> None:
        """Inline workflows, called scripts and standalone scripts fail closed."""
        for header, indent in (("<<EOF", ""), ("<<'EOF'", ""), ("<<-'EOF'", "\t")):
            inventories = []
            for repository, payload in (
                ("lgtm-hq/a", "#alpha"),
                ("lgtm-hq/b", "#beta"),
                ("lgtm-hq/b", "#alpha"),
            ):
                source = f"cat {header}\n{indent}{payload}\n{indent}EOF\n"
                workflow = yaml.safe_dump(
                    {
                        "jobs": {
                            name: {"runs-on": "ubuntu-26.04", "steps": [{"run": run}]}
                            for name, run in (
                                ("inline", source),
                                ("script", "bash scripts/wrapper.sh"),
                            )
                        }
                    }
                )
                files = {
                    WORKFLOW: workflow,
                    "scripts/wrapper.sh": "#!/bin/sh\nbash scripts/check.sh\n",
                    "scripts/check.sh": "#!/bin/sh\n" + source,
                }
                inventories.append(model.units(repository, False, files))
            with self.subTest(header=header):
                left = inventories[0]
                self.assertEqual(len(left), 4)
                for right in inventories[1:]:
                    for original, other in zip(left, right, strict=True):
                        self.assertNotEqual(original.fingerprint, other.fingerprint)
                    self.assertEqual(model.clusters([*left, *right], [], 0.8), [])

    def test_heredoc_literal_boundaries(self) -> None:
        """Quoted data and comments containing heredoc markers remain supported."""
        for source in (
            "echo '<<EOF'",
            'echo "<<-EOF"',
            "printf '%s\\n' 'cat <<EOF\n#alpha\nEOF'",
            "# cat <<EOF\necho ready",
            "echo ready # <<EOF",
            "echo // '<<EOF'",
            'echo "$((8 << 1))"',
            "echo $((8 << 1))",
            "echo $((value << 1))",
            "cat scripts/data.txt",
        ):
            with self.subTest(source=source):
                left = syntax.command_shape(source, "lgtm-hq/a", {})
                right = syntax.command_shape(source, "lgtm-hq/b", {})
                self.assertNotIn("<unresolved-", left)
                self.assertEqual(left, right)
                self.assert_units_equivalent(
                    job_unit("lgtm-hq/a", {"steps": [{"run": source}]}),
                    job_unit("lgtm-hq/b", {"steps": [{"run": source}]}),
                )

    def test_shell_word_concatenation(self) -> None:
        """Adjacent quoted fragments must not become separate shell arguments."""
        for joined, separate in (
            ('"a""b"', '"a" "b"'),
            ("'a''b'", "'a' 'b'"),
            ("\"a\"'b'", "\"a\" 'b'"),
            ('a"b"', 'a "b"'),
            ('"a"b', '"a" b'),
            ('a""', 'a ""'),
            ('""a', '"" a'),
        ):
            left_command = f"printf '%s\\n' {joined}"
            right_command = f"printf '%s\\n' {separate}"
            with self.subTest(joined=joined):
                left = job_unit("org/left", {"steps": [{"run": left_command}]})
                right = job_unit("org/right", {"steps": [{"run": right_command}]})
                self.assertNotEqual(left.fingerprint, right.fingerprint)
                self.assertEqual(model.clusters([left, right], [], 0.8), [])
                left_script = syntax.script_shape(
                    "scripts/check.sh",
                    left_command,
                    "org/left",
                    {},
                )
                right_script = syntax.script_shape(
                    "scripts/check.sh",
                    right_command,
                    "org/right",
                    {},
                )
                self.assertNotEqual(left_script, right_script)
                # Unsupported concatenation must not match a copy in another repo.
                other = job_unit("org/right", {"steps": [{"run": left_command}]})
                self.assertEqual(model.clusters([left, other], [], 0.8), [])
        for command in (
            'printf \'%s\\n\' "a" "b"',
            "echo 'a  b'",
            'echo "a"; echo b',
            'cat "scripts/data.txt"',
            "gh api 'repos/org/project'",
        ):
            with self.subTest(command=command):
                left = job_unit("org/left", {"steps": [{"run": command}]})
                right = job_unit("org/right", {"steps": [{"run": command}]})
                self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
                tabbed = command.replace(" ", "\t", 1)
                self.assertEqual(
                    syntax.command_shape(command, "org/left", {}),
                    syntax.command_shape(tabbed, "org/right", {}),
                )

    def test_direct_script_shebangs(self) -> None:
        """Direct execution retains interpreter/flags; explicit shells override it."""
        path = "scripts/check.sh"
        body = '[[ "$MODE" == check ]] && echo ready\n'
        left_files = {path: "#!/bin/bash\n" + body}
        for header in ("#!/bin/sh", "#!/bin/bash -e", "#!/usr/bin/env bash", ""):
            right_files = {path: header + "\n" + body}
            with self.subTest(header=header):
                for command in (
                    f"./{path}",
                    f"env MODE=check ./{path}",
                    f"SHELL=bash ./{path}",
                    f"PYTHON=python3 ./{path}",
                    f"env SH=sh {path}",
                    f"VERSION=a. ./{path}",
                ):
                    with self.subTest(command=command):
                        block = {"steps": [{"run": command}]}
                        left = job_unit("org/left", block, files=left_files)
                        right = job_unit("org/right", block, files=right_files)
                        self.assertEqual(model.clusters([left, right], [], 0.8), [])
                        same = job_unit("org/right", block, files=left_files)
                        self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
                self.assertNotEqual(
                    syntax.script_shape(path, left_files[path], "org/left", {}),
                    syntax.script_shape(path, right_files[path], "org/right", {}),
                )
                for prefix in (
                    "bash",
                    "bash -u",
                    "sh",
                    "source",
                    ".",
                    "env bash",
                    "env SH=sh bash",
                    "SHELL=bash sh",
                ):
                    command = f"{prefix} {path}"
                    self.assertEqual(
                        syntax.command_shape(command, "org/left", left_files),
                        syntax.command_shape(command, "org/right", right_files),
                    )
        # A resolver may cache both explicit and direct execution of one file.
        for prefix in ("", f"bash {path}; "):
            command = prefix + f"./{path}"
            changed = {path: "#!/bin/sh\n" + body}
            self.assertNotEqual(
                syntax.command_shape(command, "org/left", left_files),
                syntax.command_shape(command, "org/right", changed),
            )


if __name__ == "__main__":
    unittest.main()
