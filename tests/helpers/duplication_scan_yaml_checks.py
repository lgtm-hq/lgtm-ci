# SPDX-License-Identifier: MIT
"""Offline runtime YAML scope, mapping-key and alias coverage regressions."""

from __future__ import annotations

import unittest
from unittest.mock import patch

import duplication_scan_dependency_checks as dependency
import yaml
from duplication_scan_dependency_checks import ACTION, LARGE, SMALL, WORKFLOW
from duplication_scan_support import syntax


class Cases(unittest.TestCase):
    """Exercise production inventory and CLI using the shared offline transport."""

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
