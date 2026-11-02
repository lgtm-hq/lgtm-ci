# SPDX-License-Identifier: MIT
"""Offline runtime data, output, YAML scope and alias coverage regressions."""

from __future__ import annotations

import json
import unittest
from typing import Any
from unittest.mock import patch

import duplication_scan_dependency_checks as dependency
import yaml
from duplication_scan_dependency_checks import ACTION, LARGE, SMALL, WORKFLOW
from duplication_scan_support import syntax


class Cases(unittest.TestCase):
    """Exercise production inventory and CLI using the shared offline transport."""

    def test_templated_comment_dependencies(self) -> None:
        """GitHub interpolation can end a comment before the interpreter runs."""
        checks = dependency.Cases()
        for shell, payload in (
            ("bash", f"\n./{LARGE}"),
            ("python", f'\nimport runpy; runpy.run_path("{LARGE}")'),
        ):
            expression = "${{ fromJSON('" + json.dumps(payload) + "') }}"
            for path in (WORKFLOW, ACTION):
                step = {"shell": shell, "run": f"# {expression}\n"}
                document = (
                    {"jobs": {"check": {"steps": [step]}}}
                    if path == WORKFLOW
                    else {"runs": {"using": "composite", "steps": [step]}}
                )
                files = {path: yaml.safe_dump(document)}
                if path == ACTION:
                    files[WORKFLOW] = (
                        "jobs: {check: {steps: [{uses: './.github/actions/check'}]}}\n"
                    )
                with self.subTest(shell=shell, path=path):
                    checks.assert_reachable(files)
                # A literal command following a comment is the matched control.
                step["run"] = "# documentation\n" + payload.lstrip("\n")
                with self.subTest(shell=shell, path=path, literal=True):
                    checks.assert_reachable({**files, path: yaml.safe_dump(document)})

    def test_literal_comment_controls(self) -> None:
        """Ordinary comments and untemplated source keep documentation inert."""
        checks = dependency.Cases()
        references = f"{LARGE} {SMALL}"
        expression = "${{ fromJSON('" + json.dumps(f"\n./{LARGE}") + "') }}"
        for shell, suffix in (("bash", "sh"), ("python", "py")):
            # GitHub does not interpolate expressions in fetched script files.
            for comment in (references, expression):
                with self.subTest(shell=shell, external=True, comment=comment):
                    checks._assert_inert(  # pylint: disable=protected-access
                        {f"scripts/task.{suffix}": f"# {comment}\n"},
                    )
            for path in (WORKFLOW, ACTION):
                step = {"shell": shell, "run": f"# {references}\n"}
                document = (
                    {"jobs": {"check": {"steps": [step]}}}
                    if path == WORKFLOW
                    else {"runs": {"using": "composite", "steps": [step]}}
                )
                files = {path: yaml.safe_dump(document)}
                if path == ACTION:
                    files[WORKFLOW] = (
                        "jobs: {check: {steps: [{uses: './.github/actions/check'}]}}\n"
                    )
                with self.subTest(shell=shell, path=path):
                    checks._assert_inert(files)  # pylint: disable=protected-access

    def test_opaque_runtime_data(self) -> None:
        """Hash-prefixed data can select scripts through an opaque reader."""
        checks = dependency.Cases()
        for path in (
            "scripts/ci/runtime.txt",
            "scripts/ci/README.md",
            "scripts/ci/Dockerfile",
            "scripts/ci/runtime",
            "scripts/ci/settings.env",
            "scripts/ci/task.zsh",
        ):
            files = {
                "scripts/ci/run.py": (
                    "import pathlib, subprocess\n"
                    f"text = pathlib.Path('{path}').read_text().strip()\n"
                    "script = text.removeprefix('# ')\n"
                    "subprocess.run(['python', script])\n"
                ),
                path: f"# {LARGE}\n",
            }
            with self.subTest(path=path):
                checks.assert_reachable(files)
        checks.assert_reachable(
            {"scripts/task.sh": f"#!/usr/bin/env ruby\n# {LARGE}\n"},
        )
        # Only supported shell suffixes/shebangs prove these spans are comments.
        for path, prefix in (
            ("scripts/task.sh", ""),
            ("scripts/task.bash", ""),
            ("scripts/task", "#!/bin/sh\n"),
            ("scripts/task", "#!/usr/bin/env bash\n"),
        ):
            with self.subTest(path=path, prefix=prefix):
                checks._assert_inert(  # pylint: disable=protected-access
                    {path: prefix + f"# {LARGE} {SMALL}\nprintf ok\n"},
                )

    def test_reachable_output_values(self) -> None:
        """Job, step, action and callable-workflow outputs retain runtime values."""
        checks = dependency.Cases()
        for consumer in (
            {"run": "python '${{ needs.prepare.outputs.script }}'"},
            {
                "env": {"SCRIPT": "${{ needs.prepare.outputs.script }}"},
                "run": 'python "$SCRIPT"',
            },
            {
                "uses": "vendor/execute@v1",
                "with": {"script": "${{ needs.prepare.outputs.script }}"},
            },
        ):
            document: dict[str, Any] = {
                "description": SMALL,
                "jobs": {
                    "prepare": {
                        "outputs": {"script": LARGE},
                        "steps": [{"run": "printf ok"}],
                    },
                    "check": {"needs": "prepare", "steps": [consumer]},
                },
            }
            with self.subTest(consumer=consumer):
                checks.assert_reachable({WORKFLOW: yaml.safe_dump(document)})
        steps = [
            {"id": "prepare", "run": f'echo "script={LARGE}" >> "$GITHUB_OUTPUT"'},
            {"run": "python '${{ steps.prepare.outputs.script }}'"},
        ]
        checks.assert_reachable(
            {WORKFLOW: yaml.safe_dump({"jobs": {"check": {"steps": steps}}})},
        )
        # Output consumers can live outside the fetched action/callable workflow.
        documents: tuple[tuple[str, dict[str, Any]], ...] = (
            (
                "custom/check/action.yml",
                {"runs": {"using": "composite", "steps": [{"run": "printf ok"}]}},
            ),
            (
                WORKFLOW,
                {"jobs": {"check": {"steps": [{"run": "printf ok"}]}}},
            ),
        )
        for path, document in documents:
            declaration = {
                "script": {"value": LARGE, "description": SMALL, "name": SMALL},
                "unused": {"description": SMALL, "name": SMALL},
            }
            if path == WORKFLOW:
                declaration["script"]["value"] = "${{ jobs.check.outputs.script }}"
                document["jobs"]["check"]["outputs"] = {"script": LARGE}
                document["on"] = {"workflow_call": {"outputs": declaration}}
            else:
                document["outputs"] = declaration
            files = {path: yaml.safe_dump(document)}
            if path != WORKFLOW:
                files[WORKFLOW] = (
                    "jobs: {check: {steps: [{id: prepare, uses: './custom/check'}, "
                    "{run: \"python '${{ steps.prepare.outputs.script }}'\"}]}}\n"
                )
            with self.subTest(path=path):
                checks.assert_reachable(files)
        # Descriptive output fields stay inert even beside an opaque consumer.
        documents = (
            (ACTION, {"runs": {"using": "node24", "main": "tools/reader.js"}}),
            (
                WORKFLOW,
                {"jobs": {"check": {"steps": [{"run": "python tools/read.py"}]}}},
            ),
        )
        for path, document in documents:
            metadata: dict[str, Any] = {
                LARGE: {"description": LARGE, "name": SMALL},
            }
            if path == WORKFLOW:
                document["on"] = {"workflow_call": {"outputs": metadata}}
            else:
                document["outputs"] = metadata
            with self.subTest(path=path):
                checks._assert_inert(  # pylint: disable=protected-access
                    {path: yaml.safe_dump(document)},
                )
        checks.test_yaml_data_dependencies()

    def test_runtime_yaml_schema_paths(self) -> None:
        """Schema-like keys in fetched data do not imply workflow/action metadata."""
        checks = dependency.Cases()
        for path in (
            "scripts/ci/checks.yml",
            "scripts/ci/tasks.yaml",
            ".github/workflows/nested/config.yml",
        ):
            for configuration in (
                {"jobs": {"lint": {"script": LARGE}}},
                {"runs": {"nightly": {"script": LARGE}}},
                {"jobs": {}, "startup": LARGE},
                {"checks": {"lint": {"script": LARGE}}},
            ):
                files = {
                    "scripts/ci/run.py": (
                        "import subprocess, yaml\n"
                        f"with open('{path}') as stream:\n"
                        "    config = yaml.safe_load(stream)\n"
                        "if 'startup' in config:\n"
                        "    subprocess.run(['python', config['startup']])\n"
                        "else:\n"
                        "    for job in next(iter(config.values())).values():\n"
                        "        subprocess.run(['python', job['script']])\n"
                    ),
                    path: yaml.safe_dump(configuration),
                }
                with self.subTest(path=path, configuration=configuration):
                    checks.assert_reachable(files)
        # The same descriptive fields stay inert at real metadata paths,
        # including local actions outside .github/actions and both suffixes.
        for path, schema in (
            (WORKFLOW, "jobs"),
            (WORKFLOW.replace(".yml", ".yaml"), "jobs"),
            (ACTION, "runs"),
            ("custom/check/action.yaml", "runs"),
        ):
            files = {path: f"# {LARGE}\ndescription: {LARGE}\n{schema}: {{}}\n"}
            if schema == "runs":
                target = path.rsplit("/", 1)[0]
                files[WORKFLOW] = yaml.safe_dump(
                    {"jobs": {"check": {"steps": [{"uses": f"./{target}"}]}}},
                )
            api = dependency.InventoryGitHub(files)
            status, _ = checks.invoke(api)
            self.assertEqual(status, 0)
            self.assertNotIn(LARGE, api.attempted)
            self.assertFalse(api.partial)
            self.assertEqual(api.writes, [])

    def test_scoped_yaml_mapping_keys(self) -> None:
        """An opaque JSON consumer can execute matrix keys as well as values."""
        checks = dependency.Cases()
        reader = "tools/read_matrix.py"
        job = {
            "strategy": {"matrix": {LARGE: [True]}},
            "steps": [
                {"env": {"DATA": "${{ toJSON(matrix) }}"}, "run": f"python {reader}"},
            ],
        }
        checks.assert_reachable(
            {
                WORKFLOW: yaml.safe_dump(
                    {"description": SMALL, "jobs": {"check": job}},
                ),
                reader: (
                    "import json, os, subprocess\n"
                    "for script in json.loads(os.environ['DATA']):\n"
                    "    subprocess.run(['python', script])\n"
                ),
            },
        )
        # A key in an unused matrix or metadata cannot escape its job scope.
        api = dependency.InventoryGitHub(
            {
                WORKFLOW: yaml.safe_dump(
                    {
                        "description": {LARGE: True},
                        "jobs": {
                            "inert": {
                                "strategy": {"matrix": {LARGE: [True]}},
                                "steps": [{"run": "printf ok"}],
                            },
                            "active": {"steps": [{"run": f"python {reader}"}]},
                        },
                    },
                ),
            },
        )
        status, _ = checks.invoke(api)
        self.assertEqual(status, 0)
        self.assertNotIn(LARGE, api.attempted)
        self.assertFalse(api.partial)
        self.assertEqual(api.writes, [])

    def test_bounded_yaml_alias_hints(self) -> None:
        """A tiny acyclic alias graph keeps bounded output and genuine coverage."""
        checks = dependency.Cases()
        source = f"shared:\n  seed: &a0 [{LARGE}]\n"
        for depth in range(1, 11):
            source += f"  level{depth}: &a{depth} [*a{depth - 1}, *a{depth - 1}]\n"
        source += (
            "jobs:\n  check:\n    strategy: {matrix: {script: *a10}}\n"
            "    steps: [{run: 'python tools/reader.py'}]\n"
        )
        self.assertLess(len(source), 600)
        hints = syntax.dependency_sources({WORKFLOW: source})
        self.assertNotIn((source, "unknown"), hints)
        self.assertLess(len(hints), 100)
        checks.assert_reachable({WORKFLOW: source})
        # Shared execution steps still run in each consuming job's environment.
        checks.assert_reachable(
            {
                WORKFLOW: "jobs:\n  first:\n"
                "    steps: &steps [{run: 'python tools/reader.py'}]\n"
                f"  second:\n    env: {{SCRIPT: {LARGE}}}\n    steps: *steps\n",
            },
        )
        # Work exhaustion must retain raw hints rather than truncate discovery.
        with patch.object(syntax, "MAX_YAML_HINT_WORK", 8):
            self.assertIn(
                (source, "unknown"),
                syntax.dependency_sources({WORKFLOW: source}),
            )
            checks.assert_reachable({WORKFLOW: source})


if __name__ == "__main__":
    unittest.main()
