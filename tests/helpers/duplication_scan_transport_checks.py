# SPDX-License-Identifier: MIT
"""Offline scanner transport, workflow and CLI cases driven by BATS."""

from __future__ import annotations

import io
import itertools
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from contextlib import redirect_stdout
from pathlib import Path
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_support import FIXTURES, FakeGitHub, FixtureCase, model, scan
from gha_expr import evaluate


class Cases(FixtureCase):
    """Select one transport or workflow scenario by its BATS case name."""

    def test_independent_privacy_cleanup(self) -> None:
        """Historical issues redact private/unverifiable origins without a cluster."""
        for visibility, partial, dry_run, crlf in itertools.product(
            ("private", "missing", "public"),
            (False, True),
            (False, True),
            (False, True),
        ):
            with self.subTest(
                visibility=visibility,
                partial=partial,
                dry_run=dry_run,
                crlf=crlf,
            ):
                self.check_independent_cleanup(visibility, partial, dry_run, crlf)

    # The scenario checks payload privacy, human edits, issue state and idempotence.
    # pylint: disable-next=too-many-locals
    def check_independent_cleanup(
        self, visibility: str, partial: bool, dry_run: bool, crlf: bool
    ) -> None:
        """Check privacy cleanup without introducing cluster membership writes."""
        original = model.Unit(
            "org/previously-public",
            ".github/workflows/ci.yml",
            "PRIVATE_JOB_CANARY",
            False,
            "steps",
            ("old logic",),
            "echo PRIVATE_SOURCE_CANARY",
            ("PRIVATE_INPUT_CANARY",),
        )
        _, body = model.render(([original], [], 1.0), 0.8)
        body = "Owner notes before.\n\n" + body + "\nOwner notes after.\n"
        repos = (
            []
            if visibility == "missing"
            else [
                {
                    "full_name": original.repository,
                    "private": visibility == "private",
                    "archived": False,
                    "files": {"scripts/new.sh": "echo unrelated"},
                }
            ]
        )
        existing = body.replace("\n", "\r\n") if crlf else body
        issues = [
            {
                "number": index + 1,
                "state": state,
                "state_reason": reason,
                "title": "Owner's adoption plan",
                "body": existing,
            }
            for index, (state, reason) in enumerate(
                (
                    ("open", None),
                    ("closed", "completed"),
                    ("closed", "not_planned"),
                )
            )
        ]
        # Neither an incidental marker in a code fence nor
        # a PR body authorizes scanner issue cleanup.
        issues += [
            {"number": 4, "body": "```\n" + existing + "```\n"},
            {"number": 5, "body": existing, "pull_request": {}},
        ]
        api = FakeGitHub(issues, repositories=repos)
        if partial:
            api.skipped["oversized source"] = 1
        argv = ["scan", f"--dry-run={str(dry_run).lower()}"]
        output = io.StringIO()
        with (
            patch.object(sys, "argv", argv),
            patch.object(scan, "GitHub", return_value=api),
            patch.object(scan, "references", return_value=[]),
            patch.object(scan, "load_exceptions", return_value=[]),
            patch.dict(
                os.environ,
                {
                    "GH_TOKEN": "fixture",
                    "GITHUB_STEP_SUMMARY": "",
                },
            ),
            redirect_stdout(output),
        ):
            self.assertEqual(scan.main(), int(partial and not dry_run))
        self.assertNotIn("PRIVATE_", output.getvalue())
        redacted = visibility != "public"
        self.assertIn(
            '"redacted": 3' if redacted else "Issue actions",
            output.getvalue(),
        )
        if dry_run or not redacted:
            self.assertEqual(api.writes, [])
            self.assertEqual(api.issues, issues)
            return
        self.assertEqual(len(api.writes), 3)
        for old, current, (_, payload) in zip(
            issues[:3],
            api.issues[:3],
            api.writes,
            strict=True,
        ):
            self.assertEqual(set(payload), {"_method", "body"})
            self.assertEqual(payload["_method"], "PATCH")
            self.assertEqual({**old, "body": ""}, {**current, "body": ""})
            self.assertNotIn("PRIVATE_", current["body"])
            self.assertEqual(
                scan.membership(current["body"]),
                (f"- `{original.repository}`: `{original.path}`",),
            )
            normalized = current["body"].replace("\r\n", "\n")
            self.assertTrue(normalized.startswith("Owner notes before.\n"))
            self.assertTrue(normalized.endswith("\nOwner notes after.\n"))
        self.assertEqual(api.issues[3:], issues[3:])
        api.writes.clear()
        scan.reconcile(
            api,
            [],
            dry_run=False,
            cap=5,
            public_repositories=set(),
        )
        self.assertEqual(api.writes, [])

    # Exercise the synthetic CLI lifecycle, including duplicate matching issues.
    # pylint: disable-next=too-many-locals,too-many-nested-blocks
    def test_suppressed_source_privacy(self) -> None:
        """Closed/rejected matches redact historical source without adoption writes."""
        for reason in ("not_planned", None):
            for visibility in ("all-private", "new-public", "still-public"):
                for dry_run in (True, False):
                    for crlf in (True, False):
                        with self.subTest(
                            reason=reason,
                            visibility=visibility,
                            dry_run=dry_run,
                            crlf=crlf,
                        ):
                            repos = [
                                {
                                    **repo,
                                    "archived": False,
                                    "private": (
                                        repo["private"]
                                        if visibility == "still-public"
                                        else visibility == "all-private"
                                        or repo["full_name"] != "lgtm-hq/beta"
                                    ),
                                }
                                for repo in self.repositories
                            ]
                            issues: list[dict[str, Any]] = []
                            for _, _, body in self.findings:
                                existing = "Owner triage before.\n\n" + body
                                existing += "\nOwner notes after.\n"
                                if crlf:
                                    existing = existing.replace("\n", "\r\n")
                                # A rejection must also suppress open/completed
                                # duplicates, but privacy cleanup reaches all three.
                                states = ("closed", "open", "closed")
                                reasons = (reason, None, "completed")
                                size = 3 if reason == "not_planned" else 1
                                for state, state_reason in zip(
                                    states[:size], reasons[:size], strict=True
                                ):
                                    issues.append(
                                        {
                                            "number": len(issues) + 1,
                                            "state": state,
                                            "state_reason": state_reason,
                                            "title": "Owner's adoption plan",
                                            "body": existing,
                                        }
                                    )
                            api = FakeGitHub(issues, repositories=repos)
                            argv = [
                                "scan",
                                f"--dry-run={str(dry_run).lower()}",
                                "--exceptions",
                                str(FIXTURES / "local-exceptions.yml"),
                            ]
                            output = io.StringIO()
                            with (
                                patch.object(sys, "argv", argv),
                                patch.object(scan, "GitHub", return_value=api),
                                patch.object(scan, "references", return_value=[]),
                                # Keep both public fixtures available as controls.
                                patch.object(scan, "load_exceptions", return_value=[]),
                                patch.dict(
                                    os.environ,
                                    {
                                        "GH_TOKEN": "synthetic-fixture",
                                        "GITHUB_STEP_SUMMARY": "",
                                    },
                                ),
                                redirect_stdout(output),
                            ):
                                self.assertEqual(scan.main(), 0)
                            self.assertIn('"suppressed": 2', output.getvalue())
                            self.assertNotIn("SECRET_", output.getvalue())
                            self.assertEqual(len(api.issues), len(issues))
                            if dry_run or visibility == "still-public":
                                self.assertEqual(api.writes, [])
                                self.assertEqual(api.issues, issues)
                                continue
                            self.assertEqual(len(api.writes), len(issues))
                            for old, current, (endpoint, payload) in zip(
                                issues, api.issues, api.writes, strict=True
                            ):
                                self.assertEqual(
                                    endpoint,
                                    f"repos/{scan.TARGET}/issues/{old['number']}",
                                )
                                self.assertEqual(set(payload), {"_method", "body"})
                                self.assertEqual(payload["_method"], "PATCH")
                                self.assertEqual(
                                    {**current, "body": ""},
                                    {**old, "body": ""},
                                )
                                body = current["body"].replace("\r\n", "\n")
                                self.assertTrue(
                                    body.startswith("Owner triage before.\n\n"),
                                )
                                self.assertTrue(body.endswith("\nOwner notes after.\n"))
                                self.assertNotIn(
                                    "Public example from `lgtm-hq/alpha`",
                                    body,
                                )
                                self.assertNotIn("dist/alpha", body)
                                self.assertNotIn("/users/alpha/packages", body)
                                if visibility == "all-private":
                                    self.assertNotIn("Public example from", body)
                                    self.assertNotIn("Action input names:", body)
                                else:
                                    self.assertIn(
                                        "Public example from `lgtm-hq/beta`",
                                        body,
                                    )
                            # Recheck using the current generated bodies, rather
                            # than the old public fixture, to verify idempotence.
                            current_units = [
                                unit
                                for repo in repos
                                for unit in model.units(
                                    repo["full_name"], repo["private"], repo["files"]
                                )
                            ]
                            findings = [
                                (group[0][0].fingerprint, *model.render(group, 0.8))
                                for group in model.clusters(current_units, [], 0.8)
                            ]
                            api.writes.clear()
                            counts = scan.reconcile(api, findings, dry_run=False, cap=5)
                            self.assertEqual(counts["suppressed"], 2)
                            self.assertEqual(api.writes, [])

    def test_non_mapping_yaml_roots(self) -> None:
        """Invalid workflow/action roots count as omitted source, never complete."""
        for path in (".github/workflows/ci.yml", ".github/actions/check/action.yml"):
            for source in ("PRIVATE_SCALAR_CANARY", "- PRIVATE_LIST_CANARY", ""):
                with self.subTest(path=path, source=source):
                    with self.assertRaises(ValueError) as error:
                        model.file_units("org/private", True, path, source, {}, "")
                    self.assertNotIn("PRIVATE_", str(error.exception))
                    api = FakeGitHub()
                    found = model.units(
                        "org/private",
                        True,
                        {path: source},  # Invalid source must retain partial coverage.
                        skipped=api.skipped,
                    )
                    self.assertEqual(found, [])
                    self.assertEqual(api.skipped["invalid source"], 1)
                    self.assertTrue(api.partial)
                    counts = scan.reconcile(api, self.findings, dry_run=False, cap=5)
                    self.assertEqual(counts["blocked"], len(self.findings))
                    self.assertEqual(api.writes, [])
                    self.assertEqual(api.reads, [])

    def test_readiness_validates_exceptions(self) -> None:
        """Malformed present prerequisites fail before reporting readiness."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "catalog").mkdir()
            allowlist = root / "catalog/local-exceptions.yml"
            output = root / "output"
            for source in (
                "exceptions: [",
                "",
                "[]",
                "schema-version: 2\nexceptions: []\n",
                "schema-version: 1\nexceptions: [{}]\n",
            ):
                allowlist.write_text(source, encoding="utf-8")
                output.write_text("", encoding="utf-8")
                with (
                    self.subTest(source=source),
                    patch.object(scan, "ROOT", root),
                    patch.dict(
                        os.environ,
                        {
                            "DUPLICATION_SCAN_APP_ID": "app",
                            "DUPLICATION_SCAN_APP_PRIVATE_KEY": "key",
                            "GITHUB_OUTPUT": str(output),
                        },
                        clear=True,
                    ),
                    patch.object(scan, "verify_installation"),
                    redirect_stdout(io.StringIO()) as stdout,
                ):
                    with self.assertRaises((ValueError, yaml.YAMLError)):
                        scan.check_readiness()
                    self.assertNotIn("ready=true", output.read_text())
                    self.assertNotIn("ready=true", stdout.getvalue())

    def test_transport_and_pagination(self) -> None:
        """Transport and pagination."""
        with (
            patch.dict(
                os.environ,
                {"GH_READ_TOKEN": "read", "GH_TOKEN": "write", "GITHUB_TOKEN": "other"},
            ),
            patch.object(subprocess, "run") as run,
        ):
            run.return_value.returncode = 0
            run.return_value.stdout = '[{"number":1}]\n[{"number":2}]'
            self.assertEqual(len(scan.GitHub().api("orgs/org/repos")), 2)
            self.assertEqual(run.call_args.kwargs["env"]["GH_TOKEN"], "read")
            self.assertNotIn("GITHUB_TOKEN", run.call_args.kwargs["env"])
            scan.GitHub().api("repos/org/repo/issues?state=all", source=False)
            self.assertEqual(run.call_args.kwargs["env"]["GH_TOKEN"], "write")
            run.return_value.stdout = "{}"
            scan.GitHub().api(
                "repos/org/repo/issues/1",
                read=False,
                payload={"_method": "PATCH", "body": "ok"},
            )
            self.assertEqual(run.call_args.kwargs["env"]["GH_TOKEN"], "write")
            self.assertIn("PATCH", run.call_args.args[0])
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"body": "ok"})

    def test_graphql_errors_and_missing_repository(self) -> None:
        """Graphql errors and missing repository."""
        with patch.object(subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = '{"errors":[{"message":"redacted"}]}'
            with self.assertRaisesRegex(RuntimeError, "GraphQL returned errors"):
                scan.GitHub().api("graphql", payload={"query": "query {}"})
        tree = {"tree": [{"type": "blob", "path": "scripts/check.sh", "sha": "a" * 40}]}
        with (
            patch.object(
                scan.GitHub,
                "api",
                side_effect=[tree, {"data": {"repository": None}}],
            ),
            self.assertRaisesRegex(RuntimeError, "repository unavailable"),
        ):
            scan.GitHub().files({"full_name": "org/example", "default_branch": "main"})

    def test_files_batches_and_empty_repositories(self) -> None:
        """Files batches and empty repositories."""
        tree = {
            "tree": [
                {"type": "blob", "path": f"scripts/check{i}.sh", "sha": f"{i:040x}"}
                for i in range(51)
            ]
        }
        responses = [
            {
                "data": {
                    "repository": {
                        f"f{i}": {
                            "text": "echo ok",
                            "isBinary": False,
                        }
                        for i in range(size)
                    }
                }
            }
            for size in (50, 1)
        ]
        repo = {"full_name": "org/example", "default_branch": "main", "size": 0}
        with patch.object(scan.GitHub, "api", side_effect=[tree, *responses]) as api:
            self.assertEqual(len(scan.GitHub().files(repo)), 51)
            self.assertEqual(api.call_count, 3)
        with patch.object(scan.GitHub, "api", side_effect=scan.GitHubError(True, 409)):
            self.assertEqual(scan.GitHub().files(repo), {})
            with self.assertRaises(scan.GitHubError):
                scan.GitHub().files({**repo, "size": 1})
        with (
            patch.object(scan.GitHub, "api", side_effect=scan.GitHubError(True, 403)),
            self.assertRaises(scan.GitHubError),
        ):
            scan.GitHub().files(repo)

    def test_partial_scan(self) -> None:
        """Partial scan."""
        skipped: Counter[str] = Counter()
        files = {
            "scripts/good.sh": "echo ok",
            "scripts/bad.py": "  if (",
            ".github/workflows/bad.yml": "jobs: [",
            ".github/workflows/steps.yml": (
                "jobs:\n  check:\n    runs-on: ubuntu-26.04\n" + "    steps: [invalid]"
            ),
            ".github/workflows/with.yml": (
                "".join(
                    (
                        "jobs:\n",
                        "  check:\n",
                        "    runs-on: ubuntu-26.04\n",
                        "    steps:\n",
                        "      - uses: org/action@abc\n",
                        "        with: invalid",
                    )
                )
            ),
            ".github/workflows/env.yml": (
                "jobs:\n  check:\n    env: invalid\n    steps:\n      - run: echo ok"
            ),
        }
        found = model.units("org/example", False, files, skipped=skipped)
        self.assertEqual([unit.path for unit in found], ["scripts/good.sh"])
        self.assertEqual(skipped["invalid source"], 5)
        tree = {
            "tree": [
                {"type": "blob", "path": "scripts/large", "size": scan.MAX_BLOB + 1},
                {"type": "blob", "path": "scripts/data", "sha": "a" * 40},
                {"type": "blob", "path": "scripts/good.sh", "sha": "b" * 40},
            ]
        }
        response = {
            "data": {
                "repository": {
                    "f0": {"isBinary": True, "text": None},
                    "f1": {"isBinary": False, "text": "echo ok"},
                }
            }
        }
        api = scan.GitHub()
        with patch.object(api, "api", side_effect=[tree, response]):
            self.assertEqual(
                api.files({"full_name": "org/example", "default_branch": "main"}),
                {"scripts/good.sh": "echo ok"},
            )
        self.assertEqual(api.skipped, {"oversized source": 1, "binary source": 1})

    # The integration exercises inventory, matching, decisions and mutation guards.
    # pylint: disable-next=too-many-locals
    def test_partial_inventory_blocks_reconciliation(self) -> None:
        """Omitting a known member blocks updates, reopens and creates together."""
        repos: list[dict[str, Any]] = [
            {
                "full_name": f"org/{name}",
                "private": False,
                "archived": False,
                "files": {
                    "scripts/check.sh": "echo check",
                    "scripts/other.sh": "echo other",
                    "scripts/new.sh": "echo new",
                },
            }
            for name in ("alpha", "beta", "missing")
        ]
        known = [
            unit
            for repo in repos
            for unit in model.units(
                repo["full_name"],
                False,
                repo["files"],
            )
        ]
        findings = [
            (group[0][0].fingerprint, *model.render(group, 0.8))
            for group in model.clusters(known, [], 0.8)
        ]
        self.assertEqual(len(findings), 3)
        issues = [
            {
                "number": index + 1,
                "state": state,
                "state_reason": "completed" if state == "closed" else None,
                "title": title,
                "body": body,
            }
            for index, ((_, title, body), state) in enumerate(
                zip(findings, ("open", "closed"), strict=False)
            )
        ]
        for reason in (
            "oversized",
            "binary",
            "invalid",
            "scalar",
            "list",
            "empty",
            "fetch",
        ):
            for dry_run in (True, False):
                with self.subTest(reason=reason, dry_run=dry_run):
                    api = FakeGitHub(issues=issues, repositories=repos)

                    def transport(
                        endpoint: str,
                        *,
                        client: FakeGitHub = api,
                        **kwargs: Any,
                    ) -> Any:
                        if endpoint == "graphql":
                            blob = {"text": None, "isBinary": True}
                            return {"data": {"repository": {"f0": blob}}}
                        return FakeGitHub.api(client, endpoint, **kwargs)

                    def files(
                        repository: dict[str, Any],
                        *,
                        skip_reason: str = reason,
                        client: FakeGitHub = api,
                    ) -> dict[str, str]:
                        if repository["full_name"] != "org/missing":
                            return dict(repository["files"])
                        if skip_reason == "fetch":
                            raise scan.GitHubError(True, 403)
                        if skip_reason == "invalid":
                            return {"scripts/check.py": "if ("}
                        if skip_reason in {"scalar", "list", "empty"}:
                            return {
                                ".github/workflows/ci.yml": {
                                    "scalar": "PRIVATE_SCALAR_CANARY",
                                    "list": "- PRIVATE_LIST_CANARY",
                                    "empty": "",
                                }[skip_reason]
                            }
                        blob: dict[str, Any] = {
                            "path": "scripts/check.sh",
                            "sha": "a" * 40,
                        }
                        if skip_reason == "oversized":
                            blob["size"] = scan.MAX_BLOB + 1
                        return dict(client.read_blobs("org/missing", [blob]))

                    output = io.StringIO()
                    with (
                        patch.object(api, "api", side_effect=transport),
                        patch.object(api, "files", side_effect=files),
                        patch.object(scan, "GitHub", return_value=api),
                        patch.object(scan, "references", return_value=[]),
                        patch.object(scan, "load_exceptions", return_value=[]),
                        patch.object(
                            sys,
                            "argv",
                            [
                                "scan",
                                f"--dry-run={str(dry_run).lower()}",
                            ],
                        ),
                        patch.dict(
                            os.environ,
                            {
                                "GH_TOKEN": "fixture",
                                "GITHUB_STEP_SUMMARY": "",
                            },
                        ),
                        redirect_stdout(output),
                    ):
                        if reason == "fetch":
                            with self.assertRaises(scan.GitHubError):
                                scan.main()
                        else:
                            self.assertEqual(scan.main(), 0 if dry_run else 1)
                            self.assertIn("Partial scan", output.getvalue())
                            self.assertIn("blocked", output.getvalue())
                    self.assertEqual(api.writes, [])
                    self.assertEqual(api.issues, issues)

    def test_truncated_tree_fails(self) -> None:
        """Truncated tree fails."""
        with (
            patch.object(scan.GitHub, "api", return_value={"truncated": True}),
            self.assertRaisesRegex(RuntimeError, "truncated"),
        ):
            scan.GitHub().files({"full_name": "org/repo", "default_branch": "main"})

    def test_workflow_contract(self) -> None:
        """Workflow contract."""
        workflow = yaml.safe_load(
            (scan.ROOT / ".github/workflows/duplication-scan.yml").read_text(),
        )
        self.assertEqual(workflow["permissions"], {})
        self.assertEqual(workflow["concurrency"]["group"], "duplication-scan")
        job = workflow["jobs"]["duplication-scan"]
        self.assertEqual(job["needs"], "prerequisites")
        self.assertEqual(job["if"], "needs.prerequisites.outputs.ready == 'true'")
        prerequisites = workflow["jobs"]["prerequisites"]
        self.assertEqual(prerequisites["permissions"], {"contents": "read"})
        self.assertIn("readiness.outputs.ready", prerequisites["outputs"]["ready"])
        self.assertEqual(job["runs-on"], "ubuntu-26.04")
        self.assertEqual(job["permissions"], {"contents": "read", "issues": "write"})
        self.assertIn("step-security/harden-runner@", job["steps"][0]["uses"])
        presets = json.loads(workflow["env"]["LGTM_CI_EGRESS_PRESETS"])
        self.assertEqual(
            set(presets["duplication-scan"].split()),
            {"github.com:443", "api.github.com:443"},
        )
        for step in [*prerequisites["steps"], *job["steps"]]:
            if "uses" in step:
                self.assertIsNotNone(
                    re.fullmatch(
                        r"[\w.-]+/[\w./-]+@[0-9a-f]{40}",
                        step["uses"],
                    ),
                )
            if "run" in step:
                self.assertNotIn("\n", step["run"])
        app = next(step for step in job["steps"] if step.get("id") == "read-token")
        self.assertEqual(app["with"]["owner"], "lgtm-hq")
        self.assertEqual(app["with"]["permission-contents"], "read")
        self.assertIn(
            "DUPLICATION_SCAN_LIVE_ENABLED",
            job["steps"][-1]["env"]["SCAN_DRY_RUN"],
        )
        self.assertTrue(
            workflow["on"]["workflow_dispatch"]["inputs"]["dry-run"]["default"],
        )

    def test_readiness_skips_missing_setup(self) -> None:
        """Readiness skips missing setup."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "catalog").mkdir()
            output = root / "output"
            allowlist = root / "catalog/local-exceptions.yml"
            for app, key, exists, expected in [
                ("", "", False, False),
                ("app", "key", False, False),
                ("", "key", True, False),
                ("app", "", True, False),
                ("app", "key", True, True),
            ]:
                if exists:
                    allowlist.write_text("schema-version: 1\nexceptions: []\n")
                env = {
                    "GITHUB_OUTPUT": str(output),
                    "DUPLICATION_SCAN_APP_ID": app,
                    "DUPLICATION_SCAN_APP_PRIVATE_KEY": key,
                }
                with (
                    patch.object(scan, "ROOT", root),
                    patch.object(sys, "argv", ["scan", "--check-readiness"]),
                    patch.dict(os.environ, env),
                    patch.object(scan, "verify_installation") as verify,
                    redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(scan.main(), 0)
                    self.assertEqual(verify.called, expected)
                self.assertEqual(
                    output.read_text().splitlines()[-1],
                    f"ready={str(expected).lower()}",
                )

    def test_readiness_requires_all_repositories(self) -> None:
        """Readiness requires all repositories and strictly read-only permissions."""
        read_only = {"contents": "read", "metadata": "read"}
        for selection, permissions, valid in [
            ("all", {"contents": "read"}, True),
            ("all", {**read_only, "issues": "read", "administration": "read"}, True),
            ("selected", read_only, False),
            ("all", {"contents": "write"}, False),
            ("all", {**read_only, "issues": "write"}, False),
            ("all", {**read_only, "administration": "write"}, False),
            ("all", {**read_only, "administration": "admin"}, False),
            ("all", {**read_only, "issues": None}, False),
            ("all", {**read_only, "issues": True}, False),
            ("all", {**read_only, "issues": ["read"]}, False),
            ("all", {**read_only, "issues": {"access": "read"}}, False),
            ("all", {**read_only, "": "read"}, False),
            ("all", {"metadata": "read"}, False),
            ("all", {}, False),
            ("all", None, False),
            ("all", [], False),
            ("all", "read", False),
            ("all", True, False),
        ]:
            with (
                self.subTest(selection=selection, permissions=permissions),
                patch.object(subprocess, "run") as run,
            ):
                run.side_effect = [
                    subprocess.CompletedProcess([], 0, b"signature", b""),
                    subprocess.CompletedProcess(
                        [],
                        0,
                        json.dumps(
                            {
                                "repository_selection": selection,
                                "permissions": permissions,
                            }
                        ),
                        "",
                    ),
                ]
                if valid:
                    scan.verify_installation("app", "test-key")
                else:
                    with self.assertRaises(RuntimeError):
                        scan.verify_installation("app", "test-key")
                self.assertNotIn("GITHUB_TOKEN", run.call_args.kwargs["env"])
                self.assertEqual(
                    run.call_args.args[0][:3],
                    ["gh", "api", "orgs/lgtm-hq/installation"],
                )
                credential = run.call_args.kwargs["env"]["GH_TOKEN"]
                self.assertEqual(
                    run.call_args.args[0][3:],
                    [
                        "--header",
                        "Authorization: Bearer " + credential,
                    ],
                )

    def test_rollout_gate_behavior(self) -> None:
        """Rollout gate behavior."""
        workflow = yaml.safe_load(
            (scan.ROOT / ".github/workflows/duplication-scan.yml").read_text(),
        )
        step = workflow["jobs"]["duplication-scan"]["steps"][-1]
        expression = step["env"]["SCAN_DRY_RUN"]
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

    def test_end_to_end_dry_run(self) -> None:
        """End to end dry run."""
        repos = [{**repo, "archived": False} for repo in self.repositories]
        repos += [
            {"full_name": "org/fork", "archived": False, "fork": True},
            {"full_name": scan.TARGET, "archived": False},
            {"full_name": "org/archived", "archived": True},
            {
                "full_name": "org/" + "HIDDEN_REPO_CANARY".lower(),
                "archived": False,
                "private": True,
                "files": {"scripts/check.sh": "echo unrelated unique logic"},
            },
        ]
        api = FakeGitHub(repositories=repos)
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
            self.assertIn("Scanned 4 repositories", report.read_text())
            self.assertIn("Private repositories: 2", report.read_text())
            self.assertNotIn(repos[-1]["full_name"], report.read_text())
            self.assertNotIn("SECRET_", report.read_text())
            self.assertEqual(api.writes, [])

    def test_live_transport_end_to_end(self) -> None:
        """Live transport end to end."""
        repos = [
            {
                "full_name": "org/left",
                "private": False,
                "archived": False,
                "default_branch": "main",
            },
            {
                "full_name": "org/right",
                "private": False,
                "archived": False,
                "default_branch": "main",
            },
            {
                "full_name": "org/empty",
                "private": False,
                "archived": False,
                "default_branch": "main",
                "size": 0,
            },
        ]
        writes: list[dict[str, Any]] = []

        def transport(
            args: list[str],
            **kwargs: Any,
        ) -> subprocess.CompletedProcess[str]:
            result: Any
            blob: dict[str, Any]
            endpoint = args[2]
            token = kwargs["env"].get("GH_TOKEN")
            if endpoint.startswith("orgs/"):
                self.assertEqual(token, "read")
                result = repos
            elif "git/trees" in endpoint:
                self.assertEqual(token, "read")
                if "org/empty/" in endpoint:
                    return subprocess.CompletedProcess(
                        args, 1, "", "Git Repository is empty (HTTP 409)"
                    )
                blob = {"type": "blob", "path": "scripts/check.sh", "sha": "a" * 40}
                result = {"tree": [blob]}
            elif endpoint == "graphql":
                self.assertEqual(token, "read")
                blob = {"text": "echo copied", "isBinary": False}
                result = {"data": {"repository": {"f0": blob}}}
            elif "state=all" in endpoint:
                self.assertEqual(token, "write")
                result = []
            else:
                self.assertEqual(token, "write")
                writes.append(json.loads(kwargs["input"]))
                result = {}
            return subprocess.CompletedProcess(args, 0, json.dumps(result), "")

        with (
            patch.object(
                sys,
                "argv",
                [
                    "scan",
                    "--dry-run=false",
                    "--exceptions",
                    str(FIXTURES / "local-exceptions.yml"),
                ],
            ),
            patch.dict(
                os.environ,
                {
                    "GH_READ_TOKEN": "read",
                    "GH_TOKEN": "write",
                    "GITHUB_STEP_SUMMARY": "",
                },
            ),
            patch.object(subprocess, "run", side_effect=transport),
            patch.object(scan, "references", return_value=[]),
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(scan.main(), 0)
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0]["labels"], ["ci", "needs-triage"])


if __name__ == "__main__":
    unittest.main()
