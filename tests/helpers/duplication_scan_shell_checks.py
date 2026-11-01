# SPDX-License-Identifier: MIT
"""Bounded shell-lexing regressions exercised by the scanner BATS suite."""

from __future__ import annotations

import unittest
from unittest.mock import patch

import yaml
from duplication_scan_regression_checks import WORKFLOW, job_unit
from duplication_scan_support import FixtureCase, model, syntax


class CommentBoundaryCases(FixtureCase):
    """Comments cannot conceal executable positions or shift original offsets."""

    def test_comment_directory_guards(self) -> None:
        """Comment separators cannot permit resolving a script in the wrong cwd."""
        files = {
            "scripts/check.sh": "echo matching root copy",
            "app/scripts/check.sh": "echo app check",
        }
        for ending in [")", "(", ";", "|", "&", "{", "}"]:
            for directory in ("cd app", "pushd app", "popd"):
                source = f"# note {ending}\n{directory}; bash scripts/check.sh"
                with self.subTest(source=source):
                    with patch.object(
                        syntax.SourceResolver,
                        "script",
                        side_effect=AssertionError,
                    ):
                        shape = syntax.command_shape(source, "org/left", files)
                    self.assertTrue(shape.startswith("<unresolved-directory:"))
                    for run in (source, "bash scripts/wrapper.sh"):
                        units = [
                            job_unit(
                                repository,
                                {"steps": [{"run": run}]},
                                files={
                                    **files,
                                    "scripts/wrapper.sh": source,
                                    "app/scripts/check.sh": body,
                                },
                            )
                            for repository, body in (
                                ("org/left", "echo app check"),
                                ("org/right", "echo app release"),
                            )
                        ]
                        self.assertNotEqual(units[0].fingerprint, units[1].fingerprint)
                        self.assertEqual(model.clusters(units, [], 0.8), [])

    def test_comment_script_resolution(self) -> None:
        """Shared matches retain original path offsets and inspect actual scripts."""
        files = {"scripts/check.sh": "echo check", "check": "echo check"}
        commands = (
            (syntax.LOCAL_PROGRAM, "bash scripts/check.sh", "scripts/check.sh"),
            (syntax.INTERPRETED_PROGRAM, "bash check", "check"),
            (syntax.SCRIPT_PROGRAM, "bash check.sh", "check.sh"),
            (syntax.DYNAMIC_PROGRAM, "bash $SCRIPT", "$SCRIPT"),
        )
        for ending in ("ordinary note", *[")", "(", ";", "|", "&", "{", "}"]):
            prefix = f"# café {ending}\n"
            for pattern, command, path in commands:
                source = prefix + command + "; " + command
                with self.subTest(source=source, pattern=pattern.pattern):
                    matches = syntax.executable_matches(pattern, source)
                    self.assertEqual(len(matches), 2)
                    for match in matches:
                        self.assertEqual(match["path"], path)
                        self.assertEqual(source[slice(*match.span("path"))], path)
                        self.assertGreaterEqual(match.start("path"), len(prefix))
            command = "bash scripts/check.sh; bash check"
            self.assertEqual(
                syntax.command_shape(prefix + command, "org/left", files),
                syntax.command_shape(command, "org/right", files),
            )
            self.assertNotEqual(
                syntax.command_shape(prefix + command, "org/left", files),
                syntax.command_shape(
                    prefix + command,
                    "org/right",
                    {**files, "scripts/check.sh": "echo release"},
                ),
            )
            inline = prefix + "bash -c 'echo ready'"
            self.assertTrue(
                syntax.command_shape(inline, "org/left", {}).startswith(
                    "<unresolved-shell-command:"
                )
            )
        # Even unsupported, unmatched quotes must not shift later source spans.
        for quote in ("'", '"'):
            source = f"{quote}; bash scripts/check.sh"
            matches = syntax.executable_matches(syntax.LOCAL_PROGRAM, source)
            self.assertEqual(len(matches), 1)
            match = matches[0]
            self.assertEqual(source[slice(*match.span("path"))], match["path"])

    def test_comment_literal_controls(self) -> None:
        """Comment contents and quoted command-like data never become executable."""
        for ending in [")", "(", ";", "|", "&", "{", "}"]:
            for source in (
                f"# gh api /user; cd app; bash scripts/unused.sh {ending}\necho ready",
                f"echo ready # gh api /user; cd app; bash scripts/unused.sh {ending}",
                f'echo "# note {ending}\ngh api /user; cd app; bash scripts/unused.sh"',
                f"echo '# note {ending}\ngh api /user; cd app; bash scripts/unused.sh'",
                f"# note {ending}\necho gh api /user",
                f"# note {ending}\necho '\"gh\" api /user'",
                f"# note {ending}\necho \"'gh' api /user\"",
            ):
                with self.subTest(source=source):
                    self.assertIsNone(syntax.shell_opacity(source))
                    with patch.object(
                        syntax.SourceResolver,
                        "script",
                        side_effect=AssertionError,
                    ):
                        shape = syntax.command_shape(source, "org/left", {})
                    self.assertNotIn("<unresolved-", shape)
                    self.assertEqual(
                        shape,
                        syntax.command_shape(source, "org/right", {}),
                    )
                    self.assert_units_equivalent(
                        job_unit("org/left", {"steps": [{"run": source}]}),
                        job_unit("org/right", {"steps": [{"run": source}]}),
                    )


