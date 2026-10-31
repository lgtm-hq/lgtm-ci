# SPDX-License-Identifier: MIT
"""Offline source and issue-lifecycle regressions for PR #1244."""

from __future__ import annotations

import copy
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from dataclasses import replace
from pathlib import Path
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_support import FakeGitHub, FixtureCase, model, scan, syntax

WORKFLOW = ".github/workflows/ci.yml"
ACTION = ".github/actions/check/action.yml"


def job_unit(
    repository: str,
    block: dict[str, Any],
    *,
    context: dict[str, Any] | None = None,
    files: dict[str, str] | None = None,
) -> model.Unit:
    """Build a real workflow job with a literal runner for matching tests."""
    source = yaml.safe_dump(
        {
            **(context or {}),
            "jobs": {"check": {"runs-on": "ubuntu-26.04", **block}},
        }
    )
    return model.file_units(
        repository, False, WORKFLOW, source, {WORKFLOW: source, **(files or {})}, ""
    )[0]


class ShellCases(FixtureCase):
    """Bounded shell recognition must preserve execution and word identities."""

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
                for command in (f"./{path}", f"env MODE=check ./{path}"):
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
                for prefix in ("bash", "bash -u", "sh", "source", "env bash"):
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


class Cases(FixtureCase):
    """One focused BATS case per review finding or related group of nits."""

    def test_implicit_shell(self) -> None:
        """GitHub's implicit shell lacks explicit bash's pipefail invocation."""
        implicit = {"run": "false | true"}
        explicit = {**implicit, "shell": "bash"}
        baseline = syntax.operation_shape(implicit, "org/example", {})
        bash = syntax.operation_shape(explicit, "org/example", {})
        self.assertEqual(baseline["shell"], "<implicit-shell>")
        self.assertEqual(bash["shell"], "bash")
        self.assertNotEqual(baseline, bash)
        inherited_shape = syntax.operation_shape(
            implicit, "org/example", {}, defaults={"shell": "bash"}
        )
        self.assertEqual(inherited_shape, bash)
        overridden_shape = syntax.operation_shape(
            explicit, "org/example", {}, defaults={"shell": "pwsh"}
        )
        self.assertEqual(overridden_shape, bash)
        left = job_unit("org/left", {"steps": [implicit]})
        right = job_unit("org/right", {"steps": [explicit]})
        self.assertEqual(model.clusters([left, right], [], 0.8), [])
        for scope in ("job", "workflow"):
            context = {"defaults": {"run": {"shell": "bash"}}}
            block = {"steps": [implicit]}
            inherited = job_unit(
                "org/example",
                {**block, **context} if scope == "job" else block,
                context=context if scope == "workflow" else {},
            )
            self.assertEqual(inherited.shape[1:], right.shape[1:])

    def test_python_path_parameters(self) -> None:
        """Ordinary Python strings normalize without resolving executables."""
        path = "scripts/check.py"
        source = (
            'from pathlib import Path\noutput = Path("build/output")\n'
            'if output.exists():\n    print("scripts/report.py", "a  b")\n'
        )
        left = model.units("org/left", False, {path: source})[0]
        right = model.units("org/right", False, {path: source})[0]
        self.assertEqual(left.fingerprint, right.fingerprint)
        self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
        parameter = model.units(
            "org/right", False, {path: source.replace("build/output", "dist/result")}
        )[0]
        self.assertEqual(left.fingerprint, parameter.fingerprint)
        unused = model.units(
            "org/right",
            False,
            {path: source, "build/output": "different unused content"},
        )[0]
        self.assertEqual(left.fingerprint, unused.fingerprint)
        for changed in (
            source.replace("    print", "print"),
            source.replace("if output.exists()", "if not output.exists()"),
            source.replace("a  b", "a b"),
        ):
            other = model.units("org/right", False, {path: changed})[0]
            self.assertNotEqual(left.fingerprint, other.fingerprint)

    def test_python_process_commands(self) -> None:
        """Uninspected Python process calls must not qualify as parameter copies."""
        path = "scripts/check.py"
        for source in (
            'import subprocess\nsubprocess.run(["tools/release"])\n',
            'import subprocess as sp\nsp.run(["tools/release"])\n',
            'from subprocess import run as execute\nexecute("scripts/check.sh")\n',
            'import os\nos.system("bash scripts/check.sh")\n',
            'import os as operating_system\noperating_system.system("tools/release")\n',
            'from os import system as execute\nexecute("tools/release")\n',
            'from os import (\n    system as execute,\n)\nexecute("tools/release")\n',
            "import subprocess\nsubprocess.run(command)\n",
            "import asyncio\nasync def main():\n"
            '    await asyncio.create_subprocess_exec("tools/release")\n'
            "asyncio.run(main())\n",
            "import asyncio\nasync def main():\n"
            '    await asyncio.create_subprocess_shell("tools/release")\n'
            "asyncio.run(main())\n",
            "from asyncio import create_subprocess_exec as launch\n"
            'async def main():\n    await launch("tools/release")\n',
            'import os, subprocess as sp\nsp.run(["tools/release"])\n',
            'import json, subprocess\nrun = subprocess.run\nrun(["tools/release"])\n',
            'import os\nos.posix_spawn("tools/release", [], {})\n',
        ):
            with self.subTest(source=source):
                left = model.units("org/left", False, {path: source})[0]
                if "tools/release" in source:
                    changed = source.replace("tools/release", "tools/check")
                    self.assertNotEqual(
                        left.fingerprint,
                        model.units("org/left", False, {path: changed})[0].fingerprint,
                    )
                for other in (source, source.replace("tools/release", "tools/check")):
                    right = model.units("org/right", False, {path: other})[0]
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])
        ordinary = 'from pathlib import Path\noutput = Path("subprocess/run")\n'
        self.assertEqual(
            syntax.script_shape(path, ordinary, "org/left", {}),
            syntax.script_shape(path, ordinary, "org/right", {}),
        )

    def test_script_arguments_are_data(self) -> None:
        """Path arguments never acquire identities from unrelated script bodies."""
        path = "scripts/missing.sh"
        for command in (
            f"echo {path}",
            f"cat {path}",
            f"printf '%s\\n' {path}",
            f'echo "bash {path}"',
            f'echo "ready; bash {path}"',
        ):
            with self.subTest(command=command):
                left = job_unit("org/left", {"steps": [{"run": command}]})
                for files in ({}, {path: "echo unrelated body"}):
                    right = job_unit(
                        "org/right",
                        {"steps": [{"run": command}]},
                        files=files,
                    )
                    self.assertEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
                self.assertEqual(
                    syntax.script_shape("scripts/wrapper.sh", command, "org/left", {}),
                    syntax.script_shape("scripts/wrapper.sh", command, "org/right", {}),
                )
        for command in (
            path,
            "missing.sh",
            f'"{path}"',
            f"bash {path}",
            "bash missing.sh",
            f"source {path}",
            f". {path}",
            f"env MODE=test bash {path}",
            f"echo ready; {path}",
            "bash -c 'bash missing.sh'",
            f'echo "$(bash {path})"',
            "echo `bash missing.sh`",
        ):
            with self.subTest(command=command):
                left = job_unit("org/left", {"steps": [{"run": command}]})
                right = job_unit("org/right", {"steps": [{"run": command}]})
                self.assertNotEqual(left.fingerprint, right.fingerprint)
                self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_shell_directory_changes(self) -> None:
        """An unsupported directory change must never select a matching root copy."""
        for command in (
            "cd app; bash scripts/check.sh",
            "cd app && bash scripts/check.sh",
            "cd app\nbash scripts/check.sh",
            'cd "$APP"; bash scripts/check.sh',
            "builtin cd app; bash scripts/check.sh",
            "pushd app; bash scripts/check.sh; popd",
            "if true; then cd app; fi; bash scripts/check.sh",
            "{ cd app; bash scripts/check.sh; }",
            "{ cd app\nbash scripts/check.sh; }",
            "f() { cd app; }; f; bash scripts/check.sh",
            "! cd app || true; bash scripts/check.sh",
            "time cd app; bash scripts/check.sh",
            "sudo cd app; bash scripts/check.sh",
            "nohup command env cd app; bash scripts/check.sh",
            "if cd app; then bash scripts/check.sh; fi",
            "while false; do cd app; done; bash scripts/check.sh",
            "until cd app; do true; done; bash scripts/check.sh",
            "env --chdir=app bash scripts/check.sh",
            "sudo -u runner cd app; bash scripts/check.sh",
        ):
            with self.subTest(command=command):
                files = {
                    "scripts/check.sh": "echo matching root copy",
                    "app/scripts/check.sh": "echo app check",
                    "scripts/wrapper.sh": command,
                }
                changed = {**files, "app/scripts/check.sh": "echo app release"}
                for run in (command, "bash scripts/wrapper.sh"):
                    left = job_unit(
                        "org/left",
                        {"steps": [{"run": run}]},
                        files=files,
                    )
                    right = job_unit(
                        "org/right",
                        {"steps": [{"run": run}]},
                        files=changed,
                    )
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])
        ordinary = 'echo "cd app; bash scripts/unused.sh"; bash scripts/check.sh'
        files = {"scripts/check.sh": "echo check"}
        self.assertEqual(
            syntax.command_shape(ordinary, "org/left", files),
            syntax.command_shape(ordinary, "org/right", files),
        )

    def test_wrapped_script_identity(self) -> None:
        """Supported wrappers and shell positions compare actual called bodies."""
        commands = [
            ("uv run {path}", "py"),
            ("uv run python {path}", "py"),
            ("bun run {path}", "ts"),
            ("timeout 60 {path}", "sh"),
            ("exec {path}", "sh"),
            ("time bash {path}", "sh"),
            ("bash -euo pipefail {path}", "sh"),
            ("if {path}; then true; fi", "sh"),
            ("if true; then {path}; fi", "sh"),
            ("if false; then true; else {path}; fi", "sh"),
            ("if false; then true; elif {path}; then true; fi", "sh"),
            ("while false; do {path}; done", "sh"),
            ("while {path}; do true; done", "sh"),
            ("until {path}; do true; done", "sh"),
            ("! {path}", "sh"),
            ("{{ {path}; }}", "sh"),
            ("sudo {path}", "sh"),
            ("nohup {path}", "sh"),
            ("command {path}", "sh"),
            ("env MODE=test {path}", "sh"),
            ("if true; then time env MODE=test bash {path}; fi", "sh"),
            ('command bash "{path}"', "sh"),
        ]
        bodies = {
            "py": ("print('check')", "raise RuntimeError('release')"),
            "ts": ("console.log('check')", "throw Error('release')"),
            "sh": ("echo check", "exit 7"),
        }
        for template, extension in commands:
            path = f"scripts/check.{extension}"
            command = template.format(path=path)
            files = {path: bodies[extension][0], "scripts/wrapper.sh": command}
            for run in (command, "bash scripts/wrapper.sh"):
                with self.subTest(run=run, command=command):
                    block = {"steps": [{"run": run}]}
                    left = job_unit("org/left", block, files=files)
                    same = job_unit("org/right", block, files=files)
                    changed = job_unit(
                        "org/right",
                        block,
                        files={**files, path: bodies[extension][1]},
                    )
                    self.assertEqual(left.fingerprint, same.fingerprint)
                    self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
                    self.assertNotEqual(left.fingerprint, changed.fingerprint)
                    self.assertEqual(model.clusters([left, changed], [], 0.8), [])
                    missing = job_unit(
                        "org/right",
                        block,
                        files={"scripts/wrapper.sh": command},
                    )
                    self.assertEqual(model.clusters([left, missing], [], 0.8), [])

    def test_ambiguous_wrapper_identity(self) -> None:
        """Unmodeled wrapper options and executables cannot mask unknown logic."""
        for template in (
            "xargs -n1 bash {path}",
            "custom-runner {path}",
            'custom-runner "{path}"',
            "sudo -u runner bash {path}",
            "uv run --project app {path}",
            "timeout --signal=TERM 60 {path}",
            "env --chdir=app bash {path}",
            "bash --rcfile config {path}",
        ):
            for path in ("scripts/check.sh", "tools/check"):
                command = template.format(path=path)
                for body in ("echo check", "exit 7"):
                    files = {path: body, "scripts/wrapper.sh": command}
                    for run in (command, "bash scripts/wrapper.sh"):
                        with self.subTest(command=command, body=body, run=run):
                            block = {"steps": [{"run": run}]}
                            left = job_unit("org/left", block, files=files)
                            for other in ("echo check", "exit 7"):
                                right = job_unit(
                                    "org/right",
                                    block,
                                    files={**files, path: other},
                                )
                                self.assertNotEqual(left.fingerprint, right.fingerprint)
                                self.assertEqual(
                                    model.clusters([left, right], [], 0.8),
                                    [],
                                )

    def test_wrapped_script_data(self) -> None:
        """Keywords, groups and wrapper words inside ordinary data stay data."""
        path = "scripts/check.sh"
        for command in (
            f"if true; then echo {path}; fi",
            f"{{ cat {path}; }}",
            f"command printf '%s\\n' {path}",
            f"env MODE=test echo {path}",
            f'echo "{{ cd app; time bash {path}; }}"',
            f"printf '%s' 'if uv run {path}; then xargs bash {path}; fi'",
            f"echo ready # time cd app; bash {path}",
            f"cat '{path}'",
        ):
            with self.subTest(command=command):
                files = {path: "echo check"}
                left = syntax.command_shape(command, "org/left", files)
                right = syntax.command_shape(command, "org/right", {path: "exit 7"})
                self.assertEqual(left, right)

    def test_working_directory_and_defaults(self) -> None:
        """Directory identity and inherited run defaults select the actual script."""
        block: dict[str, Any] = {"steps": [{"run": "bash scripts/check.sh"}]}
        files = {
            "scripts/check.sh": "echo misleading root copy",
            "apps/web/scripts/check.sh": "echo web",
            "apps/api/scripts/check.sh": "echo api",
        }
        for scope in ("step", "job", "workflow"):
            fingerprints = []
            for directory in ("apps/web", "apps/api"):
                changed = copy.deepcopy(block)
                context: dict[str, Any] = {}
                defaults = {"run": {"working-directory": directory}}
                if scope == "step":
                    changed["steps"][0]["working-directory"] = directory
                elif scope == "job":
                    changed["defaults"] = defaults
                else:
                    context["defaults"] = defaults
                original = job_unit(
                    "org/example",
                    changed,
                    context=context,
                    files=files,
                )
                fingerprints.append(original.fingerprint)
                altered = {**files, f"{directory}/scripts/check.sh": "echo different"}
                self.assertNotEqual(
                    original.fingerprint,
                    job_unit(
                        "org/example",
                        changed,
                        context=context,
                        files=altered,
                    ).fingerprint,
                )
                self.assertEqual(
                    original.fingerprint,
                    job_unit(
                        "org/example",
                        changed,
                        context=context,
                        files={**files, "scripts/check.sh": "echo unused root"},
                    ).fingerprint,
                )
            self.assertNotEqual(fingerprints[0], fingerprints[1])
        changed = copy.deepcopy(block)
        changed["defaults"] = {"run": {"working-directory": "apps/web"}}
        changed["steps"][0]["working-directory"] = "apps/api"
        baseline = job_unit("org/example", changed, files=files)
        self.assertNotEqual(
            baseline.fingerprint,
            job_unit(
                "org/example",
                changed,
                files={**files, "apps/api/scripts/check.sh": "echo different"},
            ).fingerprint,
        )

    def test_external_programs(self) -> None:
        """Unknown local programs cannot match across repos or by masked paths."""
        for command in (
            "bash build",
            '"./tools/my release"',
            '"${{ inputs.directory }}/tools/release"',
            "bash ${{ inputs.script }}",
            '"$CUSTOM_DIR/tools/release"',
            "$PROGRAM",
            "./build.sh",
            "./tools/release",
            "tools/release",
            "bash tools/release",
            "echo ready && ./tools/release",
        ):
            block = {"steps": [{"run": command}]}
            with self.subTest(command=command):
                left = job_unit("org/left", block)
                right = job_unit("org/right", block)
                self.assertEqual(model.clusters([left, right], [], 0.8), [])
        self.assertNotEqual(
            syntax.command_shape("./tools/release", "org/example", {}),
            syntax.command_shape("./tools/check", "org/example", {}),
        )
        block = {"steps": [{"run": "./build.sh"}]}
        left = job_unit("org/left", block, files={"build.sh": "terraform apply"})
        right = job_unit("org/right", block, files={"build.sh": "rm -rf /"})
        self.assertNotEqual(left.fingerprint, right.fingerprint)
        same = job_unit("org/right", block, files={"build.sh": "terraform apply"})
        self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)

    def test_fetch_external_dependencies(self) -> None:
        """The immutable blob inventory follows external scripts and nested actions."""
        sources = [
            yaml.safe_dump(
                {
                    "jobs": {
                        "check": {
                            "runs-on": "ubuntu-26.04",
                            "steps": [
                                {
                                    "run": "./tools/release",
                                    "working-directory": "apps/web",
                                },
                                {"uses": "./custom/check"},
                            ],
                        }
                    }
                }
            ),
            "#!/bin/bash\nbash scripts/helper.sh",
            "echo actual helper",
            "\n".join(
                (
                    "runs:",
                    "  using: composite",
                    "  steps:",
                    "    - uses: ./.github/actions/nested/deep",
                    "",
                )
            ),
            "".join(
                (
                    "runs:\n",
                    "  using: composite\n",
                    "  steps:\n",
                    "    - run: echo nested\n",
                    "      shell: bash\n",
                )
            ),
        ]
        paths = [
            WORKFLOW,
            "apps/web/tools/release",
            "apps/web/scripts/helper.sh",
            "custom/check/action.yml",
            ".github/actions/nested/deep/action.yaml",
        ]
        tree = {
            "tree": [
                {"type": "blob", "path": path, "sha": f"{index:040x}"}
                for index, path in enumerate(paths)
            ]
        }
        requests: list[list[str]] = []

        def response(endpoint: str, **kwargs: Any) -> Any:
            if "git/trees" in endpoint:
                return tree
            query = kwargs["payload"]["query"]
            selected = []
            for index in range(len(paths)):
                if f'object(oid: "{index:040x}")' in query:
                    selected.append(index)
            # GraphQL aliases follow the sorted requested paths, not tree order.
            selected.sort(key=lambda index: paths[index])
            requests.append([paths[index] for index in selected])
            return {
                "data": {
                    "repository": {
                        f"f{i}": {"isBinary": False, "text": sources[index]}
                        for i, index in enumerate(selected)
                    }
                }
            }

        with patch.object(scan.GitHub, "api", side_effect=response):
            fetched = scan.GitHub().files(
                {"full_name": "org/example", "default_branch": "main"},
            )
        self.assertEqual(set(fetched), set(paths))
        self.assertEqual(len(requests), 3)
        unit = model.units("org/example", False, fetched)[0]
        altered = {**fetched, "apps/web/scripts/helper.sh": "echo different"}
        self.assertNotEqual(
            unit.fingerprint, model.units("org/example", False, altered)[0].fingerprint
        )

    def test_local_actions(self) -> None:
        """Local actions resolve recursively with missing and cycle guards."""
        block = {"steps": [{"uses": "./.github/actions/check"}]}
        source = "".join(
            (
                "runs:\n",
                "  using: composite\n",
                "  steps:\n",
                "    - run: echo check\n",
                "      shell: bash\n",
            )
        )
        left = job_unit("org/left", block, files={ACTION: source})
        right = job_unit("org/right", block, files={ACTION: source})
        self.assertEqual(left.fingerprint, right.fingerprint)
        altered = source.replace("echo check", "echo unrelated")
        self.assertNotEqual(
            left.fingerprint,
            job_unit("org/right", block, files={ACTION: altered}).fingerprint,
        )
        nested = source.replace(
            "run: echo check\n      shell: bash",
            "uses: ./custom/nested",
        )
        files = {ACTION: nested, "custom/nested/action.yaml": source}
        left = job_unit("org/left", block, files=files)
        self.assertNotEqual(
            left.fingerprint,
            job_unit(
                "org/right",
                block,
                files={**files, "custom/nested/action.yaml": altered},
            ).fingerprint,
        )
        for files in (
            {},
            {ACTION: nested},
            {
                ACTION: source.replace(
                    "run: echo check\n      shell: bash",
                    "uses: ./.github/actions/check",
                )
            },
            {ACTION: "runs:\n  using: node24\n  main: index.js\n"},
        ):
            self.assertNotEqual(
                job_unit("org/left", block, files=files).fingerprint,
                job_unit("org/right", block, files=files).fingerprint,
            )

    def test_catalog_sequence_compatibility(self) -> None:
        """Valid jobs match catalog operations without discarding consumer metadata."""
        steps = [
            {"run": "echo hello", "shell": "bash"},
            {"uses": "actions/github-script@abc", "with": {"script": "check()"}},
        ]
        source = yaml.safe_dump({"runs": {"using": "composite", "steps": steps}})
        reference = model.file_units(
            scan.TARGET,
            False,
            ACTION,
            source,
            {ACTION: source},
            "check",
        )[0]
        block: dict[str, Any] = {
            "steps": steps,
            "needs": "build",
            "permissions": {"contents": "read"},
        }
        job = job_unit("org/example", block)
        self.assertEqual(len(model.clusters([job], [reference], 0.8)), 1)
        title, _ = model.render(([job], [reference], 1.0), 0.8)
        self.assertEqual(title, "refactor(adoption): adopt check from lgtm-ci (1 repo)")
        other = job_unit("org/other", {**block, "runs-on": "windows-2025"})
        self.assertEqual(model.clusters([job, other], [], 0.8), [])
        for key, value in (
            ("env", {"MODE": "publish"}),
            ("defaults", {"run": {"working-directory": "apps/web"}}),
            ("defaults", {"run": {"shell": "pwsh"}}),
        ):
            changed = copy.deepcopy(block)
            # Omit explicit shell to exercise defaults.run.shell inheritance.
            changed["steps"][0].pop("shell")
            changed[key] = value
            self.assertEqual(
                model.clusters([job_unit("org/example", changed)], [reference], 0.8), []
            )
        changed = copy.deepcopy(block)
        changed["steps"].reverse()
        self.assertEqual(
            model.clusters(
                [job_unit("org/example", changed)],
                [reference],
                0.8,
            ),
            [],
        )
        changed = copy.deepcopy(block)
        changed["steps"][1]["with"]["script"] = "publish()"
        self.assertEqual(
            model.clusters(
                [job_unit("org/example", changed)],
                [reference],
                0.8,
            ),
            [],
        )

    def test_quoted_script_whitespace(self) -> None:
        """Standalone script tokens retain significant spaces inside string literals."""
        for suffix in ("sh", "js", "rb"):
            left = model.units(
                "org/left",
                False,
                {
                    f"scripts/check.{suffix}": "printf '%s' 'a b'",
                },
            )[0]
            right = model.units(
                "org/right",
                False,
                {
                    f"scripts/check.{suffix}": "printf '%s' 'a  b'",
                },
            )[0]
            self.assertNotEqual(left.fingerprint, right.fingerprint)
            self.assertEqual(model.clusters([left, right], [], 0.8), [])
        self.assertEqual(
            syntax.script_shape(
                "scripts/a.sh",
                "echo  'a  b' # comment",
                "org/example",
                {},
            ),
            syntax.script_shape("scripts/a.sh", "echo 'a  b'", "org/example", {}),
        )

    def test_public_identifier_marker_injection(self) -> None:
        """Jobs, inputs, paths, reference names and snippets cannot forge identities."""
        fingerprint = "f" * 24
        marker = f"<!-- lgtm-ci:dup-scan:{fingerprint} -->"
        hostile = f"x`\r\n{marker}\n{model.MEMBERS_END}\n```\n"
        baseline = job_unit("org/example", {"steps": [{"run": "echo hello"}]})
        for field in ("job", "path", "repository", "parameters", "source", "reference"):
            value: Any = (hostile,) if field == "parameters" else hostile
            changed = replace(baseline, **{field: value})
            title, body = model.render(([changed], [changed], 1.0), 0.8)
            with self.subTest(field=field):
                self.assertNotIn("\n", title)
                self.assertFalse(scan.has_marker(body, marker))
                self.assertEqual(body.count(model.MEMBERS_END), 1)
                self.assertEqual(len(scan.membership(body)), 1)
                api = FakeGitHub(
                    [
                        {
                            "number": 1,
                            "state": "closed",
                            "state_reason": "not_planned",
                            "body": body,
                        }
                    ]
                )
                counts = scan.reconcile(
                    api, [(fingerprint, "candidate", "body")], dry_run=True, cap=5
                )
                self.assertEqual(counts["created"], 1)
        source = yaml.safe_dump(
            {
                "jobs": {
                    hostile: {
                        "runs-on": "ubuntu-26.04",
                        "steps": [
                            {
                                "uses": "unknown/action@abc",
                                "with": {hostile: "value"},
                            }
                        ],
                    }
                }
            }
        )
        unit = model.file_units("org/public", False, WORKFLOW, source, {}, "")[0]
        _, body = model.render(([unit], [], 1.0), 0.8)
        self.assertFalse(scan.has_marker(body, marker))

    def test_human_titles_and_crlf(self) -> None:
        """Keep web line endings and human titles; refresh generated counts."""
        group = next(group for group in self.groups if group[0][0].kind == "steps")
        title, body = model.render(group, 0.8)
        fingerprint = group[0][0].fingerprint
        existing = body.replace("\n", "\r\n") + "Owner notes\r\n"
        for issue_title in (title, "Owner's adoption plan"):
            api = FakeGitHub(
                [{"number": 1, "state": "open", "title": issue_title, "body": existing}]
            )
            self.assertEqual(
                scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)[
                    "unchanged"
                ],
                1,
            )
            self.assertEqual(api.writes, [])
        stale = title.rsplit("(", 1)[0] + "(99 repos)"
        api = FakeGitHub([{"number": 1, "state": "open", "title": stale, "body": body}])
        self.assertEqual(
            scan.reconcile(
                api,
                [(fingerprint, title, body)],
                dry_run=False,
                cap=5,
            )["updated"],
            1,
        )
        self.assertEqual(api.issues[0]["title"], title)
        api.issues[0].update(
            title="Owner's adoption plan",
            body=body.replace(
                model.MEMBERS_BEGIN,
                model.MEMBERS_BEGIN + "\n- `org/new`: `ci.yml`",
            ),
        )
        scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(api.issues[0]["title"], "Owner's adoption plan")
        self.assertEqual(scan.membership(api.issues[0]["body"]), scan.membership(body))

    def test_dependency_memoization(self) -> None:
        """Diamond script graphs normalize each distinct dependency once."""
        files = {
            "scripts/top.sh": "bash scripts/a.sh\nbash scripts/b.sh",
            "scripts/a.sh": "bash scripts/shared.sh",
            "scripts/b.sh": "bash scripts/shared.sh",
            "scripts/shared.sh": "echo shared",
        }
        resolver = syntax.SourceResolver("org/example", files)
        with patch.object(resolver, "command", wraps=resolver.command) as command:
            resolver.script("scripts/top.sh")
            resolver.script("scripts/top.sh")
        self.assertEqual(command.call_count, len(files))

    def test_local_readiness_without_output(self) -> None:
        """A local readiness check prints the result when GITHUB_OUTPUT is absent."""
        output = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), redirect_stdout(output):
            self.assertEqual(scan.check_readiness(), 0)
        self.assertIn("ready=false", output.getvalue())

    def test_catalog_shape_validation(self) -> None:
        """Malformed catalog roots fail explicitly before indexing entries."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "catalog").mkdir()
            for source in ("", "[]", "entries: null"):
                (root / "catalog/catalog.yml").write_text(source, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "entries list"):
                    scan.references(root)


if __name__ == "__main__":
    unittest.main()
