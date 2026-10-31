# SPDX-License-Identifier: MIT
"""Offline cases driven individually by test_duplication_scan.bats."""

from __future__ import annotations

import copy
import io
import json
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import yaml
from gha_expr import evaluate

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/ci/maintenance"))
import duplication_model as model  # noqa: E402
import duplication_scan as scan  # noqa: E402

FIXTURES = ROOT / "tests/fixtures/duplication-scan"


class FakeGitHub:
    """Stateful issue transport: no process, network or credentials."""

    def __init__(self, issues=None):
        self.issues = copy.deepcopy(issues or [])
        self.writes = []

    def api(self, endpoint, *, payload=None, read=True):
        if read:
            if "state=all" not in endpoint:
                raise AssertionError("must include closed issues")
            return copy.deepcopy(self.issues)
        self.writes.append((endpoint, copy.deepcopy(payload)))
        if endpoint.endswith("/comments"):
            return {}
        if payload.get("_method") == "PATCH":
            number = int(endpoint.rsplit("/", 1)[1])
            issue = next(item for item in self.issues if item["number"] == number)
            issue.update({key: value for key, value in payload.items() if key != "_method"})
        else:
            self.issues.append({**payload, "state": "open", "number": len(self.issues) + 1})
        return {}


class Cases(unittest.TestCase):
    """The BATS case name selects exactly one offline scenario."""

    def setUp(self):
        self.repositories = yaml.safe_load((FIXTURES / "repositories.yml").read_text())[
            "repositories"
        ]
        self.units = [
            unit
            for repo in self.repositories
            for unit in model.units(repo["full_name"], repo["private"], repo["files"])
        ]
        self.groups = model.clusters(self.units, [], 0.8)
        self.findings = [
            (group[0][0].fingerprint, *model.render(group, 0.8)) for group in self.groups
        ]

    def test_near_identical_jobs(self):
        jobs = next(group[0] for group in self.groups if group[0][0].kind == "steps")
        self.assertEqual({unit.job for unit in jobs}, {"publish", "ship", "SECRET_JOB_CANARY"})
        self.assertFalse(any(unit.job == "local" for group in self.groups for unit in group[0]))

    def test_small_scripts(self):
        scripts = next(group[0] for group in self.groups if group[0][0].kind == "script")
        self.assertEqual(len(scripts), 2)

    def test_parameter_only_control_flow(self):
        files = self.repositories[0]["files"]
        altered = files[".github/workflows/ci.yml"].replace(
            "runs-on:", "if: ${{ github.ref == 'refs/heads/other' }}\n    runs-on:"
        )
        original = model.units("lgtm-hq/alpha", False, files)[0]
        changed = model.units("lgtm-hq/beta", False, {".github/workflows/ci.yml": altered})[0]
        self.assertNotEqual(original.fingerprint, changed.fingerprint)

    def test_order_matters(self):
        source = self.repositories[0]["files"][".github/workflows/ci.yml"]
        data = yaml.safe_load(source)
        data["jobs"]["publish"]["steps"].reverse()
        changed = model.units(
            "lgtm-hq/alpha", False, {".github/workflows/ci.yml": yaml.safe_dump(data)}
        )[0]
        original = next(unit for unit in self.units if unit.job == "publish")
        self.assertNotEqual(original.fingerprint, changed.fingerprint)

    def test_comments_and_quotes(self):
        self.assertEqual(model.normalize('echo "# keep" # drop', "org/repo"), 'echo "# keep"')
        self.assertNotEqual(
            model.normalize('sh -c "rm -rf ./build"', "org/repo"),
            model.normalize('sh -c "mkdir ./build"', "org/repo"),
        )
        self.assertNotEqual(
            model.normalize("${{ inputs.ready && 'build' || 'skip' }}", "org/repo"),
            model.normalize("${{ inputs.ready && 'publish' || 'skip' }}", "org/repo"),
        )

    def test_called_scripts_are_logic(self):
        source = "jobs:\n  check:\n    steps:\n      - run: bash scripts/check.sh\n"
        left = model.units(
            "org/left",
            False,
            {".github/workflows/ci.yml": source, "scripts/check.sh": "terraform validate"},
        )[0]
        right = model.units(
            "org/right",
            False,
            {".github/workflows/ci.yml": source, "scripts/check.sh": "bats tests"},
        )[0]
        self.assertNotEqual(left.fingerprint, right.fingerprint)
        self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_python_indentation_and_shell_boundaries(self):
        left = "if ready:\n    build()\n    publish()\n"
        right = "if ready:\n    build()\npublish()\n"
        self.assertNotEqual(
            model.script_shape("scripts/check.py", left, "org/repo", {}),
            model.script_shape("scripts/check.py", right, "org/repo", {}),
        )
        self.assertNotEqual(
            model.normalize("echo one\necho two", "org/repo"),
            model.normalize("echo one echo two", "org/repo"),
        )
        self.assertEqual(
            model.normalize("// comment\nconsole.log(1)", "org/repo"), "console.log(1)"
        )

    def test_private_parse_error_redaction(self):
        with self.assertRaises(ValueError) as error:
            model.script_shape(
                "scripts/private.py",
                "if ready:\n    build()\n  SECRET_SOURCE_CANARY()\n",
                "org/private",
                {},
            )
        self.assertNotIn("SECRET_SOURCE_CANARY", str(error.exception))
        self.assertIn("scripts/private.py", str(error.exception))

    def test_composite_matches_job(self):
        action = model.units(
            scan.TARGET,
            False,
            {
                ".github/actions/example/action.yml": (
                    "runs:\n  using: composite\n  steps:\n"
                    "    - run: echo hello\n      shell: bash\n"
                )
            },
            "example",
        )[0]
        job = model.units(
            "org/repo",
            False,
            {
                ".github/workflows/ci.yml": (
                    "jobs:\n  example:\n    steps:\n      - run: echo hello\n"
                )
            },
        )[0]
        self.assertEqual(len(model.clusters([job], [action], 0.8)), 1)

    def test_allowlist(self):
        rows = model.load_exceptions(FIXTURES / "local-exceptions.yml")
        excluded = [unit for unit in self.units if model.excepted(unit, rows)]
        self.assertEqual([unit.job for unit in excluded], ["ship"])
        filtered = [
            unit for unit in self.units if not model.excepted(unit, rows) and not unit.private
        ]
        self.assertFalse(
            any(group[0][0].kind == "steps" for group in model.clusters(filtered, [], 0.8))
        )
        rows[0].pop("job")
        self.assertTrue(model.excepted(excluded[0], rows))

    def test_allowlist_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "exceptions.yml"
            with self.assertRaisesRegex(ValueError, "prerequisite #1236"):
                model.load_exceptions(path)
            path.write_text("exceptions: [{}]\n")
            with self.assertRaises(ValueError):
                model.load_exceptions(path)

    def test_catalog_match(self):
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
                "runs:\n  using: composite\n  steps:\n    - run: echo hello\n      shell: bash\n"
            )
            self.assertEqual(scan.references(root)[0].reference, "publish")

    def test_adopted_calls_skipped(self):
        source = (
            "jobs:\n  test:\n    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test.yml@abc\n"
        )
        self.assertEqual(model.units("org/repo", False, {".github/workflows/ci.yml": source}), [])
        source = (
            "jobs:\n  test:\n    steps:\n"
            "      - uses: step-security/harden-runner@abc\n"
            "      - uses: lgtm-hq/lgtm-ci/.github/actions/run-bats@def\n"
            "        with:\n          script: scripts/product.sh\n"
        )
        self.assertEqual(model.units("org/repo", False, {".github/workflows/ci.yml": source}), [])

    def test_private_redaction(self):
        for _, title, body in self.findings:
            for canary in ("SECRET_SOURCE_CANARY", "SECRET_INPUT_CANARY", "SECRET_JOB_CANARY"):
                self.assertNotIn(canary, title + body)
        private = next(unit for unit in self.units if unit.private)
        reference = copy.copy(private)
        title, body = model.render(([private], [reference], 1.0), 0.8)
        self.assertNotIn("SECRET_", title + body)
        self.assertNotIn("```", body)

    def test_stable_membership_and_updates(self):
        group = next(group for group in self.groups if group[0][0].kind == "steps")
        old_members = group[0][:-1]
        old_title, old_body = model.render((old_members, [], 1.0), 0.8)
        api = FakeGitHub([{"number": 9, "state": "open", "title": old_title, "body": old_body}])
        fingerprint = group[0][0].fingerprint
        title, body = model.render(group, 0.8)
        counts = scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(counts["updated"], 1)
        self.assertEqual(counts["created"], 0)
        self.assertEqual(len(api.issues), 1)

    def test_rerun_deduplication(self):
        api = FakeGitHub()
        first = scan.reconcile(api, self.findings, dry_run=False, cap=5)
        self.assertEqual(first["created"], 2)
        api.writes.clear()
        second = scan.reconcile(api, self.findings, dry_run=False, cap=5)
        self.assertEqual(second["unchanged"], 2)
        self.assertEqual(api.writes, [])

    def test_not_planned_silent(self):
        fingerprint, title, body = self.findings[0]
        api = FakeGitHub(
            [{"number": 1, "state": "closed", "state_reason": "not_planned", "body": body}]
        )
        counts = scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(counts["suppressed"], 1)
        self.assertEqual(api.writes, [])

    def test_completed_reopens(self):
        fingerprint, title, body = self.findings[0]
        api = FakeGitHub(
            [{"number": 1, "state": "closed", "state_reason": "completed", "body": body}]
        )
        counts = scan.reconcile(api, [(fingerprint, title, body)], dry_run=False, cap=5)
        self.assertEqual(counts["reopened"], 1)
        self.assertEqual(api.issues[0]["state"], "open")
        self.assertEqual(len(api.writes), 2)
        self.assertTrue(api.writes[-1][0].endswith("/comments"))

    def test_cap_and_dry_run(self):
        findings = [
            (f"{i:024x}", "candidate", f"<!-- lgtm-ci:dup-scan:{i:024x} -->") for i in range(8)
        ]
        api = FakeGitHub()
        counts = scan.reconcile(api, findings, dry_run=True, cap=5)
        self.assertEqual((counts["created"], counts["deferred"]), (5, 3))
        self.assertEqual(api.writes, [])
        counts = scan.reconcile(api, findings, dry_run=False, cap=5)
        self.assertEqual((len(api.writes), counts["deferred"]), (5, 3))

    def test_transport_and_pagination(self):
        with (
            patch.dict(
                os.environ, {"GH_READ_TOKEN": "read", "GH_TOKEN": "write", "GITHUB_TOKEN": "other"}
            ),
            patch.object(scan.subprocess, "run") as run,
        ):
            run.return_value.returncode = 0
            run.return_value.stdout = '[{"number":1}]\n[{"number":2}]'
            self.assertEqual(len(scan.GitHub().api("repos/org/repo/issues?state=all")), 2)
            self.assertEqual(run.call_args.kwargs["env"]["GH_TOKEN"], "read")
            self.assertNotIn("GITHUB_TOKEN", run.call_args.kwargs["env"])
            run.return_value.stdout = "{}"
            scan.GitHub().api(
                "repos/org/repo/issues/1", read=False, payload={"_method": "PATCH", "body": "ok"}
            )
            self.assertEqual(run.call_args.kwargs["env"]["GH_TOKEN"], "write")
            self.assertIn("PATCH", run.call_args.args[0])
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"body": "ok"})

    def test_truncated_tree_fails(self):
        with patch.object(scan.GitHub, "api", return_value={"truncated": True}):
            with self.assertRaisesRegex(RuntimeError, "truncated"):
                scan.GitHub().files({"full_name": "org/repo", "default_branch": "main"})

    def test_workflow_contract(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/duplication-scan.yml").read_text())
        self.assertEqual(workflow["permissions"], {})
        self.assertEqual(workflow["concurrency"]["group"], "duplication-scan")
        job = workflow["jobs"]["duplication-scan"]
        self.assertEqual(job["runs-on"], "ubuntu-26.04")
        self.assertEqual(job["permissions"], {"contents": "read", "issues": "write"})
        self.assertIn("step-security/harden-runner@", job["steps"][0]["uses"])
        presets = json.loads(workflow["env"]["LGTM_CI_EGRESS_PRESETS"])
        self.assertEqual(
            set(presets["duplication-scan"].split()), {"github.com:443", "api.github.com:443"}
        )
        for step in job["steps"]:
            if "uses" in step:
                self.assertIsNotNone(re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", step["uses"]))
            if "run" in step:
                self.assertNotIn("\n", step["run"])
        app = next(step for step in job["steps"] if step.get("id") == "read-token")
        self.assertEqual(app["with"]["owner"], "lgtm-hq")
        self.assertEqual(app["with"]["permission-contents"], "read")
        self.assertIn("DUPLICATION_SCAN_LIVE_ENABLED", job["steps"][-1]["env"]["SCAN_DRY_RUN"])
        self.assertTrue(workflow["on"]["workflow_dispatch"]["inputs"]["dry-run"]["default"])

    def test_rollout_gate_behavior(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/duplication-scan.yml").read_text())
        expression = workflow["jobs"]["duplication-scan"]["steps"][-1]["env"]["SCAN_DRY_RUN"]
        for enabled, event, requested, expected in [
            ("", "schedule", False, True),
            ("", "workflow_dispatch", False, True),
            ("true", "schedule", False, False),
            ("true", "workflow_dispatch", True, True),
            ("true", "workflow_dispatch", False, False),
        ]:
            self.assertEqual(
                evaluate(
                    expression,
                    {
                        "vars.DUPLICATION_SCAN_LIVE_ENABLED": enabled,
                        "github.event_name": event,
                        "inputs.dry-run": requested,
                    },
                    is_condition=False,
                ),
                expected,
            )

    def test_end_to_end_dry_run(self):
        repos = [{**repo, "archived": False} for repo in self.repositories]
        repos += [
            {"full_name": scan.TARGET, "archived": False},
            {"full_name": "org/archived", "archived": True},
        ]
        api = FakeGitHub()
        read = api.api
        api.api = lambda endpoint, **kwargs: (
            repos if endpoint.startswith("orgs/") else read(endpoint, **kwargs)
        )
        api.files = lambda repo: repo["files"]
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.md"
            summary = Path(directory) / "summary.md"
            argv = [
                "scan",
                "--dry-run=true",
                "--exceptions",
                str(FIXTURES / "local-exceptions.yml"),
                "--report",
                str(report),
            ]
            with (
                patch.object(sys, "argv", argv),
                patch.object(scan, "GitHub", return_value=api),
                patch.object(scan, "references", return_value=[]),
                patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}),
                redirect_stdout(output),
            ):
                self.assertEqual(scan.main(), 0)
            self.assertEqual(report.read_text(), summary.read_text())
            self.assertIn("Scanned 3 repositories", report.read_text())
            self.assertNotIn("SECRET_", report.read_text())
            self.assertEqual(api.writes, [])


if __name__ == "__main__":
    unittest.main()