class ShellCases(FixtureCase):
    """Bounded shell recognition must preserve execution and word identities."""

    @staticmethod
    def parameter_word_pairs() -> tuple[tuple[str, str], ...]:
        """Return inert scanner inputs; no shell source is ever executed."""
        return (
            ("ls -d ${dir}/*", "ls -d ${dir} /*"),
            ("echo pre${x}", "echo pre ${x}"),
            ("echo ${a}${b}", "echo ${a} ${b}"),
            ("echo ${x}post", "echo ${x} post"),
            ("echo pre${x}post", "echo pre ${x}post"),
        )

    def test_parameter_word_script_adjacency(self) -> None:
        """Re-splitting normalized scripts must retain shell word boundaries."""
        path = "scripts/check.sh"
        for source, changed in self.parameter_word_pairs():
            with self.subTest(source=source):
                scripts = [
                    model.file_units(repo, False, path, text, {}, "")[0]
                    for repo, text in (("org/left", source), ("org/right", changed))
                ]
                self.assertEqual(model.clusters(scripts, [], 0.8), [])
                self.assertNotEqual(
                    syntax.script_shape(path, source, "org/left", {}),
                    syntax.script_shape(path, changed, "org/left", {}),
                )
                self.assertNotEqual(scripts[0].fingerprint, scripts[1].fingerprint)
                same = model.file_units("org/right", False, path, source, {}, "")[0]
                self.assert_units_equivalent(scripts[0], same)

    def test_parameter_word_called_adjacency(self) -> None:
        """Called-script digests and workflow clusters preserve glued words."""
        path = "scripts/check.sh"
        for source, changed in self.parameter_word_pairs():
            with self.subTest(source=source):
                jobs = [
                    job_unit(
                        repo,
                        {"steps": [{"run": f"sh {path}"}]},
                        files={path: text},
                    )
                    for repo, text in (("org/left", source), ("org/right", changed))
                ]
                self.assertEqual(model.clusters(jobs, [], 0.8), [])
                self.assertNotEqual(
                    syntax.command_shape(f"sh {path}", "org/left", {path: source}),
                    syntax.command_shape(f"sh {path}", "org/left", {path: changed}),
                )
                # Inline command shaping already preserved these boundaries.
                self.assertNotEqual(
                    syntax.command_shape(source, "org/left", {}),
                    syntax.command_shape(changed, "org/left", {}),
                )

    def test_quoted_parameter_opacity(self) -> None:
        """An incomplete expansion inside quotes cannot conceal executable text."""
        source = 'echo "${x:-" a # "}"; ./tools/release'
        changed = source.replace("tools/release", "tools/check")
        left = {"tools/release": "#!/bin/sh\necho release\n"}
        right = {"tools/check": "#!/bin/sh\necho check\n"}
        self.assertNotEqual(
            syntax.command_shape(source, "org/left", left),
            syntax.command_shape(changed, "org/right", right),
        )
        for prefix in ('echo "${x:-" a # "}"', 'echo "${safe} ${x:-" a # "}"'):
            with self.subTest(prefix=prefix):
                self.assertEqual(syntax.shell_opacity(prefix), "shell-expansion")
                self.assertNotEqual(
                    syntax.command_shape(prefix, "org/left", {}),
                    syntax.command_shape(prefix, "org/right", {}),
                )

    def test_quoted_parameter_inventory(self) -> None:
        """Inline, called and standalone sources with hidden commands stay apart."""
        source = 'echo "${x:-" a # "}"; ./tools/release'
        left = {"tools/release": "#!/bin/sh\necho release\n"}
        right = {"tools/check": "#!/bin/sh\necho check\n"}
        self.assert_shell_inventory_distinct(
            source,
            source.replace("tools/release", "tools/check"),
            files=left,
            other_files=right,
        )
        self.assert_shell_inventory_distinct(
            source,
            source,
            files=left,
            other_files={"tools/release": right["tools/check"]},
        )

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
            "echo ${line%% #*}; echo ok",
            'echo "${x:- #}"',
            'echo "${a}${b}"',
            'echo "${{ github.repository }}"',
            "echo '${x:-\" a # \"}'; echo done",
            'echo ok # "${x:-" a # "}"',
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
        body = "[[ check == check ]] && echo ready\n"
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


