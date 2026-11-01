# SPDX-License-Identifier: MIT
"""Offline dependency inventory and coverage regressions for issue #1237."""

from __future__ import annotations

import io
import json
import linecache
import os
import unittest
import warnings
from contextlib import redirect_stderr, redirect_stdout
from typing import Any, cast
from unittest.mock import patch

import yaml
from duplication_scan_support import FakeGitHub, model, offline_cli, scan, syntax

SourceGitHub = scan.GitHub
WORKFLOW = ".github/workflows/ci.yml"
ACTION = ".github/actions/check/action.yml"
LARGE = "tests/unit/oversized.py"
SMALL = "tools/outside.sh"


class InventoryGitHub(FakeGitHub):
    """Use real inventory/size handling with an entirely in-memory transport."""

    def __init__(self, files: dict[str, str]) -> None:
        repositories = [
            {
                "full_name": f"org/{name}",
                "private": False,
                "archived": False,
                "default_branch": "main",
            }
            for name in ("left", "right")
        ]
        super().__init__(repositories=repositories)
        self.sources = {**files, "scripts/independent.sh": "echo independent\n"}
        self.blobs: list[dict[str, Any]] = [
            {"type": "blob", "path": path, "sha": f"{index:040x}", "size": size}
            for index, (path, size) in enumerate(
                [(path, len(text.encode())) for path, text in self.sources.items()]
                + [(LARGE, scan.MAX_BLOB + 1)]
            )
        ]
        self.requested: list[str] = []
        self.attempted: list[str] = []

    def files(self, repository: dict[str, Any]) -> dict[str, str]:
        """Follow the production inventory loop, including recursive discovery."""
        return cast(dict[str, str], SourceGitHub.files(self, repository))

    def read_blobs(self, name: str, blobs: list[dict[str, Any]]) -> dict[str, str]:
        """Record even blobs rejected before a remote request by the size limit."""
        self.attempted.extend(blob["path"] for blob in blobs)
        return cast(dict[str, str], super().read_blobs(name, blobs))

    def api(self, endpoint: str, **kwargs: Any) -> Any:
        """Serve immutable tree/blob reads; delegate fake issue reconciliation."""
        if "/git/trees/" in endpoint:
            return {"tree": self.blobs, "truncated": False}
        if endpoint == "graphql" and kwargs.get("source", True):
            query = kwargs["payload"]["query"]
            blobs = sorted(
                (b for b in self.blobs if f'object(oid: "{b["sha"]}")' in query),
                key=lambda blob: blob["path"],
            )
            self.requested.extend(blob["path"] for blob in blobs)
            return {
                "data": {
                    "repository": {
                        f"f{index}": {
                            "isBinary": False,
                            "text": self.sources[blob["path"]],
                        }
                        for index, blob in enumerate(blobs)
                    }
                }
            }
        return super().api(endpoint, **kwargs)


