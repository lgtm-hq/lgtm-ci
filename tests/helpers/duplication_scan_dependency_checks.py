# SPDX-License-Identifier: MIT
"""Offline dependency inventory and coverage regressions for issue #1237."""

from __future__ import annotations

import io
import os
import unittest
from contextlib import redirect_stdout
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

    def assert_inert(self, files: dict[str, str]) -> None:
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
        """Shell/Python comments and Python docstrings do not expand inventory."""
        references = f"{LARGE} {SMALL}"
        for path, source in (
            ("scripts/task.sh", f"#!/bin/sh\n# regression: {references}\nprintf ok\n"),
            ("scripts/task.sh", f"printf ok # regression: {references}\n"),
            ("scripts/task.py", f"# regression: {references}\nprint('ok')\n"),
            ("scripts/task.py", f'"""See {references}."""\nprint("ok")\n'),
            (
                "scripts/task.py",
                f'def task():\n    """See café {references}."""\n    return 0\n',
            ),
        ):
            with self.subTest(path=path, source=source):
                self.assert_inert({path: source})
        for shell, source in (
            ("bash", f"# {references}\nprintf ok\n"),
            ("python3 -u {0}", f'"""See {references}."""\nprint("ok")\n'),
        ):
            with self.subTest(shell=shell):
                self.assert_inert(
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
                self.assert_inert({path: source})

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


if __name__ == "__main__":
    unittest.main()
