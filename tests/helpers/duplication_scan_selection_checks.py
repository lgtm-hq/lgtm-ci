# SPDX-License-Identifier: MIT
"""Offline executable forwarding and PATH-selection regressions for BATS."""

from __future__ import annotations

import unittest
from unittest.mock import patch

from duplication_scan_regression_checks import job_unit
from duplication_scan_shell_checks import GhApiCases
from duplication_scan_support import FixtureCase, model, syntax


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
    def forwarders() -> tuple[str, ...]:
        """Include positional, named, bare, quoted and braced command expansions."""
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
            "$1",
            '"$1"',
            "$COMMAND",
            '"${COMMAND}"',
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
                    ("wget --method=DELETE ftp://h/a", "wget --method=DELETE ftp://h/b"),
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
            # Unquoted braced arguments already exceed the bounded data grammar.
            if forwarder.startswith("${"):
                continue
            for source in (f"echo {forwarder}", f"printf '%s\\n' {forwarder}"):
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