class Cases(unittest.TestCase):
    """Check discovery before reconciliation without executing fixture source."""

    def invoke(self, api: InventoryGitHub, dry_run: bool = True) -> tuple[int, str]:
        """Run the real CLI and fail if any subprocess could execute or connect."""
        output = io.StringIO()
        with (
            offline_cli(dry_run),
            patch.object(scan, "GitHub", return_value=api),
            patch.object(scan.subprocess, "run", side_effect=AssertionError("process")),
            patch.dict(os.environ, {"GH_TOKEN": "fixture", "GITHUB_STEP_SUMMARY": ""}),
            redirect_stdout(output),
        ):
            status = scan.main()
        return status, output.getvalue()

    def _assert_inert(self, files: dict[str, str]) -> None:
        """Documentation cannot request either a small or oversized dependency."""
        api = InventoryGitHub(
            {**files, SMALL: "echo outside\n", "tools/unused/action.yml": "runs: {}\n"}
        )
        status, output = self.invoke(api)
        self.assertEqual(status, 0)
        self.assertNotIn(LARGE, api.attempted)
        self.assertNotIn(SMALL, api.requested)
        self.assertTrue(all(model.selected(path) for path in api.requested))
        self.assertFalse(api.partial)
        self.assertNotIn("Partial scan", output)
        self.assertIn('"created":', output)
        self.assertEqual(api.writes, [])

    def test_comment_dependencies(self) -> None:
        """Shell/Python comments do not expand inventory."""
        references = f"{LARGE} {SMALL}"
        for path, source in (
            ("scripts/task.sh", f"#!/bin/sh\n# regression: {references}\nprintf ok\n"),
            ("scripts/task.sh", f"printf ok # regression: {references}\n"),
            ("scripts/task.py", f"# regression: {references}\nprint('ok')\n"),
        ):
            with self.subTest(path=path, source=source):
                self._assert_inert({path: source})
        for shell, source in (
            ("bash", f"# {references}\nprintf ok\n"),
            ("python3 -u {0}", f'# See {references}.\nprint("ok")\n'),
        ):
            with self.subTest(shell=shell):
                self._assert_inert(
                    {
                        WORKFLOW: yaml.safe_dump(
                            {
                                "defaults": {"run": {"shell": shell}},
                                "jobs": {"check": {"steps": [{"run": source}]}},
                            }
                        )
                    }
                )

    def test_yaml_data_dependencies(self) -> None:
        """Only actual steps/uses count, including reserved-looking data keys."""
        references = f"python {LARGE}; sh {SMALL}"
        data = {"run": references, "uses": "./tools/unused"}
        for path, document in (
            (
                WORKFLOW,
                {
                    "name": references,
                    "on": {"workflow_dispatch": {"inputs": {"run": data}}},
                    "env": {"EXAMPLE": references},
                    "jobs": {
                        "check": {
                            "runs-on": "ubuntu-26.04",
                            "outputs": data,
                            "steps": [{"run": "printf ok", "name": references}],
                        }
                    },
                },
            ),
            (
                ACTION,
                {
                    "description": references,
                    "inputs": {"run": {"description": references, "default": data}},
                    "outputs": {"uses": {"description": references}},
                    "runs": {
                        "using": "composite",
                        "steps": [{"run": "printf ok", "shell": "bash"}],
                    },
                },
            ),
        ):
            source = f"# regression: {references}\n" + yaml.safe_dump(document)
            with self.subTest(path=path):
                self._assert_inert({path: source})

    def test_executable_oversized_dependencies(self) -> None:
        """A real outside-selected omission still blocks matched reconciliation."""
        self.assertFalse(model.selected(LARGE))
        for command in (
            f"python {LARGE}",
            f"sh {SMALL}",
            f"source {SMALL}",
            "source tools/settings.env",
        ):
            files = {"scripts/task.sh": command + "\n", SMALL: f"python {LARGE}\n"}
            files["tools/settings.env"] = f"python {LARGE}\n"
            for dry_run in (True, False):
                with self.subTest(command=command, dry_run=dry_run):
                    api = InventoryGitHub(files)
                    status, output = self.invoke(api, dry_run)
                    self.assertEqual(status, int(not dry_run))
                    self.assertIn(LARGE, api.attempted)
                    self.assertNotIn(LARGE, api.requested)
                    self.assertEqual(api.skipped["oversized source"], 2)
                    self.assertTrue(api.partial)
                    self.assertIn("Partial scan", output)
                    self.assertIn("Issue action: blocked", output)
                    self.assertEqual(api.writes, [])

    def test_yaml_executable_dependencies(self) -> None:
        """Defaults, local actions and opaque languages keep real dependencies."""
        for shell, command in (
            ("bash", f"python {LARGE}"),
            ("python", f'import runpy\nrunpy.run_path("{LARGE}")'),
            ("pwsh", f"python {LARGE}"),
        ):
            files = {
                WORKFLOW: yaml.safe_dump(
                    {
                        "defaults": {"run": {"shell": shell}},
                        "jobs": {
                            "check": {
                                "steps": [
                                    {"run": command},
                                    {"uses": "./custom/check"},
                                ]
                            }
                        },
                    }
                ),
                "custom/check/action.yml": yaml.safe_dump(
                    {
                        "runs": {
                            "using": "composite",
                            "steps": [{"run": f"sh {SMALL}", "shell": "sh"}],
                        }
                    }
                ),
                SMALL: "echo outside\n",
            }
            with self.subTest(shell=shell):
                api = InventoryGitHub(files)
                status, output = self.invoke(api)
                self.assertEqual(status, 0)
                self.assertIn(LARGE, api.attempted)
                self.assertIn(SMALL, api.requested)
                self.assertIn("custom/check/action.yml", api.requested)
                self.assertIn("Partial scan", output)
                self.assertEqual(api.writes, [])
                self.assertIn(
                    LARGE,
                    syntax.dependency_names({WORKFLOW: files[WORKFLOW]}),
                )

    def test_opaque_dependency_controls(self) -> None:
        """Unknown launchers and script languages retain their dependency hints."""
        for suffix in ("js", "mjs", "cjs", "ts", "rb", "pl", "ps1"):
            path = f"tools/outside.{suffix}"
            self.assertIn(path, syntax.dependency_names({"scripts/task.sh": path}))
        for source in (
            f'import subprocess\nsubprocess.run(["python", "{LARGE}"])\n',
            f'import runpy\nrunpy.run_path("{LARGE}")\n',
            f'payload = "# {LARGE}"\nexec(payload)\n',
            f'"""unclosed {LARGE}',
        ):
            with self.subTest(source=source):
                self.assertIn(
                    LARGE,
                    syntax.dependency_names({"scripts/task.py": source}),
                )
        for command in (f'"sh" {SMALL}', f"sh -c 'python {LARGE}'"):
            left = syntax.command_shape(command, "org/a", {})
            right = syntax.command_shape(command, "org/b", {})
            self.assertIn("<unresolved-", left)
            self.assertNotEqual(left, right)
        for key in ("main", "pre", "post"):
            self.assertIn(
                LARGE,
                syntax.dependency_names(
                    {ACTION: yaml.safe_dump({"runs": {"using": "node24", key: LARGE}})}
                ),
            )

    def assert_reachable(self, files: dict[str, str]) -> None:
        """Reachable data must retain hints and block on an oversized dependency."""
        for dry_run in (True, False):
            api = InventoryGitHub(files)
            status, output = self.invoke(api, dry_run)
            self.assertEqual(status, int(not dry_run))
            self.assertIn(LARGE, api.attempted)
            self.assertNotIn(LARGE, api.requested)
            self.assertEqual(api.skipped["oversized source"], 2)
            self.assertTrue(api.partial)
            self.assertIn("Issue action: blocked", output)
            self.assertEqual(api.writes, [])
        self.assertIn(LARGE, syntax.dependency_names(files))
        self.assertNotIn(SMALL, syntax.dependency_names(files))

    def test_python_external_docstrings(self) -> None:
        """Decorators and external consumers need no local reflection names."""
        for source in (
            f'from driver import execute\n@execute\ndef task():\n    """{LARGE}"""\n',
            f'from driver import execute\n@execute\nclass Task:\n    """{LARGE}"""\n',
            f'from driver import run\n@run\nasync def task():\n    """{LARGE}"""\n',
            f'"""{LARGE}"""\nfrom driver import execute\nexecute()\n',
            # Even without imports, another module can import these objects or
            # the module itself and read their documentation as execution data.
            f'"""{LARGE}"""\nprint("ok")\n',
            f'def task():\n    """See café {LARGE}."""\n    return 0\n',
            f'class Task:\n    """See {LARGE}."""\n',
        ):
            with self.subTest(source=source):
                self.assert_reachable({"scripts/task.py": source + f"# {SMALL}\n"})
        # Inline Python also allows functions/classes to escape to consumers;
        # inventory does not attempt to prove their lifetime or data flow.
        self.assert_reachable(
            {
                WORKFLOW: yaml.safe_dump(
                    {
                        "defaults": {"run": {"shell": "python3 -u {0}"}},
                        "jobs": {
                            "check": {"steps": [{"run": f'"""{LARGE}"""\n'}]},
                        },
                        "description": SMALL,
                    }
                ),
            }
        )

    def test_yaml_reachable_matrix(self) -> None:
        """Keep scoped matrix hints without evaluating include/exclude rules."""
        expression = "${{ fromJSON('" + json.dumps({"script": [LARGE]}) + "') }}"
        for matrix in (
            {"script": [LARGE]},
            {"include": [{"script": LARGE}]},
            {"script": ["tools/reader.py"], "exclude": [{"script": LARGE}]},
            expression,
        ):
            for consumer in (
                {"steps": [{"run": "python ${{ matrix.script }}"}]},
                {
                    "env": {"SCRIPT": "${{ matrix.script }}"},
                    "steps": [{"run": 'python "$SCRIPT"'}],
                },
                {
                    "steps": [
                        {
                            "uses": "vendor/action@v1",
                            "with": {"script": "${{ matrix.script }}"},
                        },
                    ],
                },
                {"uses": "vendor/repo/.github/workflows/check.yml@v1"},
            ):
                job = {"strategy": {"matrix": matrix}, **consumer}
                document = {"jobs": {"check": job}, "description": SMALL}
                with self.subTest(matrix=matrix, consumer=consumer):
                    self.assert_reachable({WORKFLOW: yaml.safe_dump(document)})
        # Unused data in another job must not leak into a consuming job.
        self._assert_inert(
            {
                WORKFLOW: yaml.safe_dump(
                    {
                        "jobs": {
                            "inert": {
                                "strategy": {"matrix": {"script": [LARGE, SMALL]}},
                                "steps": [{"run": "printf ok"}],
                            },
                            "active": {"steps": [{"run": "python tools/reader.py"}]},
                        },
                    }
                ),
            }
        )

    def test_docker_execution_dependencies(self) -> None:
        """Docker entrypoints and unresolved arguments retain inventory hints."""
        entrypoints = ("entrypoint", "pre-entrypoint", "post-entrypoint")
        executions: tuple[dict[str, Any], ...] = (
            *({key: LARGE} for key in entrypoints),
            {"args": ["--script", LARGE]},
            {"args": ["--from-env"], "env": {"SCRIPT": LARGE}},
            {"args": ["${{ inputs.script }}"]},
        )
        for execution in executions:
            inputs = (
                {"script": {"default": LARGE, "description": SMALL}}
                if execution.get("args") == ["${{ inputs.script }}"]
                else {}
            )
            files = {
                ACTION: yaml.safe_dump(
                    {
                        "description": SMALL,
                        "inputs": inputs,
                        "runs": {"using": "docker", "image": "Dockerfile", **execution},
                    }
                ),
            }
            with self.subTest(execution=execution):
                self.assert_reachable(files)
                left = syntax.SourceResolver("org/left", files).action(
                    "./.github/actions/check", frozenset()
                )
                right = syntax.SourceResolver("org/right", files).action(
                    "./.github/actions/check", frozenset()
                )
                self.assertNotEqual(left, right)

    def test_yaml_reachable_environment(self) -> None:
        """Workflow/job/step env reaches dynamic commands and unknown consumers."""
        for scope in ("workflow", "job", "step"):
            for command in ('python "$SCRIPT"', "python tools/reader.py"):
                step: dict[str, Any] = {"run": command}
                job: dict[str, Any] = {"steps": [step]}
                document: dict[str, Any] = {"jobs": {"check": job}}
                target = {"workflow": document, "job": job, "step": step}[scope]
                target["env"] = {"SCRIPT": LARGE}
                document["description"] = SMALL
                with self.subTest(scope=scope, command=command):
                    self.assert_reachable({WORKFLOW: yaml.safe_dump(document)})

    def test_runtime_yaml_configuration(self) -> None:
        """Fetched mapping and list configurations both retain runtime scripts."""
        configuration = "scripts/ci/checks.yml"
        for data in ({"checks": [{"script": LARGE}]}, [{"script": LARGE}], LARGE):
            files = {
                "scripts/ci/run.py": (
                    "import subprocess, yaml\n"
                    f"with open('{configuration}') as stream:\n"
                    "    checks = yaml.safe_load(stream)\n"
                    "if isinstance(checks, dict):\n"
                    "    checks = checks['checks']\n"
                    "if isinstance(checks, str):\n"
                    "    checks = [{'script': checks}]\n"
                    "for check in checks:\n"
                    "    subprocess.run(['python', check['script']])\n"
                ),
                configuration: yaml.safe_dump(data),
            }
            with self.subTest(data=data):
                self.assert_reachable(files)

    def test_container_and_shell_dependencies(self) -> None:
        """Container/service data and shell declarations execute before literals."""
        for field in ("container", "services"):
            for configuration in (
                {"image": "fixture", "env": {"SCRIPT": LARGE}},
                {"image": "fixture", "options": f"--entrypoint {LARGE}"},
                {"image": "fixture", "env": {"SCRIPT": "${{ env.SCRIPT }}"}},
            ):
                job: dict[str, Any] = {
                    field: configuration,
                    "steps": [{"run": "printf ok"}],
                }
                if field == "services":
                    job[field] = {"check": configuration}
                document: dict[str, Any] = {
                    "description": SMALL,
                    "env": {"SCRIPT": LARGE},
                    "jobs": {"check": job},
                }
                with self.subTest(field=field, configuration=configuration):
                    self.assert_reachable({WORKFLOW: yaml.safe_dump(document)})
        for shell in (
            f"python {LARGE} {{0}}",
            f"{LARGE} --flag {{0}}",
            "${{ env.SCRIPT }} --flag {0}",
        ):
            for scope in ("workflow", "job", "step"):
                step: dict[str, Any] = {"run": "printf ok"}
                job = {"steps": [step]}
                document = {
                    "description": SMALL,
                    "env": {"SCRIPT": LARGE} if "${{" in shell else {},
                    "jobs": {"check": job},
                }
                target = {"workflow": document, "job": job, "step": step}[scope]
                if scope == "step":
                    target["shell"] = shell
                else:
                    target["defaults"] = {"run": {"shell": shell}}
                with self.subTest(shell=shell, scope=scope):
                    self.assert_reachable({WORKFLOW: yaml.safe_dump(document)})

    def test_bash_startup_dependencies(self) -> None:
        """BASH_ENV is consumed before literal commands, at every env scope."""
        for scope in ("workflow", "job", "step"):
            for shell in (None, "bash", "bash --noprofile --norc -e -o pipefail {0}"):
                for startup in (LARGE, "$SCRIPT", "${{ env.SCRIPT }}"):
                    step: dict[str, Any] = {"run": "printf ok"}
                    if shell is not None:
                        step["shell"] = shell
                    job: dict[str, Any] = {"steps": [step]}
                    document: dict[str, Any] = {
                        "description": SMALL,
                        "env": {"SCRIPT": LARGE},
                        "jobs": {"check": job},
                    }
                    target = {"workflow": document, "job": job, "step": step}[scope]
                    target.setdefault("env", {})["BASH_ENV"] = startup
                    with self.subTest(scope=scope, shell=shell, startup=startup):
                        self.assert_reachable({WORKFLOW: yaml.safe_dump(document)})
        # A step override replaces the inherited startup file; unused env stays inert.
        self._assert_inert(
            {
                WORKFLOW: yaml.safe_dump(
                    {
                        "env": {"BASH_ENV": LARGE},
                        "jobs": {
                            "check": {
                                "steps": [
                                    {"run": "echo ok", "env": {"BASH_ENV": ""}},
                                ],
                            },
                        },
                    },
                ),
            },
        )

    def test_recursive_yaml_aliases(self) -> None:
        """Reject cyclic YAML before every walker and preserve raw inventory hints."""
        for source in (
            f"env: &e {{LOOP: *e, SCRIPT: {LARGE}}}\n"
            "jobs: {check: {steps: [{run: 'python tools/reader.py'}]}}\n",
            f"env: &e [*e, {LARGE}]\n" "jobs: {check: {steps: [{run: 'printf ok'}]}}\n",
            "jobs: {check: &j {steps: [*j], run: 'python " + LARGE + "'}}\n",
            "jobs: {check: {steps: [{run: 'printf ok'}], "
            "outputs: &o {LOOP: *o, SCRIPT: " + LARGE + "}}}\n",
            "jobs: {check: {steps: [{run: 'printf ok'}], outputs: "
            + "[" * 70
            + LARGE
            + "]" * 70
            + "}}\n",
        ):
            with self.subTest(source=source):
                self.assert_reachable({WORKFLOW: source})
                api = InventoryGitHub({WORKFLOW: source})
                self.invoke(api)
                self.assertEqual(api.skipped["invalid source"], 2)
        action_source = (
            f"inputs: &i {{LOOP: *i, SCRIPT: {LARGE}}}\n"
            "runs: {using: composite, steps: [{run: 'printf ok', shell: bash}]}\n"
        )
        self.assert_reachable(
            {
                WORKFLOW: "jobs: {check: {steps: [{uses: './custom/check'}]}}\n",
                "custom/check/action.yml": action_source,
            },
        )
        # A cycle without an oversized hint must still prevent a full-coverage claim.
        workflow_source = "env: &e {LOOP: *e}\n"
        workflow_source += "jobs: {check: {steps: [{run: 'printf ok'}]}}\n"
        for files in (
            {WORKFLOW: workflow_source},
            {
                WORKFLOW: "jobs: {check: {steps: [{uses: './custom/check'}]}}\n",
                "custom/check/action.yml": action_source.replace(LARGE, "fixture"),
            },
        ):
            for dry_run in (True, False):
                api = InventoryGitHub(files)
                status, output = self.invoke(api, dry_run)
                self.assertEqual(status, int(not dry_run))
                self.assertEqual(api.skipped["invalid source"], 2)
                self.assertTrue(api.partial)
                self.assertIn("Issue action: blocked", output)
                self.assertEqual(api.writes, [])
        # Reusing an acyclic alias across jobs preserves each job's inherited env.
        self.assert_reachable(
            {
                WORKFLOW: "jobs:\n  first:\n"
                "    steps: &s [{run: 'python tools/reader.py'}]\n"
                f"  second:\n    env: {{SCRIPT: {LARGE}}}\n    steps: *s\n",
            },
        )

    def test_yaml_reachable_inputs(self) -> None:
        """Action with/default and dispatch/call defaults retain only scoped data."""
        for steps in (
            [{"run": "python '${{ inputs.script }}'", "shell": "bash"}],
            [{"uses": "vendor/unknown@v1"}],
        ):
            document: dict[str, Any] = {
                "inputs": {"script": {"default": LARGE, "description": SMALL}},
                "runs": {"using": "composite", "steps": steps},
            }
            with self.subTest(steps=steps):
                self.assert_reachable({ACTION: yaml.safe_dump(document)})
        for event in ("workflow_dispatch", "workflow_call"):
            document = {
                "on": {
                    event: {
                        "inputs": {"script": {"default": LARGE, "description": SMALL}},
                    },
                },
                "jobs": {
                    "check": {"steps": [{"run": "python '${{ inputs.script }}'"}]},
                },
            }
            source = yaml.safe_dump(document)
            for spelling in (source, source.replace("'on':", "on:")):
                with self.subTest(event=event, spelling=spelling):
                    self.assert_reachable({WORKFLOW: spelling})
        for target in ("vendor/action@v1", "./custom/check"):
            document = {
                "jobs": {
                    "check": {"steps": [{"uses": target, "with": {"script": LARGE}}]},
                },
                "description": SMALL,
            }
            with self.subTest(target=target):
                self.assert_reachable({WORKFLOW: yaml.safe_dump(document)})

    def test_python_runtime_docstrings(self) -> None:
        """Module/function/class documentation can be consumed through reflection."""
        payload = f"import runpy; runpy.run_path('{LARGE}')"
        for source in (
            f'"""{payload}"""\nexec(__doc__)\n',
            f'def task():\n    """{payload}"""\nexec(task.__doc__)\n',
            f'class Task:\n    """{payload}"""\nexec(getattr(Task, "__doc__"))\n',
            f'def task():\n    """{payload}"""\ngetattr(task, field)\n',
            f'class Task:\n    """{payload}"""\nimport inspect as i\ni.getdoc(Task)\n',
            f'"""{payload}"""\nnamespace = globals()\n',
        ):
            with self.subTest(source=source):
                self.assert_reachable({"scripts/task.py": source + f"# {SMALL}\n"})

    def test_python_dependency_coordinates(self) -> None:
        """Only Python newlines count toward AST/tokenizer docstring coordinates."""
        for separator in ("\f", "\v", "\x1c", "\u2028"):
            for newline in ("\n", "\r\n", "\r"):
                source = f'"{separator}"; path = "{LARGE}"{newline}print(path){newline}'
                with self.subTest(separator=repr(separator), newline=repr(newline)):
                    self.assertIn(
                        LARGE,
                        syntax.dependency_names({"scripts/task.py": source}),
                    )

    def test_python_compiler_warning_privacy(self) -> None:
        """Capture real compiler stderr without suppressing unrelated warnings."""
        source = 'import re\nre.compile("\\d+ PRIVATE_PARSE_SENTINEL")\n'
        cached_source = (len(source), None, source.splitlines(True), "<unknown>")
        error = io.StringIO()
        with (
            warnings.catch_warnings(),
            redirect_stderr(error),
            # Real warning formatting may include cached source context. Keep
            # that context synthetic, temporary and out of the captured output.
            patch.dict(linecache.cache, {"<unknown>": cached_source}),
        ):
            warnings.simplefilter("always")
            syntax.dependency_names({"tools/task.py": source})
            model.units("org/private", True, {"scripts/task.py": source})
            warnings.warn("local-warning-control", UserWarning, stacklevel=1)
        captured = error.getvalue()
        self.assertIn("local-warning-control", captured)
        self.assertNotIn("PRIVATE_PARSE_SENTINEL", captured)
        self.assertNotIn("SyntaxWarning", captured)

    def test_invalid_yaml_dependency_fallback(self) -> None:
        """Malformed YAML/defaults retain hints while selected units fail closed."""
        for source in (
            f"jobs: [\n# {LARGE}\n",
            f"defaults: x\njobs:\n  check:\n    steps:\n      - run: python {LARGE}\n",
            "jobs:\n  bad:\n    defaults: 3\n    steps: [{run: 'printf ok'}]\n"
            f"  check:\n    steps:\n      - run: python {LARGE}\n",
        ):
            with self.subTest(source=source):
                self.assert_reachable({WORKFLOW: source})
                api = InventoryGitHub({WORKFLOW: source})
                self.invoke(api)
                self.assertEqual(api.skipped["invalid source"], 2)


if __name__ == "__main__":
    unittest.main()
