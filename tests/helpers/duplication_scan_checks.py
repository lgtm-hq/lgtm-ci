# SPDX-License-Identifier: MIT
"""Offline model, rendering and issue lifecycle cases driven by BATS."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Any

import duplication_scan_support as support
import yaml
from duplication_scan_support import FIXTURES, FixtureCase, model, scan, syntax


# Each named test is an independently runnable BATS scenario.
class Cases(FixtureCase):  # pylint: disable=too-many-public-methods
    """Select one model or issue lifecycle scenario by its BATS case name."""

    def examples(self, order: tuple[bool, ...], newline: str) -> tuple[str, list[str]]:
        """Build real rendered examples with long fences and surrounding notes."""
        parts = ["<!-- lgtm-ci:dup-scan:0123456789abcdef01234567 -->\nOwner before.\n"]
        public: list[str] = []
        for index, private in enumerate(order):
            label = "PRIVATE_CANARY" if private else "public-safe"
            unit = model.Unit(
                "org/private" if private else "org/public",
                "scripts/check.sh",
                "",
                False,
                "script",
                ("same",),
                f"echo {label}-{index}\n```\necho done",
                (f"{label}_input_{index}",),
            )
            _, rendered = model.render(([unit], [], 1.0), 0.8)
            example = rendered[rendered.index("Action input names:") :]
            parts.append(example + f"\nOwner between {index}.\n")
            if not private:
                public.append(example.replace("\n", newline))
        return "\n".join(parts).replace("\n", newline), public

    def test_multiple_example_privacy_cleanup(self) -> None:
        """Mixed and repeated private examples redact independently on partial scans."""
        for order in (
            (False, True),
            (True, False),
            (True, True, False, True),
            (False, True, False),
        ):
            for newline in ("\n", "\r\n"):
                for dry_run in (False, True):
                    existing, public = self.examples(order, newline)
                    api = support.FakeGitHub(
                        [
                            {
                                "number": 1,
                                "state": "closed",
                                "state_reason": "not_planned",
                                "title": "Owner title",
                                "body": existing,
                            }
                        ]
                    )
                    api.skipped["invalid source"] += 1
                    counts = scan.reconcile(
                        api,
                        [],
                        dry_run=dry_run,
                        cap=5,
                        public_repositories={"org/public"},
                    )
                    self.assertEqual(counts["redacted"], 1)
                    self.assertEqual(len(api.writes), 0 if dry_run else 1)
                    if dry_run:
                        self.assertEqual(api.issues[0]["body"], existing)
                        continue
                    result = api.issues[0]["body"]
                    self.assertNotIn("PRIVATE_CANARY", result)
                    for example in public:
                        self.assertIn(example, result)
                    self.assertIn("Owner before.", result)
                    for index in range(len(order)):
                        self.assertIn(f"Owner between {index}.", result)
                    self.assertEqual(api.issues[0]["state_reason"], "not_planned")

    def test_multiple_example_refresh(self) -> None:
        """Refreshing all examples retains public content and strips private inputs."""
        for order in (
            (False, True),
            (True, False),
            (True, True, False, True),
            (False, True, False),
        ):
            for newline in ("\n", "\r\n"):
                existing, public = self.examples(order, newline)
                refreshed = scan.refresh_public_source(existing, "\n".join(public))
                self.assertNotIn("PRIVATE_CANARY", refreshed)
                for example in public:
                    self.assertIn(example, refreshed)
                for index in range(len(order)):
                    self.assertIn(f"Owner between {index}.", refreshed)

    def test_external_action_subpath_case(self) -> None:
        """Repository case folds while external subpath and local identity survive."""

        def action(repository: str, target: str) -> model.Unit:
            job = {"steps": [{"uses": target}]}
            workflow = yaml.safe_dump({"jobs": {"check": job}})
            files = {".github/workflows/ci.yml": workflow}
            return model.units(repository, False, files)[0]

        upper = action("org/a", "OWNER/REPO/Build@v1")
        same = action("org/b", "owner/repo/Build@v2")
        different = action("org/b", "owner/repo/build@v1")
        self.assert_units_equivalent(upper, same)
        self.assertNotEqual(upper.fingerprint, different.fingerprint)
        self.assertEqual(model.clusters([upper, different], [], 0.8), [])
        local = action("org/a", "./Actions/Build")
        other_local = action("org/a", "./actions/build")
        self.assertNotEqual(local.fingerprint, other_local.fingerprint)

    def test_historical_source_privacy(self) -> None:
        """Reopen/update redacts generated private source and keeps human edits."""
        original = model.Unit(
            "org/previously-public",
            ".github/workflows/ci.yml",
            "check",
            False,
            "steps",
            ("same logic",),
            "echo PRIVATE_SOURCE_CANARY\n```\n# historical source",
            ("PRIVATE_INPUT_CANARY",),
        )
        for unit in (
            original,
            replace(original, path="scripts/check.sh", kind="script", job=""),
        ):
            with self.subTest(kind=unit.kind):
                self.check_historical_source_privacy(unit)

    # The lifecycle check includes payload privacy, human edits and idempotence.
    # pylint: disable-next=too-many-locals
    def check_historical_source_privacy(self, original: model.Unit) -> None:
        """Check transitions with changed and unchanged visible member rows."""
        other = replace(original, repository="org/other", source="echo public-safe")
        _, old_body = model.render(([original, other], [], 1.0), 0.8)
        before = "Owner triage before: keep tracker #1237.\n\n"
        after = "\nOwner notes after: keep the rollout blocked.\n"
        human_title = "Owner's adoption plan"
        for state in ("open", "closed"):
            for all_private in (True, False):
                for crlf in (True, False):
                    with self.subTest(state=state, all_private=all_private, crlf=crlf):
                        members = [
                            replace(original, private=True),
                            replace(other, private=all_private, parameters=()),
                        ]
                        title, body = model.render((members, [], 1.0), 0.8)
                        existing = before + old_body + after
                        if crlf:
                            existing = existing.replace("\n", "\r\n")
                        reason = "completed" if state == "closed" else None
                        api = support.FakeGitHub(
                            [
                                {
                                    "number": 1,
                                    "state": state,
                                    "state_reason": reason,
                                    "title": human_title,
                                    "body": existing,
                                }
                            ]
                        )
                        counts = scan.reconcile(
                            api,
                            [(original.fingerprint, title, body)],
                            dry_run=False,
                            cap=5,
                        )
                        action = "reopened" if state == "closed" else "updated"
                        self.assertEqual(counts[action], 1)
                        self.assertEqual(api.issues[0]["title"], human_title)
                        self.assertEqual(api.issues[0]["state"], "open")
                        result = api.issues[0]["body"].replace("\r\n", "\n")
                        self.assertTrue(result.startswith(before))
                        self.assertTrue(result.endswith(after))
                        for _, payload in api.writes:
                            self.assertNotIn("PRIVATE_", json.dumps(payload))
                        if not all_private:
                            self.assertIn("echo public-safe", result)
                        api.writes.clear()
                        self.assertEqual(
                            scan.reconcile(
                                api,
                                [(original.fingerprint, title, body)],
                                dry_run=False,
                                cap=5,
                            )["unchanged"],
                            1,
                        )
                        self.assertEqual(api.writes, [])

    def test_near_identical_jobs(self) -> None:
        """Near identical jobs."""
        jobs = next(group[0] for group in self.groups if group[0][0].kind == "steps")
        self.assertEqual(
            {unit.job for unit in jobs},
            {"publish", "ship", "SECRET_JOB_CANARY"},
        )
        self.assertFalse(
            any(unit.job == "local" for group in self.groups for unit in group[0]),
        )

    def test_small_scripts(self) -> None:
        """Small scripts."""
        groups = (group[0] for group in self.groups)
        scripts = next(members for members in groups if members[0].kind == "script")
        self.assertEqual(len(scripts), 2)

    def test_parameter_only_control_flow(self) -> None:
        """Parameter only control flow."""
        files = self.repositories[0]["files"]
        altered = files[".github/workflows/ci.yml"].replace(
            "runs-on:", "if: ${{ github.ref == 'refs/heads/other' }}\n    runs-on:"
        )
        original = model.units("lgtm-hq/alpha", False, files)[0]
        changed = model.units(
            "lgtm-hq/beta",
            False,
            {".github/workflows/ci.yml": altered},
        )[0]
        self.assertNotEqual(original.fingerprint, changed.fingerprint)

    def test_execution_inputs_and_metadata(self) -> None:
        """Execution inputs and metadata."""

        def fingerprint(block: dict[str, Any], **context: Any) -> str:
            unit = model.units(
                "org/example",
                False,
                {
                    ".github/workflows/ci.yml": yaml.safe_dump(
                        {**context, "jobs": {"check": block}},
                    )
                },
            )[0]
            return str(unit.fingerprint)

        original: dict[str, Any] = {
            "runs-on": "ubuntu-26.04",
            "steps": [
                {
                    "uses": "actions/github-script@abc",
                    "with": {"script": "build()"},
                }
            ],
        }
        changed = copy.deepcopy(original)
        changed["steps"][0]["with"]["script"] = "publish()"
        self.assertNotEqual(fingerprint(original), fingerprint(changed))
        for key, first, second in [
            ("needs", "build", "test"),
            ("permissions", {"contents": "read"}, {"contents": "write"}),
            ("runs-on", "ubuntu-24.04", "ubuntu-26.04"),
            ("env", {"MODE": "build"}, {"MODE": "publish"}),
            ("timeout-minutes", 5, 10),
        ]:
            with self.subTest(key=key):
                self.assertNotEqual(
                    fingerprint({**original, key: first}),
                    fingerprint({**original, key: second}),
                )
        changed = copy.deepcopy(original)
        changed["steps"][0]["uses"] = "unknown/action@abc"
        baseline = copy.deepcopy(changed)
        changed["steps"][0]["with"]["script"] = "different()"
        self.assertNotEqual(fingerprint(baseline), fingerprint(changed))
        self.assertNotEqual(
            fingerprint(original, env={"MODE": "build"}),
            fingerprint(original, env={"MODE": "publish"}),
        )

    def test_order_matters(self) -> None:
        """Order matters."""
        source = self.repositories[0]["files"][".github/workflows/ci.yml"]
        data = yaml.safe_load(source)
        data["jobs"]["publish"]["steps"].reverse()
        changed = model.units(
            "lgtm-hq/alpha", False, {".github/workflows/ci.yml": yaml.safe_dump(data)}
        )[0]
        original = next(unit for unit in self.units if unit.job == "publish")
        self.assertNotEqual(original.fingerprint, changed.fingerprint)

    def test_comments_and_quotes(self) -> None:
        """Comments and quotes."""
        self.assertEqual(
            syntax.normalize('echo "# keep" # drop', "org/repo"),
            'echo "# keep"',
        )
        self.assertNotEqual(
            syntax.normalize('sh -c "rm -rf ./build"', "org/repo"),
            syntax.normalize('sh -c "mkdir ./build"', "org/repo"),
        )
        self.assertNotEqual(
            syntax.normalize("${{ inputs.ready && 'build' || 'skip' }}", "org/repo"),
            syntax.normalize("${{ inputs.ready && 'publish' || 'skip' }}", "org/repo"),
        )

    def test_called_scripts_are_logic(self) -> None:
        """Called scripts are logic."""
        source = "".join(
            (
                "jobs:\n",
                "  check:\n",
                "    runs-on: ubuntu-26.04\n",
                "    steps:\n",
                "      - run: bash scripts/check.sh\n",
            )
        )
        left = model.units(
            "org/left",
            False,
            {
                ".github/workflows/ci.yml": source,
                "scripts/check.sh": "terraform validate",
            },
        )[0]
        right = model.units(
            "org/right",
            False,
            {".github/workflows/ci.yml": source, "scripts/check.sh": "bats tests"},
        )[0]
        self.assertNotEqual(left.fingerprint, right.fingerprint)
        self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_exact_nested_and_extensionless_scripts(self) -> None:
        """Exact nested and extensionless scripts."""
        files = {
            "scripts/deploy.sh": "echo deploy",
            "scripts/test/deploy.sh": "echo test",
            "scripts/wrapper.sh": "bash scripts/deploy.sh",
            "scripts/release": "#!/bin/bash\necho release",
            "scripts/check": "#!/bin/bash\necho check",
        }
        original = syntax.command_shape(
            "bash ./scripts/wrapper.sh",
            "org/example",
            files,
        )
        changed = {**files, "scripts/deploy.sh": "echo different"}
        self.assertNotEqual(
            original,
            syntax.command_shape("bash ./scripts/wrapper.sh", "org/example", changed),
        )
        missing = {"scripts/test/deploy.sh": "echo deploy"}
        unresolved = syntax.command_shape(
            "bash scripts/deploy.sh",
            "org/example",
            missing,
        )
        self.assertIn("unresolved-script", unresolved)
        self.assertNotEqual(
            unresolved,
            syntax.command_shape("bash scripts/deploy.sh", "org/example", files),
        )
        self.assertNotEqual(
            syntax.command_shape("bash scripts/release", "org/example", files),
            syntax.command_shape("bash scripts/check", "org/example", files),
        )
        self.assertNotEqual(
            syntax.command_shape("bash scripts/unknown", "org/example", files),
            syntax.command_shape("bash scripts/other", "org/example", files),
        )
        cycle = {
            "scripts/a.sh": "bash scripts/b.sh",
            "scripts/b.sh": "bash scripts/a.sh",
        }
        self.assertIn(
            "script:",
            syntax.command_shape("bash scripts/a.sh", "org/example", cycle),
        )

    def test_shell_expansions(self) -> None:
        """Shell expansions."""
        for left, right in [
            ('echo "${value/foo/bar}"', 'echo "${value/baz/qux}"'),
            ('echo "$((value/foo/bar))"', 'echo "$((value/baz/qux))"'),
        ]:
            self.assertNotEqual(
                syntax.normalize(left, "org/example"),
                syntax.normalize(right, "org/example"),
            )

    def test_python_indentation_and_shell_boundaries(self) -> None:
        """Python indentation and shell boundaries."""
        left = "if ready:\n    build()\n    publish()\n"
        right = "if ready:\n    build()\npublish()\n"
        self.assertNotEqual(
            syntax.script_shape("scripts/check.py", left, "org/repo", {}),
            syntax.script_shape("scripts/check.py", right, "org/repo", {}),
        )
        self.assertNotEqual(
            syntax.normalize("echo one\necho two", "org/repo"),
            syntax.normalize("echo one echo two", "org/repo"),
        )
        self.assertEqual(
            syntax.normalize("// comment\nconsole.log(1)", "org/repo"), "console.log(1)"
        )

    def test_private_parse_error_redaction(self) -> None:
        """Private parse error redaction."""
        with self.assertRaises(ValueError) as error:
            syntax.script_shape(
                "scripts/private.py",
                "if ready:\n    build()\n  SECRET_SOURCE_CANARY()\n",
                "org/private",
                {},
            )
        self.assertNotIn("SECRET_SOURCE_CANARY", str(error.exception))
        self.assertIn("scripts/private.py", str(error.exception))

    def test_composite_matches_job(self) -> None:
        """Composite matches job."""
        action = model.units(
            scan.TARGET,
            False,
            {
                ".github/actions/example/action.yml": (
                    "".join(
                        (
                            "runs:\n",
                            "  using: composite\n",
                            "  steps:\n",
                            "    - run: echo hello\n",
                            "      shell: bash\n",
                        )
                    )
                )
            },
            "example",
        )[0]
        job = model.units(
            "org/repo",
            False,
            {
                ".github/workflows/ci.yml": (
                    "".join(
                        (
                            "jobs:\n",
                            "  example:\n",
                            "    runs-on: ubuntu-26.04\n",
                            "    steps:\n",
                            "      - run: echo hello\n",
                            "        shell: bash\n",
                        )
                    )
                )
            },
        )[0]
        self.assertEqual(len(model.clusters([job], [action], 0.8)), 1)

    def test_allowlist(self) -> None:
        """Allowlist."""
        rows = model.load_exceptions(FIXTURES / "local-exceptions.yml")
        excluded = [unit for unit in self.units if model.excepted(unit, rows)]
        self.assertEqual([unit.job for unit in excluded], ["ship"])
        public = (unit for unit in self.units if not unit.private)
        filtered = [unit for unit in public if not model.excepted(unit, rows)]
        groups = model.clusters(filtered, [], 0.8)
        self.assertFalse(any(group[0][0].kind == "steps" for group in groups))
        rows[0].pop("job")
        self.assertTrue(model.excepted(excluded[0], rows))

    def test_allowlist_fail_closed(self) -> None:
        """Allowlist fail closed."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "exceptions.yml"
            with self.assertRaisesRegex(ValueError, "prerequisite #1236"):
                model.load_exceptions(path)
            path.write_text("exceptions: [{}]\n")
            with self.assertRaises(ValueError):
                model.load_exceptions(path)
            valid = yaml.safe_load((FIXTURES / "local-exceptions.yml").read_text())
            for key, header in [
                ("schema-version", 2),
                ("schema-version", True),
                ("extra", 1),
            ]:
                path.write_text(yaml.safe_dump({**valid, key: header}))
                with self.assertRaises(ValueError):
                    model.load_exceptions(path)
            for key, value in [
                ("repo", "invalid"),
                ("path", "../escape"),
                ("job", ""),
                ("reason", "two\nlines"),
                ("link", "https://example.com"),
                ("extra", "field"),
                ("repo", "org/repo\n"),
                ("path", "scripts/check.sh\n"),
                ("job", "check\n"),
                ("link", "https://github.com/org/repo/issues/1\n"),
            ]:
                changed = copy.deepcopy(valid)
                changed["exceptions"][0][key] = value
                path.write_text(yaml.safe_dump(changed))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    model.load_exceptions(path)

    def test_catalog_match(self) -> None:
        """Catalog match."""
        consumer = next(unit for unit in self.units if unit.job == "publish")
        reference = model.Unit(
            scan.TARGET,
            ".github/actions/publish/action.yml",
            "",
            False,
            consumer.kind,
            consumer.shape,
            consumer.source,
            reference="publish",
        )
        groups = model.clusters([consumer], [reference], 0.8)
        self.assertEqual(len(groups), 1)
        self.assertIn("Existing catalog", model.render(groups[0], 0.8)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "catalog").mkdir()
            (root / ".github/actions/publish").mkdir(parents=True)
            (root / "catalog/catalog.yml").write_text(
                "entries:\n  - id: publish\n    kind: composite-action\n"
            )
            (root / ".github/actions/publish/action.yml").write_text(
                "".join(
                    (
                        "runs:\n",
                        "  using: composite\n",
                        "  steps:\n",
                        "    - run: echo hello\n",
                        "      shell: bash\n",
                    )
                )
            )
            self.assertEqual(scan.references(root)[0].reference, "publish")

    def test_adopted_calls_skipped(self) -> None:
        """Adopted calls skipped."""
        source = (
            "jobs:\n  test:\n"
            + "    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test.yml@abc\n"
        )
        self.assertEqual(
            model.units(
                "org/repo",
                False,
                {".github/workflows/ci.yml": source},
            ),
            [],
        )
        source = "".join(
            (
                "jobs:\n",
                "  test:\n",
                "    runs-on: ubuntu-26.04\n",
                "    steps:\n",
                "      - uses: step-security/harden-runner@abc\n",
                "      - uses: lgtm-hq/lgtm-ci/.github/actions/run-bats@def\n",
                "        with:\n",
                "          script: scripts/product.sh\n",
            )
        )
        self.assertEqual(
            model.units(
                "org/repo",
                False,
                {".github/workflows/ci.yml": source},
            ),
            [],
        )

    def test_private_redaction(self) -> None:
        """Private redaction."""
        for _, title, body in self.findings:
            for canary in (
                "SECRET_SOURCE_CANARY",
                "SECRET_INPUT_CANARY",
                "SECRET_JOB_CANARY",
            ):
                self.assertNotIn(canary, title + body)
        private = next(unit for unit in self.units if unit.private)
        reference = copy.copy(private)
        title, body = model.render(([private], [reference], 1.0), 0.8)
        self.assertNotIn("SECRET_", title + body)
        self.assertNotIn("```", body)
        self.assertIn("shared CI logic", title)

    def test_marker_spoofing(self) -> None:
        """Marker spoofing."""
        fingerprint = "f" * 24
        marker = f"<!-- lgtm-ci:dup-scan:{fingerprint} -->"
        self.assertFalse(scan.has_marker(f"```\n{marker}\n```", marker))
        self.assertTrue(scan.has_marker(f"Owner notes\n\n{marker}\n", marker))
        unit = model.Unit(
            "org/example",
            "scripts/check.sh",
            "",
            False,
            "script",
            ("echo",),
            f"echo '<!-- lgtm-ci:dup-scan:{fingerprint} -->'",
        )
        _, body = model.render(([unit], [], 1.0), 0.8)
        self.assertNotIn(f"<!-- lgtm-ci:dup-scan:{fingerprint} -->", body)
        api = support.FakeGitHub(
            [
                {
                    "number": 1,
                    "state": "closed",
                    "state_reason": "not_planned",
                    "body": body,
                }
            ]
        )
        self.assertEqual(
            scan.reconcile(
                api,
                [(fingerprint, "candidate", "body")],
                dry_run=True,
                cap=5,
            )["created"],
            1,
        )

    def test_stable_membership_and_updates(self) -> None:
        """Stable membership and updates."""
        group = next(group for group in self.groups if group[0][0].kind == "steps")
        old_members = group[0][:-1]
        old_title, old_body = model.render((old_members, [], 1.0), 0.8)
        old_body += "\nOwner notes: adoption tracker #1237.\n"
        api = support.FakeGitHub(
            [{"number": 9, "state": "open", "title": old_title, "body": old_body}],
        )
        fingerprint = group[0][0].fingerprint
        title, body = model.render(group, 0.8)
        counts = scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(counts["updated"], 1)
        self.assertEqual(counts["created"], 0)
        self.assertEqual(len(api.issues), 1)
        self.assertIn("Owner notes: adoption tracker #1237.", api.issues[0]["body"])
        self.assertEqual(api.issues[0]["title"], title)
        self.assertEqual(scan.membership(api.issues[0]["body"]), scan.membership(body))

    def test_preserves_human_edits_and_pin_bumps(self) -> None:
        """Preserves human edits and pin bumps."""
        fingerprint, title, body = self.findings[0]
        existing = "Owner triage: link #1237.\n\n" + body + "\nFollow-up notes.\n"
        api = support.FakeGitHub(
            [{"number": 1, "state": "open", "title": title, "body": existing}],
        )
        changed = body + "\nDifferent generated snippet or pin.\n"
        counts = scan.reconcile(
            api,
            [(fingerprint, title, changed)],
            dry_run=False,
            cap=5,
        )
        self.assertEqual(counts["unchanged"], 1)
        self.assertEqual(api.writes, [])
        self.assertEqual(api.issues[0]["body"], existing)
        self.assertFalse(api.reads[0][1])

    def test_rerun_deduplication(self) -> None:
        """Rerun deduplication."""
        api = support.FakeGitHub()
        first = scan.reconcile(api, self.findings, dry_run=False, cap=5)
        self.assertEqual(first["created"], 2)
        api.writes.clear()
        second = scan.reconcile(api, self.findings, dry_run=False, cap=5)
        self.assertEqual(second["unchanged"], 2)
        self.assertEqual(api.writes, [])

    def test_not_planned_silent(self) -> None:
        """Not planned silent."""
        fingerprint, title, body = self.findings[0]
        api = support.FakeGitHub(
            [
                {
                    "number": 1,
                    "state": "closed",
                    "state_reason": "not_planned",
                    "body": body,
                }
            ]
        )
        counts = scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(counts["suppressed"], 1)
        self.assertEqual(api.writes, [])

    def test_completed_reopens(self) -> None:
        """Completed reopens."""
        fingerprint, title, body = self.findings[0]
        api = support.FakeGitHub(
            [
                {
                    "number": 1,
                    "state": "closed",
                    "state_reason": "completed",
                    "body": body,
                }
            ]
        )
        counts = scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(counts["reopened"], 1)
        self.assertEqual(api.issues[0]["state"], "open")
        self.assertEqual(len(api.writes), 4)
        self.assertTrue(api.writes[-2][0].endswith("/comments"))
        self.assertEqual(len(api.comments[1]), 1)
        self.assertIn(":delivered -->", api.issues[0]["body"])

    def test_cap_and_dry_run(self) -> None:
        """Cap and dry run."""
        fingerprints = [f"{i:024x}" for i in range(8)]
        findings = [
            (
                fp,
                "candidate",
                f"<!-- lgtm-ci:dup-scan:{fp} -->",
            )
            for fp in fingerprints
        ]
        api = support.FakeGitHub()
        counts = scan.reconcile(api, findings, dry_run=True, cap=5)
        self.assertEqual((counts["created"], counts["deferred"]), (5, 3))
        self.assertEqual(api.writes, [])
        counts = scan.reconcile(api, findings, dry_run=False, cap=5)
        self.assertEqual((len(api.writes), counts["deferred"]), (5, 3))

    def test_threshold_controls_near_matches(self) -> None:
        """Threshold controls near matches."""
        left = model.Unit(
            "org/left", "scripts/check.sh", "", False, "script", tuple("abcdefghij"), ""
        )
        right = model.Unit(
            "org/right",
            "scripts/check.sh",
            "",
            False,
            "script",
            tuple("abcdefghiZ"),
            "",
        )
        self.assertEqual(len(model.near_matches([left, right], [], 0.7)), 1)
        self.assertEqual(model.near_matches([left, right], [], 0.8), [])
        self.assertEqual(model.clusters([left, right], [], 0.7), [])
        self.assertEqual(
            model.near_matches(
                [left],
                [
                    model.Unit(
                        "org/hidden",
                        right.path,
                        "",
                        True,
                        right.kind,
                        right.shape,
                        "",
                    )
                ],
                0.7,
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
