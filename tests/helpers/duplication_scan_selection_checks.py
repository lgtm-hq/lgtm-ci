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


class ExecutableSelectionCases(FixtureCase):
    """Forwarding and PATH lookup cannot prove executable equivalence."""

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
            "$1",
            '"$1"',
            "$COMMAND",
            '"${COMMAND}"',
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
        for forwarder in self._argument_forwarders():
            for wrapper in self._wrapped_forwarders():
                source = f"for i in 1 2 3; do {wrapper} {forwarder} && exit 0; done"
                with self.subTest(source=source):
                    self.assert_selection_opaque(source, source)

    def test_unknown_wrapper_script_arguments(self) -> None:
        """Retry scripts cannot mask different executable or endpoint arguments."""
        for forwarder in self._argument_forwarders():
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
        for forwarder in self._argument_forwarders():
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

    def test_runner_path_command_shapes(self) -> None:
        """Runner PATH writes fail closed before any called program is inspected."""
        for source in self._runner_path_sources():
            with self.subTest(source=source):
                with patch.object(
                    syntax.SourceResolver,
                    "script",
                    side_effect=AssertionError,
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
        """Commented writes, quoted command text and filename reads remain inert."""
        for source in (
            '# echo tools/release/bin >> "$GITHUB_PATH"\necho ready',
            "echo ready # echo PATH=tools/release/bin >> ${GITHUB_ENV}",
            "printf '%s\\n' 'echo tools/release/bin >> \"$GITHUB_PATH\"'",
            "printf '%s\\n' 'echo PATH=tools/release/bin >> ${GITHUB_ENV}'",
            "echo tools/release/bin >> '$GITHUB_PATH'",
            "echo PATH=tools/release/bin >> '${GITHUB_ENV}'",
            'echo tools/release/bin >> "${GITHUB_PATH_BACKUP}"',
            'echo PATH=tools/release/bin >> "${GITHUB_ENV_BACKUP}"',
            'echo "$GITHUB_PATH"',
            'cat "${GITHUB_ENV}"',
        ):
            with self.subTest(source=source):
                self.assert_units_equivalent(
                    job_unit("org/left", {"steps": [{"run": source}]}),
                    job_unit(
                        "org/right",
                        {"steps": [{"run": source.replace("release", "check")}]},
                    ),
                )

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
        for files, old, new in (
            (forwarding, "./tools/deploy", "./tools/check"),
            (self._runner_path_files(path_write), "release", "check"),
            (
                self._runner_path_files(env_write),
                "release",
                "check",
            ),
        ):
            right = {path: text.replace(old, new) for path, text in files.items()}
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
                ]
            )
            output = io.StringIO()
            with (
                self.subTest(original=old, source=files[WORKFLOW]),
                offline_cli(True),
                patch.object(scan, "references", return_value=catalog),
                patch.object(scan, "GitHub", return_value=api),
                patch.object(scan.subprocess, "run", side_effect=AssertionError),
                redirect_stdout(output),
            ):
                self.assertEqual(scan.main(), 0)
                self.assertIn("0 qualifying clusters.", output.getvalue())
                self.assertEqual(api.writes, [])

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


if __name__ == "__main__":
    unittest.main()
