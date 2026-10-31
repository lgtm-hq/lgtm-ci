# SPDX-License-Identifier: MIT
"""Regressions for the two independent reviews of PR #1244 at 0d0182e."""

from __future__ import annotations

import copy
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from dataclasses import replace
from pathlib import Path
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_support import FakeGitHub, FixtureCase, model, scan, syntax

WORKFLOW = ".github/workflows/ci.yml"
ACTION = ".github/actions/check/action.yml"


def job_unit(
    repository: str,
    block: dict[str, Any],
    *,
    context: dict[str, Any] | None = None,
    files: dict[str, str] | None = None,
) -> model.Unit:
    """Build a real workflow job with a literal runner for matching tests."""
    source = yaml.safe_dump(
        {
            **(context or {}),
            "jobs": {"check": {"runs-on": "ubuntu-26.04", **block}},
        }
    )
    return model.file_units(
        repository, False, WORKFLOW, source, {WORKFLOW: source, **(files or {})}, ""
    )[0]


class Cases(FixtureCase):
    """One focused BATS case per review finding or related group of nits."""

    def test_implicit_shell(self) -> None:
        """GitHub's implicit shell lacks explicit bash's pipefail invocation."""
        implicit = {"run": "false | true"}
        explicit = {**implicit, "shell": "bash"}
        baseline = syntax.operation_shape(implicit, "org/example", {})
        bash = syntax.operation_shape(explicit, "org/example", {})
        self.assertEqual(baseline["shell"], "<implicit-shell>")
        self.assertEqual(bash["shell"], "bash")
        self.assertNotEqual(baseline, bash)
        inherited_shape = syntax.operation_shape(
            implicit, "org/example", {}, defaults={"shell": "bash"}
        )
        self.assertEqual(inherited_shape, bash)
        overridden_shape = syntax.operation_shape(
            explicit, "org/example", {}, defaults={"shell": "pwsh"}
        )
        self.assertEqual(overridden_shape, bash)
        left = job_unit("org/left", {"steps": [implicit]})
        right = job_unit("org/right", {"steps": [explicit]})
        self.assertEqual(model.clusters([left, right], [], 0.8), [])
        for scope in ("job", "workflow"):
            context = {"defaults": {"run": {"shell": "bash"}}}
            block = {"steps": [implicit]}
            inherited = job_unit(
                "org/example",
                {**block, **context} if scope == "job" else block,
                context=context if scope == "workflow" else {},
            )
            self.assertEqual(inherited.shape[1:], right.shape[1:])

    def test_python_path_parameters(self) -> None:
        """Ordinary Python strings normalize without resolving executables."""
        path = "scripts/check.py"
        source = (
            'from pathlib import Path\noutput = Path("build/output")\n'
            'if output.exists():\n    print("scripts/report.py", "a  b")\n'
        )
        left = model.units("org/left", False, {path: source})[0]
        right = model.units("org/right", False, {path: source})[0]
        self.assertEqual(left.fingerprint, right.fingerprint)
        self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
        parameter = model.units(
            "org/right", False, {path: source.replace("build/output", "dist/result")}
        )[0]
        self.assertEqual(left.fingerprint, parameter.fingerprint)
        unused = model.units(
            "org/right",
            False,
            {path: source, "build/output": "different unused content"},
        )[0]
        self.assertEqual(left.fingerprint, unused.fingerprint)
        for changed in (
            source.replace("    print", "print"),
            source.replace("if output.exists()", "if not output.exists()"),
            source.replace("a  b", "a b"),
        ):
            other = model.units("org/right", False, {path: changed})[0]
            self.assertNotEqual(left.fingerprint, other.fingerprint)

    def test_python_process_commands(self) -> None:
        """Uninspected Python process calls must not qualify as parameter copies."""
        path = "scripts/check.py"
        for source in (
            'import subprocess\nsubprocess.run(["tools/release"])\n',
            'import subprocess as sp\nsp.run(["tools/release"])\n',
            'from subprocess import run as execute\nexecute("scripts/check.sh")\n',
            'import os\nos.system("bash scripts/check.sh")\n',
            'import os as operating_system\noperating_system.system("tools/release")\n',
            'from os import system as execute\nexecute("tools/release")\n',
            'from os import (\n    system as execute,\n)\nexecute("tools/release")\n',
            "import subprocess\nsubprocess.run(command)\n",
        ):
            with self.subTest(source=source):
                left = model.units("org/left", False, {path: source})[0]
                right = model.units("org/right", False, {path: source})[0]
                self.assertEqual(model.clusters([left, right], [], 0.8), [])
        ordinary = 'from pathlib import Path\noutput = Path("subprocess/run")\n'
        self.assertEqual(
            syntax.script_shape(path, ordinary, "org/left", {}),
            syntax.script_shape(path, ordinary, "org/right", {}),
        )

    def test_working_directory_and_defaults(self) -> None:
        """Directory identity and inherited run defaults select the actual script."""
        block: dict[str, Any] = {"steps": [{"run": "bash scripts/check.sh"}]}
        files = {
            "scripts/check.sh": "echo misleading root copy",
            "apps/web/scripts/check.sh": "echo web",
            "apps/api/scripts/check.sh": "echo api",
        }
        for scope in ("step", "job", "workflow"):
            fingerprints = []
            for directory in ("apps/web", "apps/api"):
                changed = copy.deepcopy(block)
                context: dict[str, Any] = {}
                defaults = {"run": {"working-directory": directory}}
                if scope == "step":
                    changed["steps"][0]["working-directory"] = directory
                elif scope == "job":
                    changed["defaults"] = defaults
                else:
                    context["defaults"] = defaults
                original = job_unit(
                    "org/example",
                    changed,
                    context=context,
                    files=files,
                )
                fingerprints.append(original.fingerprint)
                altered = {**files, f"{directory}/scripts/check.sh": "echo different"}
                self.assertNotEqual(
                    original.fingerprint,
                    job_unit(
                        "org/example",
                        changed,
                        context=context,
                        files=altered,
                    ).fingerprint,
                )
                self.assertEqual(
                    original.fingerprint,
                    job_unit(
                        "org/example",
                        changed,
                        context=context,
                        files={**files, "scripts/check.sh": "echo unused root"},
                    ).fingerprint,
                )
            self.assertNotEqual(fingerprints[0], fingerprints[1])
        changed = copy.deepcopy(block)
        changed["defaults"] = {"run": {"working-directory": "apps/web"}}
        changed["steps"][0]["working-directory"] = "apps/api"
        baseline = job_unit("org/example", changed, files=files)
        self.assertNotEqual(
            baseline.fingerprint,
            job_unit(
                "org/example",
                changed,
                files={**files, "apps/api/scripts/check.sh": "echo different"},
            ).fingerprint,
        )

    def test_external_programs(self) -> None:
        """Unknown local programs cannot match across repos or by masked paths."""
        for command in (
            "bash build",
            '"./tools/my release"',
            '"${{ inputs.directory }}/tools/release"',
            "bash ${{ inputs.script }}",
            '"$CUSTOM_DIR/tools/release"',
            "$PROGRAM",
            "./build.sh",
            "./tools/release",
            "tools/release",
            "bash tools/release",
            "echo ready && ./tools/release",
        ):
            block = {"steps": [{"run": command}]}
            with self.subTest(command=command):
                left = job_unit("org/left", block)
                right = job_unit("org/right", block)
                self.assertEqual(model.clusters([left, right], [], 0.8), [])
        self.assertNotEqual(
            syntax.command_shape("./tools/release", "org/example", {}),
            syntax.command_shape("./tools/check", "org/example", {}),
        )
        block = {"steps": [{"run": "./build.sh"}]}
        left = job_unit("org/left", block, files={"build.sh": "terraform apply"})
        right = job_unit("org/right", block, files={"build.sh": "rm -rf /"})
        self.assertNotEqual(left.fingerprint, right.fingerprint)
        same = job_unit("org/right", block, files={"build.sh": "terraform apply"})
        self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)

    def test_fetch_external_dependencies(self) -> None:
        """The immutable blob inventory follows external scripts and nested actions."""
        sources = [
            yaml.safe_dump(
                {
                    "jobs": {
                        "check": {
                            "runs-on": "ubuntu-26.04",
                            "steps": [
                                {
                                    "run": "./tools/release",
                                    "working-directory": "apps/web",
                                },
                                {"uses": "./custom/check"},
                            ],
                        }
                    }
                }
            ),
            "#!/bin/bash\nbash scripts/helper.sh",
            "echo actual helper",
            "\n".join(
                (
                    "runs:",
                    "  using: composite",
                    "  steps:",
                    "    - uses: ./.github/actions/nested/deep",
                    "",
                )
            ),
            "".join(
                (
                    "runs:\n",
                    "  using: composite\n",
                    "  steps:\n",
                    "    - run: echo nested\n",
                    "      shell: bash\n",
                )
            ),
        ]
        paths = [
            WORKFLOW,
            "apps/web/tools/release",
            "apps/web/scripts/helper.sh",
            "custom/check/action.yml",
            ".github/actions/nested/deep/action.yaml",
        ]
        tree = {
            "tree": [
                {"type": "blob", "path": path, "sha": f"{index:040x}"}
                for index, path in enumerate(paths)
            ]
        }
        requests: list[list[str]] = []

        def response(endpoint: str, **kwargs: Any) -> Any:
            if "git/trees" in endpoint:
                return tree
            query = kwargs["payload"]["query"]
            selected = []
            for index in range(len(paths)):
                if f'object(oid: "{index:040x}")' in query:
                    selected.append(index)
            # GraphQL aliases follow the sorted requested paths, not tree order.
            selected.sort(key=lambda index: paths[index])
            requests.append([paths[index] for index in selected])
            return {
                "data": {
                    "repository": {
                        f"f{i}": {"isBinary": False, "text": sources[index]}
                        for i, index in enumerate(selected)
                    }
                }
            }

        with patch.object(scan.GitHub, "api", side_effect=response):
            fetched = scan.GitHub().files(
                {"full_name": "org/example", "default_branch": "main"},
            )
        self.assertEqual(set(fetched), set(paths))
        self.assertEqual(len(requests), 3)
        unit = model.units("org/example", False, fetched)[0]
        altered = {**fetched, "apps/web/scripts/helper.sh": "echo different"}
        self.assertNotEqual(
            unit.fingerprint, model.units("org/example", False, altered)[0].fingerprint
        )

    def test_local_actions(self) -> None:
        """Local actions resolve recursively with missing and cycle guards."""
        block = {"steps": [{"uses": "./.github/actions/check"}]}
        source = "".join(
            (
                "runs:\n",
                "  using: composite\n",
                "  steps:\n",
                "    - run: echo check\n",
                "      shell: bash\n",
            )
        )
        left = job_unit("org/left", block, files={ACTION: source})
        right = job_unit("org/right", block, files={ACTION: source})
        self.assertEqual(left.fingerprint, right.fingerprint)
        altered = source.replace("echo check", "echo unrelated")
        self.assertNotEqual(
            left.fingerprint,
            job_unit("org/right", block, files={ACTION: altered}).fingerprint,
        )
        nested = source.replace(
            "run: echo check\n      shell: bash",
            "uses: ./custom/nested",
        )
        files = {ACTION: nested, "custom/nested/action.yaml": source}
        left = job_unit("org/left", block, files=files)
        self.assertNotEqual(
            left.fingerprint,
            job_unit(
                "org/right",
                block,
                files={**files, "custom/nested/action.yaml": altered},
            ).fingerprint,
        )
        for files in (
            {},
            {ACTION: nested},
            {
                ACTION: source.replace(
                    "run: echo check\n      shell: bash",
                    "uses: ./.github/actions/check",
                )
            },
            {ACTION: "runs:\n  using: node24\n  main: index.js\n"},
        ):
            self.assertNotEqual(
                job_unit("org/left", block, files=files).fingerprint,
                job_unit("org/right", block, files=files).fingerprint,
            )

    def test_catalog_sequence_compatibility(self) -> None:
        """Valid jobs match catalog operations without discarding consumer metadata."""
        steps = [
            {"run": "echo hello", "shell": "bash"},
            {"uses": "actions/github-script@abc", "with": {"script": "check()"}},
        ]
        source = yaml.safe_dump({"runs": {"using": "composite", "steps": steps}})
        reference = model.file_units(
            scan.TARGET,
            False,
            ACTION,
            source,
            {ACTION: source},
            "check",
        )[0]
        block: dict[str, Any] = {
            "steps": steps,
            "needs": "build",
            "permissions": {"contents": "read"},
        }
        job = job_unit("org/example", block)
        self.assertEqual(len(model.clusters([job], [reference], 0.8)), 1)
        title, _ = model.render(([job], [reference], 1.0), 0.8)
        self.assertEqual(title, "refactor(adoption): adopt check from lgtm-ci (1 repo)")
        other = job_unit("org/other", {**block, "runs-on": "windows-2025"})
        self.assertEqual(model.clusters([job, other], [], 0.8), [])
        for key, value in (
            ("env", {"MODE": "publish"}),
            ("defaults", {"run": {"working-directory": "apps/web"}}),
            ("defaults", {"run": {"shell": "pwsh"}}),
        ):
            changed = copy.deepcopy(block)
            # Omit explicit shell to exercise defaults.run.shell inheritance.
            changed["steps"][0].pop("shell")
            changed[key] = value
            self.assertEqual(
                model.clusters([job_unit("org/example", changed)], [reference], 0.8), []
            )
        changed = copy.deepcopy(block)
        changed["steps"].reverse()
        self.assertEqual(
            model.clusters(
                [job_unit("org/example", changed)],
                [reference],
                0.8,
            ),
            [],
        )
        changed = copy.deepcopy(block)
        changed["steps"][1]["with"]["script"] = "publish()"
        self.assertEqual(
            model.clusters(
                [job_unit("org/example", changed)],
                [reference],
                0.8,
            ),
            [],
        )

    def test_quoted_script_whitespace(self) -> None:
        """Standalone script tokens retain significant spaces inside string literals."""
        for suffix in ("sh", "js", "rb"):
            left = model.units(
                "org/left",
                False,
                {
                    f"scripts/check.{suffix}": "printf '%s' 'a b'",
                },
            )[0]
            right = model.units(
                "org/right",
                False,
                {
                    f"scripts/check.{suffix}": "printf '%s' 'a  b'",
                },
            )[0]
            self.assertNotEqual(left.fingerprint, right.fingerprint)
            self.assertEqual(model.clusters([left, right], [], 0.8), [])
        self.assertEqual(
            syntax.script_shape(
                "scripts/a.sh",
                "echo  'a  b' # comment",
                "org/example",
                {},
            ),
            syntax.script_shape("scripts/a.sh", "echo 'a  b'", "org/example", {}),
        )

    def test_public_identifier_marker_injection(self) -> None:
        """Jobs, inputs, paths, reference names and snippets cannot forge identities."""
        fingerprint = "f" * 24
        marker = f"<!-- lgtm-ci:dup-scan:{fingerprint} -->"
        hostile = f"x`\r\n{marker}\n{model.MEMBERS_END}\n```\n"
        baseline = job_unit("org/example", {"steps": [{"run": "echo hello"}]})
        for field in ("job", "path", "repository", "parameters", "source", "reference"):
            value: Any = (hostile,) if field == "parameters" else hostile
            changed = replace(baseline, **{field: value})
            title, body = model.render(([changed], [changed], 1.0), 0.8)
            with self.subTest(field=field):
                self.assertNotIn("\n", title)
                self.assertFalse(scan.has_marker(body, marker))
                self.assertEqual(body.count(model.MEMBERS_END), 1)
                self.assertEqual(len(scan.membership(body)), 1)
                api = FakeGitHub(
                    [
                        {
                            "number": 1,
                            "state": "closed",
                            "state_reason": "not_planned",
                            "body": body,
                        }
                    ]
                )
                counts = scan.reconcile(
                    api, [(fingerprint, "candidate", "body")], dry_run=True, cap=5
                )
                self.assertEqual(counts["created"], 1)
        source = yaml.safe_dump(
            {
                "jobs": {
                    hostile: {
                        "runs-on": "ubuntu-26.04",
                        "steps": [
                            {
                                "uses": "unknown/action@abc",
                                "with": {hostile: "value"},
                            }
                        ],
                    }
                }
            }
        )
        unit = model.file_units("org/public", False, WORKFLOW, source, {}, "")[0]
        _, body = model.render(([unit], [], 1.0), 0.8)
        self.assertFalse(scan.has_marker(body, marker))

    def test_human_titles_and_crlf(self) -> None:
        """Keep web line endings and human titles; refresh generated counts."""
        group = next(group for group in self.groups if group[0][0].kind == "steps")
        title, body = model.render(group, 0.8)
        fingerprint = group[0][0].fingerprint
        existing = body.replace("\n", "\r\n") + "Owner notes\r\n"
        for issue_title in (title, "Owner's adoption plan"):
            api = FakeGitHub(
                [{"number": 1, "state": "open", "title": issue_title, "body": existing}]
            )
            self.assertEqual(
                scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)[
                    "unchanged"
                ],
                1,
            )
            self.assertEqual(api.writes, [])
        stale = title.rsplit("(", 1)[0] + "(99 repos)"
        api = FakeGitHub([{"number": 1, "state": "open", "title": stale, "body": body}])
        self.assertEqual(
            scan.reconcile(
                api,
                [(fingerprint, title, body)],
                dry_run=False,
                cap=5,
            )["updated"],
            1,
        )
        self.assertEqual(api.issues[0]["title"], title)
        api.issues[0].update(
            title="Owner's adoption plan",
            body=body.replace(
                model.MEMBERS_BEGIN,
                model.MEMBERS_BEGIN + "\n- `org/new`: `ci.yml`",
            ),
        )
        scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(api.issues[0]["title"], "Owner's adoption plan")
        self.assertEqual(scan.membership(api.issues[0]["body"]), scan.membership(body))

    def test_dependency_memoization(self) -> None:
        """Diamond script graphs normalize each distinct dependency once."""
        files = {
            "scripts/top.sh": "bash scripts/a.sh\nbash scripts/b.sh",
            "scripts/a.sh": "bash scripts/shared.sh",
            "scripts/b.sh": "bash scripts/shared.sh",
            "scripts/shared.sh": "echo shared",
        }
        resolver = syntax.SourceResolver("org/example", files)
        with patch.object(resolver, "command", wraps=resolver.command) as command:
            resolver.script("scripts/top.sh")
            resolver.script("scripts/top.sh")
        self.assertEqual(command.call_count, len(files))

    def test_local_readiness_without_output(self) -> None:
        """A local readiness check prints the result when GITHUB_OUTPUT is absent."""
        output = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), redirect_stdout(output):
            self.assertEqual(scan.check_readiness(), 0)
        self.assertIn("ready=false", output.getvalue())

    def test_catalog_shape_validation(self) -> None:
        """Malformed catalog roots fail explicitly before indexing entries."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "catalog").mkdir()
            for source in ("", "[]", "entries: null"):
                (root / "catalog/catalog.yml").write_text(source, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "entries list"):
                    scan.references(root)


if __name__ == "__main__":
    unittest.main()
