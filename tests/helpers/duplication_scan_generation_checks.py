# SPDX-License-Identifier: MIT
"""Offline regressions for executable files overwritten by shell redirections."""

from __future__ import annotations

import unittest
from collections.abc import Callable
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_regression_checks import ACTION, WORKFLOW, job_unit
from duplication_scan_selection_checks import SelectionCase
from duplication_scan_support import guarded_command_shape, model, syntax

TARGET = "scripts/run.sh"
PAYLOAD = "scripts/payload.txt"
CALLERS = {WORKFLOW, ACTION, "scripts/prepare.sh", "scripts/mutate.sh"}
WRITER = "scripts/gen.sh"
CHAIN = "scripts/chain.sh"
WRITER_ACTION = ".github/actions/write/action.yml"


class Cases(SelectionCase):
    """Never infer executed bodies from stale committed executable contents."""

    def setUp(self) -> None:
        """Forbid process execution throughout the inventory and CLI probes."""
        for target in ("subprocess.run", "subprocess.Popen", "os.system"):
            self.enterContext(patch(target, side_effect=AssertionError(target)))
        super().setUp()

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

    def separated_files(self, source: str) -> tuple[dict[str, str], dict[str, str]]:
        """Carry writes through step, script and local composite boundaries."""
        execute = {"run": f"bash {TARGET}"}
        steps = [{"run": source}, execute]
        jobs = {
            "inline": steps,
            "called-block": [{"run": f"bash {WRITER}\nbash {TARGET}"}],
            "called-steps": [{"run": f"bash {WRITER}"}, execute],
            "nested-writer": [{"run": f"bash {CHAIN}"}],
            "composite-steps": [{"uses": "./.github/actions/check"}],
            "composite-writer": [{"uses": "./.github/actions/write"}, execute],
            "composite-after-write": [
                {"run": source},
                {"uses": "./.github/actions/check"},
            ],
            "cached-script": [execute, *steps],
            "cached-action": [
                {"uses": "./.github/actions/write"},
                {"uses": "./.github/actions/write"},
                execute,
            ],
        }
        files = {
            WORKFLOW: yaml.safe_dump(
                {"jobs": {name: {"steps": items} for name, items in jobs.items()}}
            ),
            ACTION: yaml.safe_dump({"runs": {"using": "composite", "steps": steps}}),
            WRITER_ACTION: yaml.safe_dump(
                {"runs": {"using": "composite", "steps": [{"run": source}]}}
            ),
            WRITER: "#!/bin/sh\n" + source,
            CHAIN: f"#!/bin/sh\nbash {WRITER}\nbash {TARGET}\n",
            TARGET: "#!/bin/sh\necho committed\n",
            PAYLOAD: "#!/bin/sh\nexit 7\n",
        }
        return files, {**files, PAYLOAD: "#!/bin/sh\necho ok\n"}

    def test_cross_step_generated_inventory(self) -> None:
        """Real consumer and catalog clusters exclude stale executable callers."""
        for operator in (">", ">>", ">|", "1>", "2>", "<>"):
            with self.subTest(operator=operator):
                source = f"cat {PAYLOAD} {operator} {TARGET}"
                files, right = self.separated_files(source)
                # Clobber syntax already fails closed in the bounded data guard.
                expected = {TARGET}
                if operator != ">|":
                    expected.update((WRITER, WRITER_ACTION))
                self.assert_matching_paths(files, right, expected)

    def test_cross_step_generated_cli(self) -> None:
        """The offline CLI excludes both cross-step and called-writer adoption."""
        files, right = self.separated_files(f"cat {PAYLOAD} > {TARGET}")
        for include_left in (True, False):
            with self.subTest(include_left=include_left):
                report = self.cli_report(files, right, include_left=include_left)
                report = report.split("## Public near matches", 1)[0]
                for path in (WORKFLOW, ACTION, CHAIN):
                    self.assertNotIn(f"`{path}`", report)
                for path in (TARGET, WRITER, WRITER_ACTION):
                    self.assertIn(f"`{path}`", report)

    def test_cross_step_generated_lookup_guards(self) -> None:
        """No stale body or local action is looked up after an active write."""
        source = f"cat {PAYLOAD} > {TARGET}"
        files, _ = self.separated_files(source)
        files["check/action.yml"] = yaml.safe_dump(
            {"runs": {"using": "composite", "steps": [{"run": f"bash {TARGET}"}]}}
        )
        for first in (
            {"run": source},
            {"run": f"bash {WRITER}"},
            {"uses": "./.github/actions/write"},
        ):
            resolver = syntax.SourceResolver("org/left", files)
            # Warm both caches before the write; cached bodies are stale too.
            resolver.script(TARGET)
            resolver.action("./check", frozenset())
            syntax.operation_shape(first, "org/left", files, resolver=resolver)
            with (
                self.subTest(first=first),
                patch.object(resolver, "script", side_effect=AssertionError),
                patch.object(resolver, "action", side_effect=AssertionError),
            ):
                result = syntax.operation_shape(
                    {"steps": [{"run": f"bash {TARGET}"}, {"uses": "./check"}]},
                    "org/left",
                    files,
                    resolver=resolver,
                )
                self.assertIn("<unresolved-", str(result))
        # A called writer can have a different command pattern from its caller.
        for invocation in (f"bash {WRITER}", "bash gen", "./scripts/gen.sh"):
            resolver = syntax.SourceResolver("org/left", {**files, "gen": source})

            def inspected(
                path: str,
                *args: Any,
                script: Callable[..., tuple[str, ...]] = resolver.script,
                **kwargs: Any,
            ) -> tuple[str, ...]:
                self.assertNotEqual(path, TARGET, "stale executable lookup")
                return script(path, *args, **kwargs)

            with (
                self.subTest(invocation=invocation),
                patch.object(resolver, "script", side_effect=inspected),
            ):
                shape = resolver.command(f"{invocation}\nbash {TARGET}")
                self.assertIn("<unresolved-", shape)

    def test_cross_step_generated_literal_controls(self) -> None:
        """Inert redirects and safe reads remain comparable across boundaries."""
        for source in (
            f"echo 'cat {PAYLOAD} > {TARGET}'",
            f'echo "cat {PAYLOAD} >> {TARGET}"',
            f"# cat {PAYLOAD} >| {TARGET}\necho ready",
            f"cat {PAYLOAD} \\> {TARGET}",
            f"cat {PAYLOAD}",
        ):
            with self.subTest(source=source):
                files, right = self.separated_files(source)
                expected = {path for path in files if model.selected(path)}
                self.assert_matching_paths(files, right, expected)
        # Writes followed only by data operations do not inspect stale bodies.
        files, right = self.separated_files(f"cat {PAYLOAD} > {TARGET}")
        block = {"steps": [{"run": f"cat {PAYLOAD} > {TARGET}"}, {"run": "echo ready"}]}
        self.assert_units_equivalent(
            job_unit("org/left", block, files=files),
            job_unit("org/right", block, files=right),
        )


if __name__ == "__main__":
    unittest.main()
