# SPDX-License-Identifier: MIT
"""Offline executable forwarding and PATH-selection regressions for BATS."""

from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import yaml
from duplication_scan_regression_checks import ACTION, WORKFLOW, job_unit
from duplication_scan_shell_checks import GhApiCases
from duplication_scan_support import (
    FakeGitHub,
    FixtureCase,
    model,
    offline_cli,
    scan,
    syntax,
)


class SelectionCase(FixtureCase):
    """Shared assertions and inventories for executable selection tests."""

    def assert_data_equivalent(self, source: str, changed: str) -> None:
        """Retain inert data controls through the real workflow inventory."""
        self.assert_units_equivalent(
            job_unit("org/left", {"steps": [{"run": source}]}),
            job_unit("org/right", {"steps": [{"run": changed}]}),
        )

    def assert_inventory_opaque(
        self,
        files: dict[str, str],
        right: dict[str, str],
    ) -> None:
        """Exercise jobs, called scripts, actions and catalog implementations."""
        left, other, catalog = self.inventory_triplet(files, right)
        self.assertTrue(left)
        self.assertEqual(len(left), len(other))
        left_ids = {unit.fingerprint for unit in left}
        self.assertFalse(left_ids & {unit.fingerprint for unit in other})
        self.assertEqual(model.clusters([*left, *other], [], 0.8), [])
        self.assertEqual(model.clusters(other, catalog, 0.8), [])

    def assert_cli_opaque(
        self,
        files: dict[str, str],
        right: dict[str, str],
        *,
        include_left: bool = True,
    ) -> None:
        """Run the real dry-run entrypoint without executing scanned source."""
        output = self.cli_report(files, right, include_left=include_left)
        self.assertIn("0 qualifying clusters.", output)

    @staticmethod
    def inventory_triplet(
        files: dict[str, str], right: dict[str, str]
    ) -> tuple[list[model.Unit], list[model.Unit], list[model.Unit]]:
        """Build both consumer inventories and their catalog control together."""
        return (
            model.units("org/left", False, files),
            model.units("org/right", False, right),
            model.units("lgtm-hq/lgtm-ci", False, files, "check"),
        )

    def cli_report(
        self,
        files: dict[str, str],
        right: dict[str, str],
        *,
        include_left: bool = True,
    ) -> str:
        """Capture the actual dry-run report with source execution forbidden."""
        catalog = model.units("lgtm-hq/lgtm-ci", False, files, "check")
        api = FakeGitHub(
            repositories=[
                {
                    "full_name": repo,
                    "private": False,
                    "archived": False,
                    "files": source,
                }
                for repo, source in (("org/left", files), ("org/right", right))
                if include_left or repo == "org/right"
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
            self.assertEqual(api.writes, [])

        return output.getvalue()

    def assert_matching_paths(
        self, files: dict[str, str], right: dict[str, str], expected: set[str]
    ) -> None:
        """Only the known comparable units may qualify, including in CLI output."""
        left, other, catalog = self.inventory_triplet(files, right)
        for caller, groups in (
            ("inventory", model.clusters([*left, *other], [], 0.8)),
            ("catalog", model.clusters(other, catalog, 0.8)),
        ):
            with self.subTest(caller=caller):
                self.assertEqual(
                    {u.path for members, _, _ in groups for u in members},
                    expected,
                )
        output = self.cli_report(files, right)
        report = output.split("## Public near matches", 1)[0]
        for path in {unit.path for unit in left}:
            self.assertEqual(f"`{path}`" in report, path in expected, report)

    def assert_selection_opaque(
        self,
        source: str,
        changed: str,
        *,
        files: dict[str, str] | None = None,
    ) -> None:
        """Check real command resolution, inventory and catalog exclusion offline."""
        left = syntax.SourceResolver("org/left", files or {}).command(source)
        if not files:
            self.assertIn("<unresolved-", left)
        inventory = GhApiCases.inventory("org/left", source, files=files)
        reference = GhApiCases.inventory(
            "lgtm-hq/lgtm-ci",
            source,
            "check",
            files=files,
        )
        fingerprints = {unit.fingerprint for unit in inventory}
        for command in (source, changed):
            self.assertNotEqual(
                left,
                syntax.SourceResolver("org/right", files or {}).command(command),
            )
            right = GhApiCases.inventory("org/right", command, files=files)
            self.assertFalse(fingerprints & {unit.fingerprint for unit in right})
            self.assertEqual(model.clusters([*inventory, *right], [], 0.8), [])
            self.assertEqual(model.clusters(right, reference, 0.8), [])

    @staticmethod
    def _runner_path_files(source: str) -> dict[str, str]:
        """Mutate the runner's next-step environment inline and through scripts."""
        steps = [{"run": source, "shell": "bash"}, {"run": "helper"}]
        return {
            WORKFLOW: yaml.safe_dump(
                {
                    "jobs": {
                        "inline": {"runs-on": "ubuntu-26.04", "steps": steps},
                        "called": {
                            "runs-on": "ubuntu-26.04",
                            "steps": [
                                {"run": "bash scripts/prepare.sh"},
                                {"run": "helper"},
                            ],
                        },
                        "local-action": {
                            "runs-on": "ubuntu-26.04",
                            "steps": [{"uses": "./.github/actions/check"}],
                        },
                    }
                }
            ),
            ACTION: yaml.safe_dump({"runs": {"using": "composite", "steps": steps}}),
            "scripts/prepare.sh": "#!/bin/sh\nbash scripts/mutate.sh\n",
            "scripts/mutate.sh": "#!/bin/sh\n" + source,
            "tools/release/bin/helper": "#!/bin/sh\nrm -rf build\n",
            "tools/check/bin/helper": "#!/bin/sh\necho ok\n",
        }


class ExecutableSelectionCases(SelectionCase):
    """Forwarding and PATH lookup cannot prove executable equivalence."""

    @staticmethod
    def _argument_forwarders() -> tuple[str, ...]:
        """Include bare, quoted, braced and sliced positional-list expansions."""
        return (
            "$@",
            '"$@"',
            "$*",
            '"$*"',
            "${@}",
            '"${@}"',
            "${*}",
            '"${*}"',
            "${@:1}",
            '"${@:1}"',
            "${*:1}",
            '"${*:1}"',
            '"${@: -1}"',
            '"${*: -1}"',
            "${@:-fallback}",
            '"${*:-fallback}"',
            "${@/deploy/check}",
            '"${*/deploy/check}"',
        )

    @classmethod
    def forwarders(cls) -> tuple[str, ...]:
        """Direct command positions also include named and positional scalars."""
        return (
            *cls._argument_forwarders(),
            *cls._scalar_forwarders(),
        )

    @staticmethod
    def _scalar_forwarders() -> tuple[str, ...]:
        """Scalar arguments may select programs, including parameter operators."""
        return (
            "$1",
            '"$1"',
            "${1}",
            '"${1}"',
            "${10}",
            '"$1" "$2"',
            "$TOOL",
            '"$TOOL"',
            "$COMMAND",
            '"${COMMAND}"',
            "${TOOL}",
            '"${TOOL}"',
            "${1:-./tools/deploy}",
            '"${1:-./tools/deploy}"',
            "${TOOL:-./tools/deploy}",
            '"${TOOL:-./tools/deploy}"',
            '"${TOOL#./}"',
            '"${TOOL%/bin}"',
            '"${!TOOL}"',
            '"${TOOL[@]}"',
        )

    @staticmethod
    def _wrapped_forwarders() -> tuple[str, ...]:
        """Forwarding is unsafe independently of the wrapper's name or options."""
        return (
            "nice",
            "setsid",
            "stdbuf -oL",
            "ionice -c3",
            "chronic",
            "doas",
            "nice -n 5",
            "unknown-program --arbitrary-option",
        )

    def test_unknown_wrapper_forwarding(self) -> None:
        """Unproven forwarding anywhere in a command cannot establish adoption."""
        for forwarder in self.forwarders():
            for wrapper in self._wrapped_forwarders():
                source = f"for i in 1 2 3; do {wrapper} {forwarder} && exit 0; done"
                with self.subTest(source=source):
                    self.assert_selection_opaque(source, source)

    def test_unknown_wrapper_script_arguments(self) -> None:
        """Retry scripts cannot mask different executable or endpoint arguments."""
        for forwarder in self.forwarders():
            for wrapper in self._wrapped_forwarders():
                files = {
                    "scripts/retry.sh": "#!/bin/sh\nfor i in 1 2 3; do "
                    f"{wrapper} {forwarder} && exit 0; sleep 5; done\n",
                    "tools/deploy": "#!/bin/sh\nrm -rf build\n",
                    "tools/check": "#!/bin/sh\necho ok\n",
                }
                for original, changed in (
                    ("./tools/deploy", "./tools/check"),
                    (
                        "curl -X DELETE api.example.com/deploy",
                        "curl -X DELETE api.example.com/delete",
                    ),
                ):
                    with self.subTest(
                        forwarder=forwarder,
                        wrapper=wrapper,
                        original=original,
                    ):
                        self.assert_selection_opaque(
                            f"bash scripts/retry.sh {original}",
                            f"bash scripts/retry.sh {changed}",
                            files=files,
                        )

    def test_resolved_command_forwarding(self) -> None:
        """Resolving an inspected command cannot prove its forwarded inputs safe."""
        files = {"scripts/inspect.sh": "#!/bin/sh\necho ready\n"}
        for forwarder in self.forwarders():
            with self.subTest(forwarder=forwarder):
                source = f"bash scripts/inspect.sh {forwarder} ./tools/deploy"
                changed = source.replace("./tools/deploy", "./tools/check")
                self.assertNotEqual(
                    syntax.SourceResolver("org/left", files).command(source),
                    syntax.SourceResolver("org/right", files).command(changed),
                )
                left, right, catalog = (
                    job_unit(repo, {"steps": [{"run": command}]}, files=files)
                    for repo, command in (
                        ("org/left", source),
                        ("org/right", changed),
                        ("lgtm-hq/lgtm-ci", source),
                    )
                )
                self.assertEqual(model.clusters([left, right], [], 0.8), [])
                self.assertEqual(model.clusters([right], [catalog], 0.8), [])

    def test_scalar_command_prefix_forwarding(self) -> None:
        """Command-prefix values and assignments cannot hide executable choice."""
        for forwarder in ("$TOOL", '"$TOOL"', "${TOOL}", '"${TOOL:-fallback}"'):
            files = {"scripts/retry.sh": f"#!/bin/sh\nnice {forwarder}\n"}
            for command in (
                f"TOOL=./tools/deploy nice {forwarder}",
                "TOOL=./tools/deploy bash scripts/retry.sh",
                f"TOOL=./tools/deploy; nice {forwarder}",
            ):
                with self.subTest(command=command):
                    self.assert_selection_opaque(
                        command, command.replace("deploy", "check"), files=files
                    )

    def test_forwarded_command_shapes(self) -> None:
        """Bare forwarding at command positions remains repository-specific."""
        for forwarder in self.forwarders():
            for source in (
                forwarder,
                f"exec {forwarder}",
                f"for i in 1 2 3; do {forwarder} && exit 0; sleep 5; done",
            ):
                with self.subTest(source=source):
                    self.assert_selection_opaque(source, source)
            for original, changed in (
                ("./tools/deploy", "./tools/check"),
                (
                    "curl -X DELETE api.example.com/deploy",
                    "curl -X DELETE api.example.com/delete",
                ),
            ):
                with self.subTest(forwarder=forwarder, original=original):
                    self.assert_selection_opaque(
                        f"{forwarder} {original}", f"{forwarder} {changed}"
                    )

    def test_forwarded_script_inventory(self) -> None:
        """Retry wrappers cannot erase forwarded executable or endpoint identity."""
        for forwarder in self.forwarders():
            retry = f"for i in 1 2 3; do {forwarder} && exit 0; sleep 5; done\n"
            files = {
                "scripts/retry.sh": "#!/bin/sh\n" + retry,
                "tools/deploy": "#!/bin/sh\nrm -rf build\n",
                "tools/check": "#!/bin/sh\necho ok\n",
            }
            for invocation in ("bash scripts/retry.sh", "./scripts/retry.sh"):
                for original, changed in (
                    ("./tools/deploy", "./tools/check"),
                    (
                        "curl -X DELETE api.example.com/deploy",
                        "curl -X DELETE api.example.com/delete",
                    ),
                    (
                        "wget --method=DELETE ftp://h/a",
                        "wget --method=DELETE ftp://h/b",
                    ),
                ):
                    with self.subTest(
                        forwarder=forwarder, invocation=invocation, original=original
                    ):
                        self.assert_selection_opaque(
                            f"{invocation} {original}",
                            f"{invocation} {changed}",
                            files=files,
                        )

    def test_forwarded_data_controls(self) -> None:
        """Argument expansions passed to proven data commands remain parameters."""
        for forwarder in self.forwarders():
            for command in ("echo", "cat", "printf '%s\\n'", "ls", "test", "["):
                source = f"{command} {forwarder}"
                with self.subTest(source=source):
                    if "${!" in forwarder:
                        # Indirection may name a runner file even in data commands.
                        self.assert_selection_opaque(source, source)
                        continue
                    files = {"scripts/retry.sh": "#!/bin/sh\n" + source}
                    for command in (source, "bash scripts/retry.sh"):
                        left = command + " ./data/first.json"
                        right = command + " ./data/second.json"
                        self.assertEqual(
                            syntax.SourceResolver("org/left", files).command(left),
                            syntax.SourceResolver("org/right", files).command(right),
                        )
                        self.assert_units_equivalent(
                            job_unit(
                                "org/left",
                                {"steps": [{"run": left}]},
                                files=files,
                            ),
                            job_unit(
                                "org/right",
                                {"steps": [{"run": right}]},
                                files=files,
                            ),
                        )

    def test_single_positional_data_control(self) -> None:
        """A single forwarded positional passed to echo is still ordinary data."""
        files = {"scripts/show.sh": '#!/bin/sh\necho "$1"\n'}
        for command in ('echo "$1"', "bash scripts/show.sh"):
            with self.subTest(command=command):
                self.assert_units_equivalent(
                    job_unit(
                        "org/left",
                        {"steps": [{"run": command + " ./data/first.json"}]},
                        files=files,
                    ),
                    job_unit(
                        "org/right",
                        {"steps": [{"run": command + " ./data/second.json"}]},
                        files=files,
                    ),
                )

    def test_forwarding_literal_controls(self) -> None:
        """Comments and literal forwarding text are inert, including unknown tools."""
        for source in (
            '# nice "$@"\necho ready',
            "echo ready # nice ${*:1}",
            "unknown-program '$@'",
            "unknown-program '${*:1}'",
            r'unknown-program "\$@"',
            r"unknown-program \$*",
            "printf '%s\\n' 'nice \"$@\"; doas ${@}'",
            '# nice "$1" "$TOOL"\necho ready',
            "echo ready # nice ${1} ${TOOL:-fallback}",
            "unknown-program '$1' '${TOOL:-fallback}'",
            r'unknown-program "\$1" "\${TOOL}"',
            r"unknown-program \$TOOL \${1}",
            r"unknown-program \${@} \${*:1}",
            "printf '%s\\n' 'nice \"$1\"; doas ${TOOL}'",
        ):
            with self.subTest(source=source):
                self.assert_units_equivalent(
                    job_unit("org/left", {"steps": [{"run": source}]}),
                    job_unit("org/right", {"steps": [{"run": source}]}),
                )

    @staticmethod
    def _runner_path_sources() -> tuple[str, ...]:
        """Cover both runner files, quoting, braced names and data-command writes."""
        return tuple(
            f'{command} "{value}" {operator} {destination}'
            for command in ("echo", "printf '%s\\n'")
            for value, variable in (
                ("$GITHUB_WORKSPACE/tools/release/bin", "GITHUB_PATH"),
                ("PATH=$GITHUB_WORKSPACE/tools/release/bin:$PATH", "GITHUB_ENV"),
            )
            for destination in (
                f"${variable}",
                f'"${variable}"',
                "${" + variable + "}",
                '"${' + variable + '}"',
            )
            for operator in (">>", ">", ">|")
        )

    def test_runner_path_command_shapes(self) -> None:
        """Runner PATH writes fail closed before any called program is inspected."""
        for source in self._runner_path_sources():
            with (
                self.subTest(source=source),
                patch.object(
                    syntax.SourceResolver,
                    "script",
                    side_effect=AssertionError,
                ),
            ):
                shape = syntax.SourceResolver("org/left", {}).command(
                    source + "; bash scripts/check.sh"
                )
                self.assertTrue(shape.startswith("<unresolved-path:"), shape)
                self.assertNotEqual(
                    shape,
                    syntax.SourceResolver("org/left", {}).command(
                        source.replace("release", "check") + "; bash scripts/check.sh"
                    ),
                )

    def test_runner_path_cross_step_inventory(self) -> None:
        """Earlier runner-file writes block consumer clusters and catalog matches."""
        for source in self._runner_path_sources():
            inventories = [
                model.units(repo, False, self._runner_path_files(text), reference)
                for repo, text, reference in (
                    ("org/left", source, ""),
                    ("org/right", source.replace("release", "check"), ""),
                    ("lgtm-hq/lgtm-ci", source, "check"),
                )
            ]
            with self.subTest(source=source):
                left, right, catalog = inventories
                fingerprints = {u.fingerprint for u in left}
                self.assertFalse(fingerprints & {u.fingerprint for u in right})
                self.assertEqual(model.clusters([*left, *right], [], 0.8), [])
                self.assertEqual(model.clusters(right, catalog, 0.8), [])

    def test_runner_path_literal_controls(self) -> None:
        """Only comments, single quotes and escaped runner-file text are inert."""
        for source in (
            '# echo tools/release/bin >> "$GITHUB_PATH"\necho ready',
            "echo ready # echo PATH=tools/release/bin >> ${GITHUB_ENV}",
            "printf '%s\\n' 'echo tools/release/bin >> \"$GITHUB_PATH\"'",
            "printf '%s\\n' 'echo PATH=tools/release/bin >> ${GITHUB_ENV}'",
            "echo tools/release/bin >> '$GITHUB_PATH'",
            "echo PATH=tools/release/bin >> '${GITHUB_ENV}'",
            'echo tools/release/bin >> "${GITHUB_PATH_BACKUP}"',
            'echo PATH=tools/release/bin >> "${GITHUB_ENV_BACKUP}"',
            '# tee -a "$GITHUB_PATH"\necho ready',
            "unknown-program '$GITHUB_PATH' '${GITHUB_ENV}'",
            r'unknown-program "\$GITHUB_PATH" "\${GITHUB_ENV}"',
            r"unknown-program \$GITHUB_PATH \${GITHUB_ENV}",
            r'echo x | tee -a "\$GITHUB_PATH"',
            r"GP=\$GITHUB_PATH; echo ready",
            "printf '%s\\n' 'tee -a \"$GITHUB_PATH\"; cp x ${GITHUB_ENV}'",
        ):
            with self.subTest(source=source):
                self.assert_data_equivalent(source, source.replace("release", "check"))

    def test_executable_selection_cli(self) -> None:
        """The actual dry-run CLI reports no adoption for either review reproducer."""
        env_write = 'echo "PATH=tools/release/bin:$PATH" >> "$GITHUB_ENV"'
        path_write = 'echo "$GITHUB_WORKSPACE/tools/release/bin" >> "$GITHUB_PATH"'
        forwarding = {
            WORKFLOW: yaml.safe_dump(
                {
                    "jobs": {
                        "retry": {
                            "runs-on": "ubuntu-26.04",
                            "steps": [{"run": "bash scripts/retry.sh ./tools/deploy"}],
                        }
                    }
                }
            ),
            "scripts/retry.sh": (
                '#!/bin/sh\nfor i in 1 2 3; do nice "$@" && exit 0; ' "sleep 5; done"
            ),
            "tools/deploy": "#!/bin/sh\nrm -rf build\n",
            "tools/check": "#!/bin/sh\necho ok\n",
        }
        scenarios = [
            (forwarding, "./tools/deploy", "./tools/check"),
            (self._runner_path_files(path_write), "release", "check"),
            (
                self._runner_path_files(env_write),
                "release",
                "check",
            ),
        ]
        for forwarder in self._scalar_forwarders():
            scenarios.append(
                (
                    {
                        **forwarding,
                        "scripts/retry.sh": f"#!/bin/sh\nnice {forwarder}\n",
                    },
                    "./tools/deploy",
                    "./tools/check",
                )
            )
        prefix = "TOOL=./tools/deploy bash scripts/retry.sh"
        scenarios.append(
            (
                {
                    **forwarding,
                    WORKFLOW: forwarding[WORKFLOW].replace(
                        "bash scripts/retry.sh ./tools/deploy", prefix
                    ),
                    "scripts/retry.sh": '#!/bin/sh\nnice "${TOOL}"\n',
                },
                "./tools/deploy",
                "./tools/check",
            )
        )
        for source in (
            path_write.replace('>> "$GITHUB_PATH"', '| tee -a "$GITHUB_PATH"'),
            env_write.replace('>> "$GITHUB_ENV"', '| tee -a "$GITHUB_ENV"'),
            'cp tools/release/config "$GITHUB_PATH"',
            'GP=$GITHUB_PATH; echo tools/release/bin >> "$GP"',
        ):
            scenarios.append((self._runner_path_files(source), "release", "check"))
        scenarios.append(
            (
                {
                    **self._runner_path_files('echo "$1" | tee -a "$GITHUB_PATH"'),
                    WORKFLOW: forwarding[WORKFLOW].replace(
                        "bash scripts/retry.sh ./tools/deploy",
                        "bash scripts/mutate.sh ./tools/release/bin",
                    ),
                },
                "release",
                "check",
            )
        )
        for files, old, new in scenarios:
            right = {path: text.replace(old, new) for path, text in files.items()}
            with self.subTest(original=old, source=files[WORKFLOW]):
                self.assert_cli_opaque(files, right)

    def test_protocol_endpoint_shapes(self) -> None:
        """All literal URL schemes guard endpoints, with no requests executed."""
        for scheme in ("ftp", "ws", "wss", "git+ssh", "custom.v1", "FTP"):
            source = f"bash scripts/request.sh {scheme}://api.example.com/deploy"
            changed = source.replace("deploy", "delete")
            with self.subTest(scheme=scheme):
                self.assertEqual(syntax.shell_opacity(source), "http")
                self.assert_selection_opaque(source, changed)
                comment = f"# {source}\necho ready"
                self.assertIsNone(syntax.shell_opacity(comment))
                self.assertEqual(
                    syntax.command_shape(comment, "org/left", {}),
                    syntax.command_shape(comment, "org/right", {}),
                )

    @staticmethod
    def path_commands() -> tuple[str, ...]:
        """Select executables through prefixes, declarations and earlier commands."""
        return (
            "PATH=tools/release/bin helper",
            "MODE=scan PATH=tools/release/bin helper",
            "env PATH=tools/release/bin helper",
            "command env PATH=tools/release/bin helper",
            "sudo PATH=tools/release/bin helper",
            "PATH=tools/release/bin\nhelper",
            "export PATH=tools/release/bin\nhelper",
            "export MODE=scan PATH=tools/release/bin; helper",
            'export "PATH=tools/release/bin"; helper',
            "readonly PATH=tools/release/bin; helper",
            "declare -x PATH=tools/release/bin; helper",
            "PATH+=:tools/release/bin; helper",
            "if true; then PATH=tools/release/bin helper; fi",
            "(PATH=tools/release/bin; helper)",
            "# note (\nPATH=tools/release/bin helper",
            "echo ready # note (\nexport PATH=tools/release/bin; helper",
        )

    def test_path_command_shapes(self) -> None:
        """PATH mutation makes the whole block opaque before dependency resolution."""
        for source in self.path_commands():
            changed = source.replace("release", "check")
            with self.subTest(source=source):
                self.assertEqual(syntax.shell_opacity(source), "path")
                with patch.object(
                    syntax.SourceResolver,
                    "script",
                    side_effect=AssertionError,
                ):
                    left = syntax.SourceResolver("org/left", {}).command(
                        source + "; bash scripts/check.sh"
                    )
                self.assertTrue(left.startswith("<unresolved-path:"), left)
                self.assertNotEqual(
                    syntax.SourceResolver("org/left", {}).command(source),
                    syntax.SourceResolver("org/left", {}).command(changed),
                )

    def test_path_inventory(self) -> None:
        """PATH lookup in inline, called and action code cannot establish adoption."""
        for source in (
            *self.path_commands(),
            "env -i PATH=tools/release/bin helper",
            "unset PATH; helper",
            "env -u PATH helper",
        ):
            with self.subTest(source=source):
                self.assert_selection_opaque(source, source.replace("release", "check"))

    def test_path_data_controls(self) -> None:
        """Quoted PATH text, comments and ordinary input assignments stay comparable."""
        for source in (
            "echo PATH=tools/release/bin",
            "echo 'PATH=tools/release/bin'",
            'echo "PATH=tools/release/bin"',
            "printf '%s\\n' 'export PATH=tools/release/bin; helper'",
            "echo 'note\nPATH=tools/release/bin\nhelper'",
            "# export PATH=tools/release/bin\necho ready",
            "echo ready # PATH=tools/release/bin",
            "OUTPUT=tools/release/bin printf '%s' \"$OUTPUT\"",
            'echo "$PATH"',
            "printf '%s' 'printf -v PATH tools/release/bin'",
            'echo "printf -v PATH tools/release/bin"',
            "echo 'read -r PATH; mapfile PATH; getopts a PATH' tools/release/bin",
            "# printf -v PATH tools/release/bin\necho ready",
            "echo tools/release/bin # read -r PATH",
            r"echo tools/release/bin \; printf -v PATH",
            r"echo tools/release/bin \& read PATH",
            r"echo printf \-v PATH tools/release/bin",
            "printf -- -v PATH tools/release/bin",
            "printf '%s' '-v PATH' tools/release/bin",
        ):
            changed = source.replace("release", "check")
            with self.subTest(source=source):
                self.assertIsNone(syntax.shell_opacity(source))
                self.assertEqual(
                    syntax.SourceResolver("org/left", {}).command(source),
                    syntax.SourceResolver("org/right", {}).command(changed),
                )
                self.assert_units_equivalent(
                    job_unit("org/left", {"steps": [{"run": source}]}),
                    job_unit("org/right", {"steps": [{"run": changed}]}),
                )


class AssignmentBuiltinCases(SelectionCase):
    """Variable-writing builtins cannot establish executable equivalence."""

    @staticmethod
    def assignment_commands() -> tuple[str, ...]:
        """Variable-writing builtins may change exported executable selection."""
        return (
            "printf -v PATH '%s' \"tools/release/bin:$PATH\"",
            "printf -vPATH '%s' \"tools/release/bin:$PATH\"",
            r"printf \-v PATH '%s' tools/release/bin",
            r"printf -\v PATH '%s' tools/release/bin",
            "printf '-v' 'PATH' '%s' tools/release/bin",
            "printf \"-vPATH\" '%s' tools/release/bin",
            "printf -v 'PATH[0]' '%s' tools/release/bin",
            "command printf -v PATH '%s' tools/release/bin",
            "builtin printf -v PATH '%s' tools/release/bin",
            "if true; then printf -v PATH '%s' tools/release/bin; fi",
            "printf -v \"$destination\" '%s' tools/release/bin",
            "printf -v RESULT '%s' tools/release/bin",
            "read -r PATH; helper tools/release/bin",
            "read -a PATH; helper tools/release/bin",
            "mapfile -t PATH; helper tools/release/bin",
            "readarray PATH; helper tools/release/bin",
            "getopts a PATH tools/release/bin",
            "let 'PATH=1'; helper tools/release/bin",
        )

    def test_assignment_builtin_shapes(self) -> None:
        """Variable writes fail closed before data exemptions or script lookup."""
        resolver = syntax.SourceResolver
        for source in self.assignment_commands():
            with self.subTest(source=source):
                self.assertEqual(syntax.shell_opacity(source), "path")
                with patch.object(resolver, "script", side_effect=AssertionError):
                    command = source + "; bash scripts/check.sh"
                    shape = syntax.command_shape(command, "org/left", {})
                self.assertTrue(shape.startswith("<unresolved-path:"), shape)
                self.assert_selection_opaque(source, source.replace("release", "check"))

    def test_assignment_builtin_inventory(self) -> None:
        """Inline, nested and composite writes block next-step catalog matches."""
        for source in self.assignment_commands():
            files = self._runner_path_files(source)
            right = self._runner_path_files(source.replace("release", "check"))
            with self.subTest(source=source):
                self.assert_inventory_opaque(files, right)
                self.assert_cli_opaque(files, right)


class ExpandedReferenceCases(SelectionCase):
    """Expanded references stay opaque unless their data use is proven."""

    @staticmethod
    def _runner_file_references() -> tuple[str, ...]:
        """Runner-file arguments, aliases and quoted expansions are unproven."""
        return tuple(
            command
            for variable, payload in (
                ("GITHUB_PATH", "$GITHUB_WORKSPACE/tools/release/bin"),
                ("GITHUB_ENV", "PATH=$GITHUB_WORKSPACE/tools/release/bin:$PATH"),
            )
            for reference in (
                f"${variable}",
                f'"${variable}"',
                "${" + variable + "}",
                '"${' + variable + ':-fallback}"',
            )
            for command in (
                f'echo "{payload}" | tee -a {reference}',
                f"cp tools/release/config {reference}",
                f"unknown-program tools/release/config {reference}",
                f'GP={reference}; echo "{payload}" >> "$GP"',
                f'GP={reference} bash scripts/writer.sh "{payload}"',
                f'echo "literal-looking command: tee -a ${variable}"',
                f"cat {reference}",
            )
        )

    def test_runner_file_reference_shapes(self) -> None:
        """Any active runner-file reference fails closed before script inspection."""
        for source in self._runner_file_references():
            with (
                self.subTest(source=source),
                patch.object(
                    syntax.SourceResolver,
                    "script",
                    side_effect=AssertionError,
                ),
            ):
                shape = syntax.SourceResolver("org/left", {}).command(
                    source + "; bash scripts/check.sh"
                )
                self.assertTrue(shape.startswith("<unresolved-path:"), shape)
                self.assertNotEqual(
                    shape,
                    syntax.SourceResolver("org/right", {}).command(source),
                )

    def test_runner_file_reference_inventory(self) -> None:
        """Tee, unknown consumers and aliases cannot match jobs or catalog actions."""
        for source in self._runner_file_references():
            with self.subTest(source=source):
                inventories = [
                    model.units(repo, False, self._runner_path_files(text), reference)
                    for repo, text, reference in (
                        ("org/left", source, ""),
                        ("org/right", source.replace("release", "check"), ""),
                        ("lgtm-hq/lgtm-ci", source, "check"),
                    )
                ]
                left, right, catalog = inventories
                fingerprints = {u.fingerprint for u in left}
                self.assertFalse(fingerprints & {u.fingerprint for u in right})
                self.assertEqual(model.clusters([*left, *right], [], 0.8), [])
                self.assertEqual(model.clusters(right, catalog, 0.8), [])

    def test_runner_file_forwarded_paths(self) -> None:
        """Called scripts cannot mask different paths written through runner files."""
        for destination in ('"$GITHUB_PATH"', '"${GITHUB_ENV}"'):
            for source in (
                f'echo "$1" | tee -a {destination}',
                f'GP={destination}; echo "$1" >> "$GP"',
            ):
                with self.subTest(source=source):
                    self.assert_selection_opaque(
                        "bash scripts/prepare.sh ./tools/release/bin",
                        "bash scripts/prepare.sh ./tools/check/bin",
                        files={"scripts/prepare.sh": "#!/bin/sh\n" + source},
                    )

    def test_unproven_scalar_contexts(self) -> None:
        """Unmodeled scalar contexts remain opaque without inferring shell flow."""
        for source in (
            "rm -rf ${dir}/*",
            "key=${line%% #*}; echo ok",
            '[[ "$MODE" == check ]] && echo ready',
            r'unknown-program "\\$TOOL"',
            r"unknown-program \\${TOOL}",
            r'echo "\\$GITHUB_PATH"',
            r"echo \\${GITHUB_ENV}",
        ):
            with self.subTest(source=source):
                self.assert_selection_opaque(source, source)


if __name__ == "__main__":
    unittest.main()