class HttpCases(unittest.TestCase):
    """HTTP endpoints and request payloads are behavior, never path inputs."""

    @staticmethod
    def request_pairs() -> tuple[tuple[str, str], ...]:
        """Return inert URL and payload differences without issuing requests."""
        endpoint = "https://api.example.com/deploy"
        return (
            (endpoint, "https://api.example.com/delete"),
            (endpoint, "https://other.example.com/deploy"),
            (endpoint, "http://api.example.com/deploy"),
            (f"'{endpoint}?target=release/prod'", f"'{endpoint}?target=release/test'"),
            (f"'{endpoint}?mode=deploy'", f"'{endpoint}?mode=delete'"),
            (f"-X POST {endpoint}", f"-X DELETE {endpoint}"),
            (
                f'--data \'{{"target":"release/prod"}}\' {endpoint}',
                f'--data \'{{"target":"release/test"}}\' {endpoint}',
            ),
            (
                f"--data @./requests/deploy.json {endpoint}",
                f"--data @./requests/delete.json {endpoint}",
            ),
        )

    def test_http_endpoint_shapes(self) -> None:
        """Inline, standalone and forwarded URL arguments retain request identity."""
        files = {"scripts/request.sh": '#!/bin/sh\ncurl "$@"'}
        path = "scripts/check.sh"
        for left, right in self.request_pairs():
            for prefix in ("bash scripts/request.sh --fail ", "curl --fail "):
                source, changed = prefix + left, prefix + right
                with self.subTest(source=source, changed=changed):
                    self.assertNotEqual(
                        syntax.command_shape(source, "org/example", files),
                        syntax.command_shape(changed, "org/example", files),
                    )
                    self.assertNotEqual(
                        syntax.script_shape(path, source, "org/example", files),
                        syntax.script_shape(path, changed, "org/example", files),
                    )

    def test_http_dynamic_shapes(self) -> None:
        """Unknown endpoints and payloads cannot establish HTTP equivalence."""
        for source in (
            'curl --fail "${{ inputs.first }}"',
            'curl --data "${{ inputs.first }}" "$ENDPOINT"',
            'wget --quiet "${{ inputs.first }}"',
            'wget --post-data="${{ inputs.first }}" "$ENDPOINT"',
            'http "${{ inputs.first }}"',
            'http POST "$ENDPOINT" "body=${{ inputs.first }}"',
            'https "${{ inputs.first }}"',
            'https POST "$ENDPOINT" "body=${{ inputs.first }}"',
        ):
            changed = source.replace("inputs.first", "inputs.second")
            with self.subTest(source=source):
                self.assertNotEqual(
                    syntax.command_shape(source, "org/example", {}),
                    syntax.command_shape(changed, "org/example", {}),
                )
                self.assertNotEqual(
                    syntax.command_shape(source, "org/left", {}),
                    syntax.command_shape(source, "org/right", {}),
                )

    def test_http_inventory(self) -> None:
        """Identical and changed requests cannot cluster or match a catalog."""
        sources = (
            "curl --fail https://api.example.com/deploy",
            'curl --fail "${{ inputs.endpoint }}"',
            'curl --data "${{ inputs.payload }}" "$ENDPOINT"',
        )
        for source in sources:
            with self.subTest(source=source):
                left = GhApiCases.inventory("org/left", source)
                reference = GhApiCases.inventory("lgtm-hq/lgtm-ci", source, "check")
                self.assertEqual(len(left), 5)
                fingerprints = {unit.fingerprint for unit in left}
                for command in (source, source.replace("deploy", "delete")):
                    right = GhApiCases.inventory("org/right", command)
                    observed = {unit.fingerprint for unit in right}
                    self.assertFalse(fingerprints & observed)
                    self.assertEqual(model.clusters([*left, *right], [], 0.8), [])
                    self.assertEqual(model.clusters(right, reference, 0.8), [])

    def test_http_boundaries_and_controls(self) -> None:
        """Wrappers and quotes stay opaque while comments and ordinary data work."""
        for prefix, suffix in (
            ("", ""),
            ("command ", ""),
            ("env MODE=scan ", ""),
            ("if ", "; then echo done; fi"),
            ("(", ")"),
            ("echo ready && ", " | cat"),
            ("# note (\n", ""),
        ):
            for client in ("curl", "wget", "http", "https"):
                for quote in ("", "'", '"'):
                    source = f'{prefix}{quote}{client}{quote} "$ENDPOINT"{suffix}'
                    with self.subTest(source=source):
                        shape = syntax.command_shape(source, "org/left", {})
                        self.assertTrue(shape.startswith("<unresolved-http:"), shape)
        with patch.object(syntax.SourceResolver, "script", side_effect=AssertionError):
            shape = syntax.command_shape(
                "bash scripts/request.sh https://api.example.com/deploy",
                "org/left",
                {"scripts/request.sh": 'curl "$@"'},
            )
            self.assertTrue(shape.startswith("<unresolved-http:"), shape)
        for source in (
            "# curl https://api.example.com/deploy\necho ready",
            "echo ready # wget https://api.example.com/delete",
            "echo curl",
            "printf '%s' 'wget --help'",
        ):
            with self.subTest(source=source):
                self.assertIsNone(syntax.shell_opacity(source))
                self.assertEqual(
                    syntax.command_shape(source, "org/left", {}),
                    syntax.command_shape(source, "org/right", {}),
                )
        self.assertEqual(
            syntax.command_shape("cat ./data/first.json", "org/left", {}),
            syntax.command_shape("cat ./data/second.json", "org/right", {}),
        )


