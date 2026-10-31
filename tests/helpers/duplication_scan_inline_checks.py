# SPDX-License-Identifier: MIT
"""Effective run-shell regressions driven by the offline scanner BATS suite."""

from __future__ import annotations

import json
import unittest
from typing import Any

import yaml
from duplication_scan_regression_checks import ACTION, job_unit
from duplication_scan_support import FixtureCase, model, syntax


def inline_job(
    repository: str,
    source: str,
    shell: str,
    scope: str,
    files: dict[str, str] | None = None,
) -> model.Unit:
    """Exercise step, job and workflow shell selection through real YAML."""
    step: dict[str, Any] = {"run": source}
    block: dict[str, Any] = {"steps": [step]}
    context = {}
    defaults = {"run": {"shell": shell}}
    if scope == "step":
        step["shell"] = shell
    elif scope == "job":
        block["defaults"] = defaults
    else:
        context["defaults"] = defaults
    return job_unit(repository, block, context=context, files=files)


class Cases(FixtureCase):
    """Only known run languages may establish cross-repository equivalence."""

    def test_inline_python_indentation(self) -> None:
        """Moving a statement into a conditional must change the job identity."""
        original = "if False:\n    print('A')\nprint('B')\n"
        changed = "if False:\n    print('A')\n    print('B')\n"
        for scope in ("step", "job", "workflow"):
            for shell in ("python", "/usr/bin/python3 {0}"):
                with self.subTest(scope=scope, shell=shell):
                    left = inline_job("org/left", original, shell, scope)
                    right = inline_job("org/right", changed, shell, scope)
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_inline_python_equivalence(self) -> None:
        """Comments, indentation width and safe path inputs may differ."""
        original = (
            "from pathlib import Path\nif True:\n"
            "    print(Path('build/output'))\n    print(8 // 2)\n"
        )
        changed = (
            "# comment\nfrom pathlib import Path\n\nif True:  # condition\n"
            "  print( Path('dist/result') )\n  print(8 // 2)\n"
        )
        for scope in ("step", "job", "workflow"):
            for shell in ("python", "python -u {0}", "/usr/bin/python3 {0}"):
                with self.subTest(scope=scope, shell=shell):
                    left = inline_job("org/left", original, shell, scope)
                    right = inline_job("org/right", changed, shell, scope)
                    self.assertNotIn("<unresolved-", " ".join(left.shape))
                    self.assertEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)

    def test_effective_shell_precedence(self) -> None:
        """Step settings override job defaults, which override workflow defaults."""
        source = "if False:\n    print('A')\nprint('B')\n"
        changed = source.replace("\nprint('B')", "\n    print('B')")
        for workflow_shell, job_shell, step_shell in (
            ("python", None, None),
            ("bash", "python", None),
            ("pwsh", "python", None),
            ("python", "bash", "python"),
            ("pwsh", "pwsh", "python"),
        ):
            with self.subTest(shells=(workflow_shell, job_shell, step_shell)):
                units = []
                for repo, text in (("org/left", source), ("org/right", changed)):
                    step = {"run": text}
                    if step_shell:
                        step["shell"] = step_shell
                    block: dict[str, Any] = {"steps": [step]}
                    if job_shell:
                        block["defaults"] = {"run": {"shell": job_shell}}
                    units.append(
                        job_unit(
                            repo,
                            block,
                            context={"defaults": {"run": {"shell": workflow_shell}}},
                        )
                    )
                self.assertEqual(model.clusters(units, [], 0.8), [])
                expected = inline_job("org/left", source, "python", "step")
                self.assertEqual(units[0].shape[1:], expected.shape[1:])
        for step in ({"run": "echo ready", "shell": "bash"}, {"run": "echo ready"}):
            expected = syntax.operation_shape(step, "org/example", {})
            block = {"defaults": {"run": {"shell": "bash"}}, "steps": [step]}
            actual = syntax.operation_shape(
                block,
                "org/example",
                {},
                defaults={"shell": "python"},
            )["steps"][0]
            self.assertEqual(actual["run"], expected["run"])
            self.assertEqual(actual["shell"], "bash")

    def test_unsupported_run_shells(self) -> None:
        """Unsupported languages and dynamic or ambiguous commands stay opaque."""
        for shell in (
            "pwsh",
            "powershell",
            "cmd",
            "node",
            "ruby",
            "${{ matrix.shell }}",
            "${{ inputs.shell }}",
            "bash ${{ inputs.flags }} {0}",
            "bash -c {0}",
            "python -m runner {0}",
            "custom-python {0}",
        ):
            for scope in ("step", "job", "workflow"):
                with self.subTest(shell=shell, scope=scope):
                    units = [
                        inline_job(repo, "echo ready", shell, scope)
                        for repo in ("org/left", "org/right")
                    ]
                    self.assertEqual(model.clusters(units, [], 0.8), [])
                    self.assertIn("<unresolved-", " ".join(units[0].shape))
                    self.assertEqual(json.loads(units[0].shape[1])["shell"], shell)

    def test_inline_python_dependencies(self) -> None:
        """Inline code reuses the existing bounded import and launcher guards."""
        for source, files in (
            ('import os\nos.system("tools/release")\n', {}),
            ('print(eval("8/2"))\n', {}),
            ("from helper import main\nmain()\n", {"scripts/helper.py": "pass\n"}),
            (
                "import pathlib\nprint(pathlib.Path('build/output'))\n",
                {"scripts/pathlib.py": "pass\n"},
            ),
        ):
            with self.subTest(source=source):
                units = [
                    inline_job(repo, source, "python", "step", files)
                    for repo in ("org/left", "org/right")
                ]
                self.assertEqual(model.clusters(units, [], 0.8), [])
                self.assertIn("<unresolved-python-", " ".join(units[0].shape))

    def test_literal_run_shells(self) -> None:
        """Executable paths and argument values are never ordinary parameters."""
        for original, changed in (
            ("/bin/bash -e {0}", "/bin/sh -e {0}"),
            ("/bin/bash -e {0}", "/usr/bin/bash -e {0}"),
            ("/bin/bash -e {0}", "/bin/bash -u {0}"),
            (
                "/bin/bash --rcfile config/left {0}",
                "/bin/bash --rcfile config/right {0}",
            ),
            ("${{ inputs.shell }}", "${{ matrix.shell }}"),
        ):
            for scope in ("step", "job", "workflow"):
                with self.subTest(shells=(original, changed), scope=scope):
                    left = inline_job("org/left", "[[ x == x ]]", original, scope)
                    right = inline_job("org/right", "[[ x == x ]]", changed, scope)
                    self.assertEqual(json.loads(left.shape[1])["shell"], original)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])
                    shaped = syntax.operation_shape(
                        {"steps": [{"run": "echo ready", "shell": original}]},
                        "org/left",
                        {},
                        defaults={"shell": "python"},
                    )
                    self.assertEqual(shaped["steps"][0]["shell"], original)

    def test_recursive_run_shells(self) -> None:
        """Local composite expansion must preserve shell identity and Python flow."""
        for shell, source, changed_shell, changed_source in (
            ("/bin/bash -e {0}", "[[ x == x ]]", "/bin/sh -e {0}", "[[ x == x ]]"),
            (
                "python",
                "if False:\n    print('A')\nprint('B')\n",
                "python",
                "if False:\n    print('A')\n    print('B')\n",
            ),
        ):
            units = []
            for repo, interpreter, program in (
                ("org/left", shell, source),
                ("org/right", changed_shell, changed_source),
            ):
                action = yaml.safe_dump(
                    {
                        "runs": {
                            "using": "composite",
                            "steps": [{"shell": interpreter, "run": program}],
                        }
                    }
                )
                units.append(
                    job_unit(
                        repo,
                        {"steps": [{"uses": "./.github/actions/check"}]},
                        files={ACTION: action},
                    )
                )
            with self.subTest(shell=shell):
                self.assertEqual(model.clusters(units, [], 0.8), [])
                self.assertIn(shell, " ".join(units[0].shape))

    def test_supported_shell_templates(self) -> None:
        """Ordinary shell normalization and safe explicit templates still match."""
        for shell in (
            "bash",
            "sh",
            "bash {0}",
            "/bin/bash -e {0}",
            "/bin/sh -e {0}",
            "/usr/bin/bash --noprofile --norc -e -o pipefail {0}",
        ):
            for scope in ("step", "job", "workflow"):
                with self.subTest(shell=shell, scope=scope):
                    left = inline_job("org/left", "echo build/output\n", shell, scope)
                    right = inline_job(
                        "org/right",
                        "# comment\necho dist/result\n",
                        shell,
                        scope,
                    )
                    self.assertNotIn("<unresolved-", " ".join(left.shape))
                    self.assertEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)


if __name__ == "__main__":
    unittest.main()
