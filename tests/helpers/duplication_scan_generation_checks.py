# SPDX-License-Identifier: MIT
"""Offline regressions for executable files overwritten by shell redirections."""

from __future__ import annotations

import unittest

from duplication_scan_regression_checks import ACTION, WORKFLOW
from duplication_scan_selection_checks import SelectionCase
from duplication_scan_support import guarded_command_shape, syntax

TARGET = "scripts/run.sh"
PAYLOAD = "scripts/payload.txt"
CALLERS = {WORKFLOW, ACTION, "scripts/prepare.sh", "scripts/mutate.sh"}


class Cases(SelectionCase):
    """Never infer executed bodies from stale committed executable contents."""

    def generated_files(self, source: str) -> tuple[dict[str, str], dict[str, str]]:
        """Use identical committed executables and different generated programs."""
        files = {
            **self._runner_path_files(source),
            TARGET: "#!/bin/sh\necho committed\n",
            PAYLOAD: "#!/bin/sh\nexit 7\n",
        }
        return files, {**files, PAYLOAD: "#!/bin/sh\necho ok\n"}

    def test_generated_script_inventory(self) -> None:
        """Inline jobs, nested scripts and composites cannot compare stale bodies."""
        files, right = self.generated_files(f"cat {PAYLOAD} > {TARGET}\nbash {TARGET}")
        self.assert_matching_paths(files, right, {TARGET})

    def test_generated_script_cli(self) -> None:
        """The actual offline CLI excludes callers of generated executable files."""
        files, right = self.generated_files(f"cat {PAYLOAD} > {TARGET}\nbash {TARGET}")
        for include_left in (True, False):
            report = self.cli_report(files, right, include_left=include_left)
            report = report.split("## Public near matches", 1)[0]
            for path in CALLERS:
                with self.subTest(path=path, include_left=include_left):
                    self.assertNotIn(f"`{path}`", report)
            self.assertIn(f"`{TARGET}`", report)

    def test_generated_script_guards(self) -> None:
        """Truncation, append and clobber writes stop before executable lookup."""
        for operator in (">", ">>", ">|", "1>", "2>", "<>"):
            for template in (
                f"cat {PAYLOAD} {operator} {{target}}\nbash {{target}}",
                f"cat {PAYLOAD} {operator} {{target}}; ./{{target}}",
                f"{operator} {{target}}\nbash {{target}}",
                f"bash {{target}} {operator} {{target}}",
            ):
                source = template.format(target=TARGET)
                files, right = self.generated_files(source)
                with self.subTest(source=source):
                    shape = guarded_command_shape(source, files)
                    self.assertIn("<unresolved-", shape)
                    changed = syntax.command_shape(source, "org/right", right)
                    self.assertNotEqual(shape, changed)
                    self.assert_matching_paths(files, right, {TARGET})

    def test_generated_script_literal_controls(self) -> None:
        """Quoted, commented and escaped redirection text cannot hide real calls."""
        for source in (
            f"echo 'cat {PAYLOAD} > {TARGET}'\nbash {TARGET}",
            f'echo "cat {PAYLOAD} >> {TARGET}"\nbash {TARGET}',
            f"# cat {PAYLOAD} >| {TARGET}\nbash {TARGET}",
            f"cat {PAYLOAD} \\> {TARGET}\nbash {TARGET}",
            f"cat {PAYLOAD} \\\\; echo ready\nbash {TARGET}",
            f"cat {PAYLOAD}\nbash {TARGET}",
        ):
            files, right = self.generated_files(source)
            with self.subTest(source=source):
                self.assert_matching_paths(files, right, {TARGET, *CALLERS})


if __name__ == "__main__":
    unittest.main()