class GhApiCases(unittest.TestCase):
    """Unmodeled API operations cannot prove copies of jobs, actions or scripts."""

    def test_gh_api_comment_boundaries(self) -> None:
        """Comment-ending operators cannot consume the next API command boundary."""
        for ending in ("ordinary note", *[")", "(", ";", "|", "&", "{", "}"]):
            for prefix in (f"# note {ending}\n", f"echo ready # note {ending}\n"):
                source = prefix + "gh api -X DELETE /user"
                changed = prefix + "gh api -X DELETE /orgs"
                with self.subTest(source=source):
                    self.assertEqual(syntax.shell_opacity(source), "gh-api")
                    self.assertNotEqual(
                        syntax.command_shape(source, "org/example", {}),
                        syntax.command_shape(changed, "org/example", {}),
                    )
                    left = self.inventory("org/left", source)
                    for command in (source, changed):
                        right = self.inventory("org/right", command)
                        self.assertEqual(model.clusters([*left, *right], [], 0.8), [])
                        self.assertEqual(
                            model.clusters(
                                right,
                                self.inventory("lgtm-hq/lgtm-ci", source, "check"),
                                0.8,
                            ),
                            [],
                        )

    def test_gh_api_quoted_commands(self) -> None:
        """Single- and double-quoted gh command names retain API opacity."""
        for quote in ("'", '"'):
            for prefix in ("", "# note (x)\n", "command "):
                source = f"{prefix}{quote}gh{quote} api /user"
                changed = f"{prefix}{quote}gh{quote} api /orgs"
                with self.subTest(source=source):
                    self.assertEqual(syntax.shell_opacity(source), "gh-api")
                    self.assertNotEqual(
                        syntax.command_shape(source, "org/example", {}),
                        syntax.command_shape(changed, "org/example", {}),
                    )
                    left = self.inventory("org/left", source)
                    for command in (source, changed):
                        self.assertEqual(
                            model.clusters(
                                [*left, *self.inventory("org/right", command)],
                                [],
                                0.8,
                            ),
                            [],
                        )
                    command = f"{prefix}{quote}gh{quote} api scripts/endpoint.sh"
                    with patch.object(
                        syntax.SourceResolver,
                        "script",
                        side_effect=AssertionError,
                    ):
                        self.assertTrue(
                            syntax.command_shape(command, "org/left", {}).startswith(
                                "<unresolved-gh-api:"
                            )
                        )

    @staticmethod
    def command_pairs() -> tuple[tuple[str, str], ...]:
        """Return inert endpoints, options and payloads with distinct behavior."""
        endpoints = (
            ("/user/issues", "/user/repos"),
            ("user/issues", "user/repos"),
            ("repos/org/name/issues", "repos/org/name/actions/runs"),
            ("./repos/org/name/issues", "./repos/org/name/actions/runs"),
        )
        return (
            *(
                (f"gh api {quote}{left}{quote}", f"gh api {quote}{right}{quote}")
                for left, right in endpoints
                for quote in ("", "'", '"')
            ),
            ("gh api -X GET /user/issues", "gh api -X POST /user/issues"),
            ("gh api --method GET /user/issues", "gh api --method POST /user/issues"),
            ("gh api /user/issues", "gh api /user/issues --paginate"),
            ("gh api '/user/issues?state=open'", "gh api '/user/issues?state=closed'"),
            (
                "gh api graphql -f 'query={ viewer { issues { totalCount } } }'",
                "gh api graphql -f 'query={ viewer { repositories { totalCount } } }'",
            ),
            (
                "gh api graphql --input ./requests/issues.json",
                "gh api graphql --input ./requests/repos.json",
            ),
            (
                'gh api /user/issues -f \'body={"target":"release/prod"}\'',
                'gh api /user/issues -f \'body={"target":"release/test"}\'',
            ),
        )

    @staticmethod
    def inventory(
        repository: str,
        source: str,
        reference: str = "",
        *,
        files: dict[str, str] | None = None,
    ) -> list[model.Unit]:
        """Use the real inventory path, including a recursively expanded action."""
        step = {"run": source, "shell": "bash"}
        runs = {"using": "composite", "steps": [step]}
        action = ".github/actions/check/action.yml"
        workflow = yaml.safe_dump(
            {
                "jobs": {
                    name: {"runs-on": "ubuntu-26.04", "steps": [operation]}
                    for name, operation in (
                        ("inline", step),
                        ("called", {"run": "bash scripts/check.sh", "shell": "bash"}),
                        ("local-action", {"uses": "./.github/actions/check"}),
                    )
                }
            }
        )
        units: list[model.Unit] = model.units(
            repository,
            False,
            {
                WORKFLOW: workflow,
                action: yaml.safe_dump({"runs": runs}),
                "scripts/check.sh": "#!/bin/bash\n" + source,
                **(files or {}),
            },
            reference,
        )
        return units

    def test_gh_api_command_shapes(self) -> None:
        """Endpoint operations, methods, options, queries and JSON remain opaque."""
        for source, changed in self.command_pairs():
            with self.subTest(source=source, changed=changed):
                left = syntax.command_shape(source, "org/example", {})
                right = syntax.command_shape(changed, "org/example", {})
                self.assertNotEqual(left, right)
                for command, shape in ((source, left), (changed, right)):
                    self.assertEqual(syntax.shell_opacity(command), "gh-api")
                    self.assertTrue(shape.startswith("<unresolved-gh-api:"))

    def test_gh_api_inventory(self) -> None:
        """Different and identical API commands cannot cluster or match a catalog."""
        for source, changed in self.command_pairs():
            with self.subTest(source=source, changed=changed):
                left = self.inventory("org/left", source)
                fingerprints = {u.fingerprint for u in left}
                reference = self.inventory("lgtm-hq/lgtm-ci", source, "check")
                self.assertEqual(len(left), 5)
                self.assertEqual(len(reference), 5)
                for command in (changed, source):
                    right = self.inventory("org/right", command)
                    self.assertEqual(len(right), 5)
                    self.assertFalse(fingerprints & {u.fingerprint for u in right})
                    self.assertEqual(model.clusters([*left, *right], [], 0.8), [])
                    for consumers in (left, right):
                        self.assertEqual(model.clusters(consumers, reference, 0.8), [])

    def test_gh_api_command_boundaries(self) -> None:
        """Wrappers, groups and adjacent commands cannot expose masked endpoints."""
        for prefix, suffix in (
            ("env MODE=scan ", ""),
            ("MODE=scan ", ""),
            ("command ", ""),
            ("if ", "; then echo done; fi"),
            ("! ", ""),
            ("echo ready; ", ""),
            ("echo ready && ", " | cat"),
            ("echo ready\n", "\necho done"),
            ("(", ")"),
            ("{ ", "; }"),
            ("", ";echo done"),
            ("", ">result.json"),
        ):
            source = prefix + "gh api /user/issues" + suffix
            changed = prefix + "gh api /user/repos" + suffix
            with self.subTest(source=source):
                self.assertNotEqual(
                    syntax.command_shape(source, "org/example", {}),
                    syntax.command_shape(changed, "org/example", {}),
                )
                self.assertEqual(syntax.shell_opacity(source), "gh-api")
                units = self.inventory("org/left", source)
                units += self.inventory("org/right", changed)
                self.assertEqual(
                    model.clusters(
                        units,
                        self.inventory("lgtm-hq/lgtm-ci", source, "check"),
                        0.8,
                    ),
                    [],
                )

    def test_gh_api_opacity_controls(self) -> None:
        """API arguments never resolve as scripts; ordinary data stays comparable."""
        for command in (
            "gh api",
            "gh api;echo done",
            "gh api graphql",
            "gh api scripts/endpoint.sh",
        ):
            with self.subTest(command=command):
                with patch.object(
                    syntax.SourceResolver,
                    "script",
                    side_effect=AssertionError,
                ):
                    shape = syntax.command_shape(
                        command,
                        "org/left",
                        {"scripts/endpoint.sh": "echo PRIVATE_API_CANARY"},
                    )
                self.assertTrue(shape.startswith("<unresolved-gh-api:"))
                self.assertNotIn("PRIVATE_API_CANARY", shape)
                self.assertEqual(shape, syntax.command_shape(command, "org/left", {}))
                other = syntax.command_shape(command, "org/right", {})
                self.assertNotEqual(shape, other)
        for command in (
            "echo gh api /user/issues",
            "printf '%s' 'gh api /user/issues'",
            'echo "gh api /user/issues"',
            "echo ready # gh api /user/issues",
            "cat 'scripts/data.txt'",
            "ls /tmp/output",
            "test -f ./data/input.json",
        ):
            with self.subTest(command=command):
                self.assertIsNone(syntax.shell_opacity(command))
                left = syntax.command_shape(command, "org/left", {})
                self.assertNotIn("<unresolved-", left)
                self.assertEqual(left, syntax.command_shape(command, "org/right", {}))
                self.assertTrue(
                    model.clusters(
                        self.inventory("org/left", command),
                        self.inventory("lgtm-hq/lgtm-ci", command, "check"),
                        0.8,
                    )
                )


if __name__ == "__main__":
    unittest.main()
