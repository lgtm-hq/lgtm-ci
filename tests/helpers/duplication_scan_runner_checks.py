# SPDX-License-Identifier: MIT
"""Offline runner-file, pipeline and quoted-executable review regressions."""

from __future__ import annotations

import unittest
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_regression_checks import ACTION, WORKFLOW
from duplication_scan_selection_checks import SelectionCase
from duplication_scan_support import model, syntax


class Cases(SelectionCase):
    """Unknown executable selection must not qualify as parameter-only copies."""

    def assert_runner_opaque(self, source: str) -> None:
        """Check early resolution, two-step inventories, catalog and offline CLI."""
        changed = source.replace("release", "check")
        with patch.object(
            syntax.SourceResolver,
            "script",
            side_effect=AssertionError,
        ):
            shape = syntax.SourceResolver("org/left", {}).command(source)
            self.assertIn("<unresolved-", shape)
        self.assert_selection_opaque(source, changed)
        files = self._runner_path_files(source)
        right = self._runner_path_files(changed)
        self.assert_inventory_opaque(files, right)
        self.assert_cli_opaque(files, right)

    def test_runner_context_expressions(self) -> None:
        """Actions evaluates context expressions before shell quoting or escaping."""
        for context in (
            "github.path",
            "github.env",
            "GitHub.PaTh",
            "GITHUB.ENV",
            "github . path",
            "github['path']",
            "github['ENV']",
        ):
            expression = "${{ " + context + " }}"
            for destination in (expression, f'"{expression}"', f"'{expression}'"):
                source = f'echo "$GITHUB_WORKSPACE/tools/release/bin" >> {destination}'
                with self.subTest(source=source):
                    self.assert_runner_opaque(source)
            # Backslashes and shell comments do not escape Actions expressions.
            for source in (
                f"echo tools/release/bin >> \\{expression}",
                f"echo ready # {expression}",
            ):
                with self.subTest(source=source):
                    self.assert_runner_opaque(source)

    def test_indirect_runner_references(self) -> None:
        """Unmodeled indirect expansions stay opaque even inside data commands."""
        for variable in ("GITHUB_PATH", "GITHUB_ENV"):
            for source in (
                f'n={variable}; echo tools/release/bin >> "${{!n}}"',
                f"n='{variable}'; echo tools/release/bin >> ${{!n}}",
                f'n="{variable}"; echo tools/release/bin >> "${{!n}}"',
                'echo tools/release/bin >> "${!destination}"',
                'printf "%s" "${!prefix@}" tools/release/bin',
                'echo "\\\\${!destination}" tools/release/bin',
            ):
                with self.subTest(source=source):
                    self.assert_runner_opaque(source)

    def test_runner_environment_scopes(self) -> None:
        """Runner filenames carried in execution metadata poison the whole unit."""
        for expression in (
            "${{ github.path }}",
            "${{ GitHub.ENV }}",
            "${{ github['path'] }}",
        ):
            for scope in (
                "workflow",
                "job",
                "step",
                "action-step",
                "action-call",
                "strategy",
                "container",
                "services",
            ):
                steps: list[dict[str, Any]] = [
                    {"run": 'echo "$GITHUB_WORKSPACE/tools/bin" >> "$GP"'},
                    {"run": "helper"},
                ]
                job: dict[str, Any] = {"runs-on": "ubuntu-26.04", "steps": steps}
                workflow: dict[str, Any] = {"jobs": {"check": job}}
                action = {"runs": {"using": "composite", "steps": steps}}
                if scope == "workflow":
                    workflow["env"] = {"GP": expression}
                elif scope == "job":
                    job["env"] = {"GP": expression}
                elif scope == "strategy":
                    job["strategy"] = {"matrix": {"p": [expression]}}
                    job["env"] = {"GP": "${{ matrix.p }}"}
                elif scope in {"container", "services"}:
                    config = {"image": "ubuntu:26.04", "env": {"GP": expression}}
                    job[scope] = config if scope == "container" else {"db": config}
                else:
                    steps[0]["env"] = {"GP": expression}
                files = {
                    "tools/bin/helper": "#!/bin/sh\necho ready\n",
                    (ACTION if scope == "action-step" else WORKFLOW): yaml.safe_dump(
                        action if scope == "action-step" else workflow
                    ),
                }
                if scope == "action-call":
                    files[ACTION] = yaml.safe_dump(action)
                    files[WORKFLOW] = yaml.safe_dump(
                        {
                            "jobs": {
                                "check": {
                                    "steps": [{"uses": "./.github/actions/check"}],
                                },
                            },
                        },
                    )
                right = {**files, "tools/bin/helper": "#!/bin/sh\nexit 7\n"}
                with self.subTest(expression=expression, scope=scope):
                    self.assert_inventory_opaque(files, right)
                    self.assert_cli_opaque(files, right)

    def test_runner_context_data_controls(self) -> None:
        """Inert env strings and arbitrary output keys remain ordinary data."""
        for parameter in (
            "github.path",
            "GITHUB_ENV",
            "${{ 'github.path' }}",
            "${{ github.path_backup }}",
            "${{ github.workspace }}",
        ):
            source = yaml.safe_dump(
                {
                    "env": {"GP": parameter},
                    "jobs": {
                        "check": {
                            "outputs": {"env": "${{ github.path }}"},
                            "steps": [{"run": "echo ready"}],
                        }
                    },
                }
            )
            with self.subTest(parameter=parameter):
                self.assert_units_equivalent(
                    model.units("org/left", False, {WORKFLOW: source})[0],
                    model.units("org/right", False, {WORKFLOW: source})[0],
                )

    def test_process_substitution(self) -> None:
        """Process substitutions can execute data even behind tee or redirects."""
        for source in (
            "printf '%s\\n' tools/release | tee >(sh)",
            "echo tools/release | tee >(bash)",
            "echo tools/release > >(sh)",
            "cat <(sh tools/release)",
            "diff <(cat tools/release) <(cat tools/check)",
            "echo ${x:-<(sh tools/release)}",
            "echo ${x:- >(sh tools/release)}",
            'printf "%s" "${x:-<(sh tools/release)}"',
        ):
            with self.subTest(source=source):
                self.assert_runner_opaque(source)

    def test_parameter_adjacency_inventory(self) -> None:
        """The fresh bot reproducer remains distinct through inventory and CLI."""
        source, changed = "echo foo${suffix}", "echo foo ${suffix}"
        self.assertIsNone(syntax.shell_opacity(source))
        self.assertIsNone(syntax.shell_opacity(changed))
        self.assertNotEqual(
            syntax.normalize(source, "org/left", shell_source=True),
            syntax.normalize(changed, "org/left", shell_source=True),
        )
        files, right = (self._runner_path_files(text) for text in (source, changed))
        self.assert_inventory_opaque(files, right)
        # The left source correctly matches its own catalog entry. Only the
        # whitespace-different consumer must be excluded from that catalog.
        self.assert_cli_opaque(files, right, include_left=False)

    def test_python_runner_files(self) -> None:
        """Python runner-file references block called, standalone and inline code."""
        for variable in ("GITHUB_PATH", "GITHUB_ENV"):
            for access in (
                f'os.environ["{variable}"]',
                f'os.getenv("{variable}")',
                f'env.get("{variable}")',
                f'os.environb[b"{variable}"]',
                'os.environ["GITHUB_\\x50ATH"]',
                'os.environ["GITHUB_" "PATH"]',
                'os.getenv("GITHUB_" + "ENV")',
                'os.environb[b"GITHUB_" b"PATH"]',
                'env.get(("GITHUB_"\n "ENV"))',
            ):
                source = (
                    "import os, sys\nfrom os import environ as env\n"
                    f'open({access}, "a").write(sys.argv[1])\n'
                )
                command = "python3 scripts/addpath.py tools/release/bin"
                files = {
                    **self._runner_path_files(command),
                    "scripts/addpath.py": source,
                }
                workflow = yaml.safe_load(files[WORKFLOW])
                workflow["jobs"]["inline-python"] = {
                    "runs-on": "ubuntu-26.04",
                    "steps": [{"run": source, "shell": "python"}, {"run": "helper"}],
                }
                files[WORKFLOW] = yaml.safe_dump(workflow)
                right = {
                    path: text.replace("tools/release", "tools/check")
                    for path, text in files.items()
                }
                with self.subTest(access=access):
                    self.assertIn(
                        "<unresolved-",
                        " ".join(syntax.SourceResolver("org/left", {}).python(source)),
                    )
                    self.assertNotEqual(
                        syntax.SourceResolver("org/left", files).command(command),
                        syntax.SourceResolver("org/right", right).command(command),
                    )
                    self.assert_inventory_opaque(files, right)
                    self.assert_cli_opaque(files, right)

    @staticmethod
    def pipeline_sources() -> tuple[str, ...]:
        """Consumers can execute their input without a recognizable interpreter."""
        return (
            "echo ./tools/release | dash",
            "echo ./tools/release | awk '{system($0)}'",
            "printf '%s\\n' ./tools/release | unknown-consumer",
            "cat ./tools/release | cat | arbitrary-command --run-input",
            'echo ./tools/release | "dash"',
            "echo ./tools/release | 'awk' '{system($0)}'",
            "(echo ./tools/release | dash)",
            "echo ./tools/release | (cat; dash)",
            "echo ./tools/release | { cat; dash; }",
            "echo ./tools/release |& arbitrary-command",
            "if true; then echo ./tools/release | dash; fi",
            'echo "./tools/release | quoted data" | unknown-consumer',
            r"echo ./tools/release \|| dash",
        )

    def test_unknown_pipeline_consumers(self) -> None:
        """A data producer cannot hide an unproven downstream executable."""
        for source in self.pipeline_sources():
            with self.subTest(source=source):
                self.assert_runner_opaque(source)

    def test_called_pipeline_consumers(self) -> None:
        """Resolving a shell script cannot erase its executable stdin arguments."""
        for consumer in ("dash", "awk '{system($0)}'", "custom-executor"):
            source = f'echo "$1" | {consumer}'
            command = "bash scripts/pipe.sh tools/release/bin"
            files = {
                **self._runner_path_files(command),
                "scripts/pipe.sh": "#!/bin/sh\n" + source,
            }
            right = {
                path: text.replace(
                    "release",
                    "check",
                )
                for path, text in files.items()
            }
            with self.subTest(consumer=consumer):
                changed = command.replace("release", "check")
                self.assert_selection_opaque(command, changed, files=files)
                self.assert_inventory_opaque(files, right)
                self.assert_cli_opaque(files, right)

    def test_quoted_executable_names(self) -> None:
        """Quoted interpreters/wrappers cannot bypass local dependency guards."""
        for quote in ("'", '"'):
            for command in (
                f"{quote}python{quote} -m check",
                f"{quote}python3{quote} -m check",
                f"{quote}sh{quote} tools/dependency.sh",
                f"{quote}bash{quote} -c 'python -m check'",
                f"{quote}command{quote} python -m check",
                f"env {quote}python{quote} -m check",
                f"uv run {quote}python{quote} -m check",
                f"if true; then {quote}python{quote} -m check; fi",
                f"( {quote}python{quote} -m check )",
            ):
                files = {
                    **self._runner_path_files(command),
                    "check.py": "print('check')\n",
                    "tools/dependency.sh": "echo check\n",
                }
                right = {
                    **files,
                    "check.py": "raise SystemExit(7)\n",
                    "tools/dependency.sh": "exit 7\n",
                }
                with self.subTest(command=command):
                    self.assertNotEqual(
                        syntax.SourceResolver("org/left", files).command(command),
                        syntax.SourceResolver("org/right", right).command(command),
                    )
                    self.assert_inventory_opaque(files, right)
                    self.assert_cli_opaque(files, right)
        for command in ('py"thon" -m check', "'python'\"\" -m check", 'bash"" x'):
            with self.subTest(command=command):
                self.assert_selection_opaque(command, command)

    def test_runner_and_pipeline_data_controls(self) -> None:
        """Literal references and proven data pipelines must remain comparable."""
        for source in (
            "# ${!destination}\necho ready",
            "echo '${!destination}' tools/release/bin",
            r'echo "\${!destination}" tools/release/bin',
            r"echo \${!destination} tools/release/bin",
            "echo '${{ github.workspace }}' tools/release/bin",
            "echo \"${{ 'github.path' }}\" tools/release/bin",
            'echo "${{ github.path_backup }}" tools/release/bin',
            'echo "$1" | cat',
            'printf "%s\\n" "$1" | cat | cat',
            'cat "$1" | test',
            'echo "$1" | ls',
            'echo "$1" | [ -n ready ]',
            "false | true",
            'echo "$1" | true',
            'echo "$1" | false',
            "echo tools/release/bin || echo ready",
            "echo tools/release/bin # | dash",
            "echo 'tools/release/bin | dash'",
            'echo "tools/release/bin | dash"',
            r"echo ready \| dash",
            "echo tools/release/bin >| output.txt",
            "echo '\"python\" -m check'",
            "echo \"'sh' scripts/dependency.sh\"",
            "echo 'tools/release >(sh)'",
            'echo "tools/release <(sh)"',
            r"echo tools/release \>\(sh\)",
            r"echo tools/release \<\(sh\)",
            "echo tools/release # >(sh)",
            "echo tools/release # <(sh)",
        ):
            with self.subTest(source=source):
                self.assert_data_equivalent(source, source.replace("release", "check"))
        for source in (
            "echo '${x:-<(sh tools/release)}'",
            r'echo "\${x:-<(sh tools/release)}"',
        ):
            with self.subTest(source=source):
                self.assertIsNone(syntax.shell_opacity(source))
                shape = syntax.command_shape(source, "org/left", {})
                self.assertNotIn("<unresolved-", shape)
                self.assert_data_equivalent(source, source)
        for source in (
            '# GITHUB_PATH\nprint("ready")\n',
            'print("GITHUB_PATH_BACKUP", "GITHUB_ENV_BACKUP")\n',
            'from pathlib import Path\nprint(Path("tools/release/bin"))\n',
            'print("GITHUB_", "PATH", "ENV")\n',
            'print("GITHUB_" "PATH_BACKUP", "GITHUB_" + "ENV_BACKUP")\n',
        ):
            with self.subTest(python=source):
                self.assertEqual(
                    syntax.SourceResolver("org/left", {}).python(source),
                    syntax.SourceResolver("org/right", {}).python(
                        source.replace("release", "check")
                    ),
                )
                shape = syntax.SourceResolver("org/left", {}).python(source)
                self.assertNotIn("<unresolved-", " ".join(shape))


if __name__ == "__main__":
    unittest.main()
