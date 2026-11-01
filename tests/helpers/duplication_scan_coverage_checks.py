# SPDX-License-Identifier: MIT
"""Stateful, offline source-credential coverage regressions driven by BATS."""

from __future__ import annotations

import copy
import io
import json
import os
import subprocess
import sys
import unittest
from collections.abc import Callable
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass
from dataclasses import field as data_field
from typing import Any
from unittest.mock import patch

from duplication_scan_support import FIXTURES, FakeGitHub, FixtureCase, model, scan


@dataclass
class CoverageResponses:
    """Independent source grants, full grants and App metadata response state."""

    org_pages: list[Any]
    installation_pages: list[Any]
    full_pages: list[Any]
    installation: Any
    grant: Any
    raw: dict[str, str] = data_field(default_factory=dict)


# Keep independent transport fault controls explicit in this offline test fake.
class Transport:  # pylint: disable=too-many-instance-attributes
    """Exercise real gh parsing, source reads and persistent issue mutations."""

    def __init__(self) -> None:
        self.repos: list[dict[str, Any]] = [
            {
                "id": index,
                "full_name": f"lgtm-hq/{name}",
                "owner": {"id": 42, "login": "lgtm-hq", "type": "Organization"},
                "private": False,
                "visibility": "public",
                "archived": False,
                "default_branch": "main",
            }
            for index, name in enumerate(("alpha", "beta", "gamma"), start=1)
        ]
        self.responses = CoverageResponses(
            org_pages=[copy.deepcopy(self.repos)],
            installation_pages=[self.page(self.repos)],
            full_pages=[self.page(self.repos)],
            installation={
                "id": 123,
                "account": copy.deepcopy(self.repos[0]["owner"]),
                "repository_selection": "all",
                "permissions": {"contents": "read", "metadata": "read"},
            },
            grant={
                "token": "full-canary",
                "repository_selection": "all",
                "permissions": {"contents": "read", "metadata": "read"},
            },
        )
        self.unreadable = ""
        self.unreadable_metadata = False
        self.metadata = {repo["full_name"]: copy.deepcopy(repo) for repo in self.repos}
        self.source_prefix: dict[str, str] = {}
        self.source_calls: list[str] = []
        self.rotate_token = False
        self.issues = FakeGitHub()

    @staticmethod
    def page(repos: list[dict[str, Any]], total: int | None = None) -> dict[str, Any]:
        """Return the actual installation-repositories response envelope."""
        return {
            "total_count": len(repos) if total is None else total,
            "repositories": copy.deepcopy(repos),
        }

    def check_credentials(self, args: list[str], env: dict[str, str]) -> str:
        """Check App, source and issue credentials separately on every request."""
        assert args[:2] == ["gh", "api"]
        endpoint = args[2]
        token = env["GH_TOKEN"]
        source = "/issues" not in endpoint
        app = endpoint == "orgs/lgtm-hq/installation" or endpoint.startswith("app/")
        if app:
            assert args[3:5] == ["--header", "Authorization: Bearer " + token]
            assert token not in ("source-canary", "full-canary", "write-canary")
        else:
            expected = {"source-canary", "full-canary"} if source else {"write-canary"}
            assert token in expected
        if source:
            assert "GITHUB_TOKEN" not in env
            self.source_calls.append(endpoint)
        return token

    def __call__(
        self,
        args: list[str],
        **kwargs: Any,
    ) -> subprocess.CompletedProcess[Any]:
        """Route subprocess calls without network, signing or live writes."""
        if args[0] == "openssl":
            return subprocess.CompletedProcess(args, 0, b"signature", b"")
        endpoint = args[2]
        token = self.check_credentials(args, kwargs["env"])
        metadata_request = endpoint.removeprefix("repos/") in self.metadata
        if (endpoint.startswith(self.unreadable) and self.unreadable) or (
            self.unreadable_metadata and metadata_request
        ):
            return subprocess.CompletedProcess(
                args,
                1,
                "",
                "PRIVATE_AUTH_CANARY (HTTP 403)",
            )
        if endpoint == "orgs/lgtm-hq/installation":
            result = [self.responses.installation]
        elif endpoint == "app/installations/123/access_tokens":
            assert args[5:] == ["--method", "POST", "--input", "-"]
            assert json.loads(kwargs["input"]) == {"permissions": {"contents": "read"}}
            result = [self.responses.grant]
        elif endpoint.startswith("installation/repositories"):
            assert "--paginate" in args
            result = (
                self.responses.full_pages
                if token == "full-canary"
                else self.responses.installation_pages
            )
            if self.rotate_token:
                os.environ["GH_READ_TOKEN"] = "different-source-canary"
        elif endpoint.startswith("orgs/lgtm-hq/repos"):
            assert "--paginate" in args
            result = self.responses.org_pages
        elif "git/trees" in endpoint:
            result = [
                {
                    "tree": [
                        {
                            "type": "blob",
                            "path": f"scripts/{name}.sh",
                            "sha": f"{index:040x}",
                        }
                        for index, name in enumerate(("check", "other", "new"), start=1)
                    ]
                }
            ]
        elif endpoint == "graphql":
            query = json.loads(kwargs["input"])["query"]
            repository = query.split('name: "', 1)[1].split('"', 1)[0]
            prefix = self.source_prefix.get(repository, "echo ")
            result = [
                {
                    "data": {
                        "repository": {
                            f"f{index}": {"text": prefix + name, "isBinary": False}
                            for index, name in enumerate(("check", "new", "other"))
                        }
                    }
                }
            ]
        elif endpoint in {f"repos/{name}" for name in self.metadata}:
            result = [self.metadata[endpoint.removeprefix("repos/")]]
        else:
            payload = json.loads(kwargs["input"]) if kwargs.get("input") else None
            if payload is not None:
                payload["_method"] = args[args.index("--method") + 1]
            result = [
                self.issues.api(
                    endpoint,
                    payload=payload,
                    read=payload is None,
                    source=False,
                )
            ]
        matching = (v for k, v in self.responses.raw.items() if endpoint.startswith(k))
        raw = next(matching, None)
        stdout = "\n".join(json.dumps(page) for page in result) if raw is None else raw
        return subprocess.CompletedProcess(args, 0, stdout, "")


class Cases(FixtureCase):
    """Bind reconciliation to coverage proven by the source credential itself."""

    @staticmethod
    def initial_inventory_history(transport: Transport) -> None:
        """Seed formerly public examples across open and both closed decisions."""
        issues = []
        for number, state, reason in (
            (1, "open", None),
            (2, "closed", "completed"),
            (3, "closed", "not_planned"),
        ):
            members = [
                model.Unit(
                    f"lgtm-hq/{name}",
                    "scripts/check.sh",
                    "PRIVATE_JOB_CANARY",
                    False,
                    "steps",
                    (f"old-{number}",),
                    "echo PRIVATE_SOURCE_CANARY",
                    ("PRIVATE_INPUT_CANARY",),
                )
                for name in ("alpha", "gamma")
            ]
            title, body = model.render((members, [], 1.0), 0.8)
            issues.append(
                {
                    "number": number,
                    "state": state,
                    "state_reason": reason,
                    "title": title,
                    "body": body + "\nOwner notes.\n",
                }
            )
        transport.issues = FakeGitHub(issues)

    def test_initial_inventory_privacy_cleanup(self) -> None:
        """Real initial transport and malformed JSON inventories redact only bodies."""
        for failure in ("transport", "object", "null", "mixed", "raw"):
            for dry_run in (False, True):
                with self.subTest(failure=failure, dry_run=dry_run):
                    transport = Transport()
                    self.initial_inventory_history(transport)
                    original = copy.deepcopy(transport.issues.issues)
                    self.assertTrue(
                        all("PRIVATE_SOURCE_CANARY" in i["body"] for i in original),
                    )
                    self.assertTrue(
                        all("PRIVATE_INPUT_CANARY" in i["body"] for i in original),
                    )
                    if failure == "transport":
                        transport.unreadable = "orgs/lgtm-hq/repos"
                    elif failure == "raw":
                        transport.responses.raw["orgs/lgtm-hq/repos"] = "{"
                    else:
                        malformed: dict[str, Any] = {
                            "object": {},
                            "null": None,
                            "mixed": [transport.repos[0], None],
                        }
                        transport.responses.org_pages = [malformed[failure]]
                    with patch.object(
                        scan,
                        "reconcile",
                        side_effect=AssertionError("ordinary reconciliation"),
                    ):
                        status, output, error = self.invoke(transport, dry_run)
                    self.assertIsNone(status)
                    self.assertIsNotNone(error)
                    self.assertNotIn("PRIVATE_", output)
                    if failure == "transport":
                        self.assertIsInstance(error, scan.GitHubError)
                        self.assertEqual(getattr(error, "status", None), 403)
                    elif failure == "raw":
                        self.assertIsInstance(error, ValueError)
                    else:
                        self.assertEqual(
                            str(error),
                            "invalid organization repository inventory",
                        )
                    self.assertEqual(
                        transport.source_calls,
                        ["orgs/lgtm-hq/repos?type=all&per_page=100"],
                    )
                    self.assertEqual(
                        transport.issues.reads,
                        [
                            (
                                "repos/lgtm-hq/lgtm-ci/issues?state=all&per_page=100",
                                False,
                            ),
                        ],
                    )
                    self.assertEqual(len(transport.issues.writes), 0 if dry_run else 3)
                    for endpoint, payload in transport.issues.writes:
                        self.assertRegex(
                            endpoint,
                            r"^repos/lgtm-hq/lgtm-ci/issues/[123]$",
                        )
                        self.assertEqual(set(payload), {"_method", "body"})
                        self.assertEqual(payload["_method"], "PATCH")
                        self.assertNotIn("PRIVATE_", payload["body"])
                        self.assertIn("Owner notes.", payload["body"])
                        for name in ("alpha", "gamma"):
                            self.assertIn(
                                f"- `lgtm-hq/{name}`: `scripts/check.sh`",
                                payload["body"],
                            )
                    if dry_run:
                        self.assertEqual(transport.issues.issues, original)
                    for before, after in zip(
                        original,
                        transport.issues.issues,
                        strict=True,
                    ):
                        self.assertEqual(
                            {**before, "body": ""},
                            {**after, "body": ""},
                        )
                    writes = copy.deepcopy(transport.issues.writes)
                    self.assertIsNotNone(self.invoke(transport, dry_run)[2])
                    self.assertEqual(transport.issues.writes, writes)

    def test_initial_inventory_cleanup_failure(self) -> None:
        """Issue-read or redaction-write failures must preserve the initial cause."""
        for initial in ("transport", "malformed"):
            for cleanup in ("read", "write", "malformed"):
                with self.subTest(initial=initial, cleanup=cleanup):
                    transport = Transport()
                    self.initial_inventory_history(transport)
                    if initial == "malformed":
                        transport.responses.org_pages = [None]
                    if cleanup == "malformed":
                        endpoint = "repos/lgtm-hq/lgtm-ci/issues"
                        transport.responses.raw[endpoint] = '["invalid issue"]'

                    def failing(
                        args: list[str],
                        *,
                        initial: str = initial,
                        cleanup: str = cleanup,
                        transport: Transport = transport,
                        **kwargs: Any,
                    ) -> subprocess.CompletedProcess[Any]:
                        endpoint = args[2]
                        initial_request = endpoint.startswith("orgs/lgtm-hq/repos")
                        if initial == "transport" and initial_request:
                            raise OSError("initial inventory unavailable")
                        failing_operation = cleanup == "read" or "--method" in args
                        if "/issues" in endpoint and failing_operation:
                            return subprocess.CompletedProcess(
                                args,
                                1,
                                "",
                                "cleanup unavailable (HTTP 503)",
                            )
                        return transport(args, **kwargs)

                    stderr = io.StringIO()
                    with redirect_stderr(stderr):
                        _, _, error = self.invoke(failing)
                    expected = (
                        "initial inventory unavailable"
                        if initial == "transport"
                        else "invalid organization repository inventory"
                    )
                    self.assertEqual(str(error), expected)
                    self.assertIsInstance(
                        error,
                        OSError if initial == "transport" else RuntimeError,
                    )
                    self.assertEqual(transport.issues.writes, [])
                    self.assertIn(
                        "historical privacy cleanup failed",
                        stderr.getvalue(),
                    )

    def test_initial_inventory_success_controls(self) -> None:
        """Valid inventory permits normal work; dry runs and reruns never write."""
        for dry_run in (False, True):
            transport = Transport()
            status, output, error = self.invoke(transport, dry_run)
            self.assertIsNone(error)
            self.assertEqual(status, 0)
            self.assertIn("Scanned 3 repositories", output)
            self.assertEqual(len(transport.issues.writes), 0 if dry_run else 3)
            transport.issues.writes.clear()
            self.assertEqual(self.invoke(transport, dry_run)[0], 0)
            self.assertEqual(transport.issues.writes, [])

    def test_visibility_coverage_snapshots(self) -> None:
        """Every real API inventory must agree on well-formed visibility."""
        for snapshot in ("org_pages", "installation_pages", "full_pages"):
            for field, value in (
                ("private", True),
                ("private", None),
                ("private", 0),
                ("visibility", "private"),
                ("visibility", None),
                ("visibility", "PRIVATE_VISIBILITY_CANARY"),
            ):
                with self.subTest(snapshot=snapshot, field=field, value=value):
                    transport = Transport()
                    page = getattr(transport.responses, snapshot)[0]
                    repos = page if snapshot == "org_pages" else page["repositories"]
                    repos[0][field] = value
                    if field == "private" and value is True:
                        repos[0]["visibility"] = "private"
                    self.assert_blocked(transport)
        transport = Transport()
        for snapshot in ("installation_pages", "full_pages"):
            getattr(transport.responses, snapshot)[0]["repositories"][0].update(
                private=True, visibility="private"
            )
        self.assert_blocked(transport)
        # Consistent private snapshots retain complete source coverage.
        transport = Transport()
        for repo in transport.repos:
            repo.update(private=True, visibility="private")
        transport.responses.org_pages = [copy.deepcopy(transport.repos)]
        transport.responses.installation_pages = [transport.page(transport.repos)]
        transport.responses.full_pages = [transport.page(transport.repos)]
        status, output, error = self.invoke(transport)
        self.assertIsNone(error)
        self.assertEqual(status, 0)
        self.assertIn("Private repositories: 3", output)
        self.assertNotIn("Public example from", output)

    def test_publication_visibility_recheck(self) -> None:
        """Late private, malformed and unreadable origins never reach publication."""
        for visibility in ("private", "malformed", "unreadable", "missing", "mixed"):
            for dry_run in (False, True):
                with self.subTest(visibility=visibility, dry_run=dry_run):
                    transport = Transport()
                    for repo in transport.repos:
                        transport.source_prefix[repo["full_name"].split("/")[1]] = (
                            "echo /PRIVATE_SOURCE_CANARY/"
                        )
                        metadata = transport.metadata[repo["full_name"]]
                        if visibility in ("private", "mixed"):
                            metadata.update(private=True, visibility="private")
                        elif visibility == "malformed":
                            metadata["visibility"] = "PRIVATE_VISIBILITY_CANARY"
                        elif visibility == "missing":
                            del metadata["private"]
                    if visibility == "unreadable":
                        transport.unreadable_metadata = True
                    if visibility == "mixed":
                        transport.metadata["lgtm-hq/gamma"].update(
                            private=False, visibility="public"
                        )
                        transport.source_prefix["gamma"] = "echo /public-safe/"
                    status, output, error = self.invoke(transport, dry_run)
                    self.assertIsNone(error)
                    self.assertEqual(status, 0)
                    self.assertNotIn("PRIVATE_", output)
                    count = 2 if visibility == "mixed" else 3
                    self.assertIn(f"Private repositories: {count}", output)
                    if visibility == "mixed":
                        self.assertIn("echo /public-safe/", output)
                    self.assertEqual(len(transport.issues.writes), 0 if dry_run else 1)
                    for _, payload in transport.issues.writes:
                        self.assertNotIn("PRIVATE_", json.dumps(payload))
                    calls = transport.source_calls
                    reads = (i for i, call in enumerate(calls) if call == "graphql")
                    self.assertGreater(calls.index("repos/lgtm-hq/alpha"), max(reads))

    def test_failed_scan_visibility_recheck(self) -> None:
        """Failed source reads still recheck stale public history before cleanup."""
        for dry_run in (False, True):
            transport = Transport()
            old = model.Unit(
                "lgtm-hq/gamma",
                "scripts/check.sh",
                "PRIVATE_JOB_CANARY",
                False,
                "steps",
                ("old",),
                "echo PRIVATE_SOURCE_CANARY",
                ("PRIVATE_INPUT_CANARY",),
            )
            title, body = model.render(([old], [], 1.0), 0.8)
            transport.issues = FakeGitHub(
                [
                    {
                        "number": 1,
                        "state": "closed",
                        "state_reason": "not_planned",
                        "title": title,
                        "body": body + "\nMaintainer notes.\n",
                    }
                ]
            )
            transport.metadata[old.repository].update(
                private=True,
                visibility="private",
            )
            transport.unreadable = "graphql"
            _, output, error = self.invoke(transport, dry_run)
            self.assertIsNotNone(error)
            self.assertNotIn("PRIVATE_", output)
            self.assertEqual(len(transport.issues.writes), 0 if dry_run else 1)
            for _, payload in transport.issues.writes:
                self.assertEqual(set(payload), {"_method", "body"})
                self.assertNotIn("PRIVATE_", payload["body"])
                self.assertIn("Maintainer notes.", payload["body"])

    def invoke(
        self,
        transport: Callable[..., subprocess.CompletedProcess[Any]],
        dry_run: bool = False,
        *,
        app_env: dict[str, str] | None = None,
    ) -> tuple[int | None, str, Exception | None]:
        """Run the real CLI twice against retained offline issue state."""
        output = io.StringIO()
        with (
            patch.object(subprocess, "run", side_effect=transport),
            patch.object(scan, "references", return_value=[]),
            patch.object(scan, "load_exceptions", return_value=[]),
            patch.object(sys, "argv", ["scan", f"--dry-run={str(dry_run).lower()}"]),
            patch.dict(
                os.environ,
                {
                    "GH_READ_TOKEN": "source-canary",
                    "GH_TOKEN": "write-canary",
                    "GITHUB_TOKEN": "must-be-discarded",
                    "GITHUB_STEP_SUMMARY": "",
                    # Readiness flags cannot replace independent source-grant proof.
                    "DUPLICATION_SCAN_READY": "true",
                    "DUPLICATION_SCAN_APP_ID": "source-app",
                    "DUPLICATION_SCAN_APP_PRIVATE_KEY": "test-key",
                    **(app_env or {}),
                },
                clear=True,
            ),
            redirect_stdout(output),
        ):
            try:
                status = scan.main()
            except (RuntimeError, ValueError, KeyError, TypeError, OSError) as error:
                self.assertNotIn("PRIVATE_", str(error))
                self.assertNotIn("canary", str(error))
                self.assertNotIn("PRIVATE_", output.getvalue())
                return None, output.getvalue(), error
        self.assertNotIn("PRIVATE_", output.getvalue())
        return status, output.getvalue(), None

    def assert_blocked(self, transport: Transport, dry_run: bool = False) -> None:
        """Coverage gaps fail without creates, state changes or member removal."""
        for _ in range(2):
            status, output, error = self.invoke(transport, dry_run)
            self.assertTrue(error is not None or status == 1, output)
            self.assertEqual(transport.issues.writes, [])

    def test_source_installation_coverage(self) -> None:
        """Complete proof permits idempotent reporting; successful subsets cannot."""
        transport = Transport()
        transport.rotate_token = True
        status, _, error = self.invoke(transport)
        self.assertIsNone(error)
        self.assertEqual(status, 0)
        self.assertEqual(len(transport.issues.writes), 3)
        calls = transport.source_calls
        coverage_calls = [c for c in calls if c.startswith("installation/repositories")]
        self.assertTrue(coverage_calls)
        self.assertEqual(len(coverage_calls), 2)
        transport.issues.writes.clear()
        self.assertEqual(self.invoke(transport)[0], 0)
        self.assertEqual(transport.issues.writes, [])
        # Complete coverage still permits member refresh, reopening and creation.
        body = transport.issues.issues[0]["body"]
        transport.issues.issues[0]["body"] = body.replace(
            model.MEMBERS_END,
            "- `lgtm-hq/old-member`: `scripts/check.sh`\n" + model.MEMBERS_END,
        )
        transport.issues.issues[1].update(state="closed", state_reason="completed")
        transport.issues.issues.pop()
        self.assertEqual(self.invoke(transport)[0], 0)
        self.assertEqual(len(transport.issues.writes), 4)
        transport.issues.writes.clear()
        self.assertEqual(self.invoke(transport)[0], 0)
        self.assertEqual(transport.issues.writes, [])
        for dry_run in (True, False):
            subset = Transport()
            subset.issues = FakeGitHub(transport.issues.issues)
            subset.issues.issues[1].update(state="closed", state_reason="completed")
            subset.issues.issues.pop()
            original = copy.deepcopy(subset.issues.issues)
            subset.responses.org_pages = [subset.repos[:2]]
            subset.responses.installation_pages = [subset.page(subset.repos[:2])]
            self.assert_blocked(subset, dry_run)
            self.assertEqual(subset.issues.issues, original)

    def test_independent_app_coverage(self) -> None:
        """Unknown App ownership, narrowing and invalid token grants block writes."""
        minimal = Transport()
        minimal.responses.grant = {"token": "full-canary", "expires_at": "future"}
        self.assertEqual(self.invoke(minimal)[0], 0)
        for field, value in (
            ("id", True),
            ("id", 0),
            ("account", {"id": True, "login": "lgtm-hq", "type": "Organization"}),
            ("account", {"id": 43, "login": "lgtm-hq", "type": "Organization"}),
            ("account", {"id": 42, "login": "other-org", "type": "Organization"}),
            ("repository_selection", "selected"),
            ("repository_selection", None),
            ("suspended_at", "2026-10-01T00:00:00Z"),
            ("permissions", {"contents": "write"}),
        ):
            with self.subTest(field=field, value=value):
                transport = Transport()
                transport.responses.installation[field] = value
                self.assert_blocked(transport)
        invalid: list[Any] = [None, [], {}]
        for field, value in (
            ("token", None),
            ("token", ""),
            ("token", True),
            ("repository_selection", "selected"),
            ("repository_selection", None),
            ("permissions", {"contents": "read", "issues": "write"}),
            ("permissions", {"metadata": "read"}),
            ("permissions", None),
        ):
            invalid.append({**Transport().responses.grant, field: value})
        for response in invalid:
            with self.subTest(response=response):
                transport = Transport()
                transport.responses.grant = response
                self.assert_blocked(transport)
        for name in ("DUPLICATION_SCAN_APP_ID", "DUPLICATION_SCAN_APP_PRIVATE_KEY"):
            transport = Transport()
            for dry_run in (True, False):
                self.assertIsNotNone(
                    self.invoke(transport, dry_run, app_env={name: ""})[2],
                )
                self.assertEqual(transport.issues.writes, [])

    def test_invalid_coverage_metadata(self) -> None:
        """Unknown grants, owners and unreadable or malformed metadata fail closed."""
        invalid: list[Any] = [
            None,
            [],
            {},
            {"total_count": True, "repositories": []},
            {"total_count": False, "repositories": []},
            {"total_count": -1, "repositories": []},
            {"total_count": 0, "repositories": []},
        ]
        fixture = Transport()
        value: Any
        for field, value in (
            ("total_count", "3"),
            ("total_count", 4),
            ("repositories", None),
        ):
            invalid.append({**fixture.page(fixture.repos), field: value})
        for field, value in (
            ("id", None),
            ("id", True),
            ("id", False),
            ("id", 1.0),
            ("full_name", "other-org/PRIVATE_REPO_CANARY"),
            ("owner", {"id": 42, "login": "other-org", "type": "Organization"}),
            ("owner", {"id": 42, "login": "lgtm-hq", "type": "User"}),
            ("owner", None),
            ("owner", {"id": True, "login": "lgtm-hq", "type": "Organization"}),
            ("private", None),
            ("private", 0),
            ("archived", "false"),
            ("archived", 0),
            ("fork", "false"),
            ("fork", 0),
            ("default_branch", None),
        ):
            repos = copy.deepcopy(fixture.repos)
            repos[0][field] = value
            invalid.append(fixture.page(repos))
        for page in invalid:
            with self.subTest(page=page):
                transport = Transport()
                transport.responses.installation_pages = [page]
                self.assert_blocked(transport)
        invalid_inventories: list[Any] = [None, {}, [None], [{}]]
        for inventory in invalid_inventories:
            transport = Transport()
            transport.responses.org_pages = [inventory]
            self.assert_blocked(transport)
        for endpoint in (
            "installation/repositories",
            "orgs/lgtm-hq/repos",
            "orgs/lgtm-hq/installation",
            "app/installations/123/access_tokens",
        ):
            malformed = (
                "<html>PRIVATE_METADATA_CANARY</html>",
                '{"PRIVATE_METADATA_CANARY":',
                "",
            )
            for raw in malformed:
                with self.subTest(endpoint=endpoint, raw=raw):
                    transport = Transport()
                    transport.responses.raw[endpoint] = raw
                    self.assert_blocked(transport)
            transport = Transport()
            transport.unreadable = endpoint
            self.assert_blocked(transport)

    def test_coverage_pagination(self) -> None:
        """All object/list pages must agree, be unique and exhaust the total."""
        transport = Transport()
        transport.responses.org_pages = [transport.repos[:1], transport.repos[1:]]
        transport.responses.installation_pages = [
            transport.page(transport.repos[:1], 3),
            transport.page(transport.repos[1:], 3),
        ]
        transport.responses.full_pages = copy.deepcopy(
            transport.responses.installation_pages,
        )
        self.assertEqual(self.invoke(transport)[0], 0)
        self.assertEqual(len(transport.issues.writes), 3)
        for reason in (
            "missing-page",
            "duplicate",
            "changed-total",
            "full-grant-subset",
            "full-grant-missing-page",
            "full-grant-duplicate",
            "different-inventory",
            "malformed-tail",
            "org-duplicate",
            "org-malformed-page",
        ):
            with self.subTest(reason=reason):
                broken = Transport()
                broken.responses.installation_pages = [
                    broken.page(broken.repos[:1], 3),
                    broken.page(broken.repos[1:], 3),
                ]
                if reason == "missing-page":
                    broken.responses.installation_pages.pop()
                elif reason == "duplicate":
                    broken.responses.installation_pages[1] = broken.page(
                        broken.repos[:2],
                        3,
                    )
                elif reason == "changed-total":
                    broken.responses.installation_pages[1]["total_count"] = 2
                elif reason == "full-grant-subset":
                    broken.responses.full_pages = [broken.page(broken.repos[:2])]
                elif reason == "full-grant-missing-page":
                    broken.responses.full_pages = [broken.page(broken.repos[:2], 3)]
                elif reason == "full-grant-duplicate":
                    broken.responses.full_pages = [
                        broken.page([*broken.repos, broken.repos[0]]),
                    ]
                elif reason == "different-inventory":
                    broken.responses.org_pages = [broken.repos[:2]]
                elif reason == "org-duplicate":
                    broken.responses.org_pages = [broken.repos, broken.repos[:1]]
                elif reason == "org-malformed-page":
                    broken.responses.org_pages = [broken.repos, {}]
                else:
                    first = json.dumps(broken.responses.installation_pages[0])
                    malformed = first + "\nPRIVATE_TAIL_CANARY"
                    broken.responses.raw["installation/repositories"] = malformed
                self.assert_blocked(broken)

    def test_coverage_privacy_cleanup(self) -> None:
        """On gaps, redact unverifiable history while retaining adoption decisions."""
        for visibility in ("public", "private", "missing", "unverified"):
            for dry_run in (True, False):
                with self.subTest(visibility=visibility, dry_run=dry_run):
                    transport = Transport()
                    old = model.Unit(
                        "lgtm-hq/gamma",
                        "scripts/check.sh",
                        "PRIVATE_JOB_CANARY",
                        False,
                        "steps",
                        ("old",),
                        "echo PRIVATE_SOURCE_CANARY",
                        ("PRIVATE_INPUT_CANARY",),
                    )
                    title, body = model.render(([old], [], 1.0), 0.8)
                    transport.issues = FakeGitHub(
                        [
                            {
                                "number": 1,
                                "state": "closed",
                                "state_reason": "completed",
                                "title": title,
                                "body": body + "\nOwner notes.\n",
                            }
                        ]
                    )
                    if visibility == "missing":
                        transport.responses.org_pages = [transport.repos[:2]]
                    else:
                        transport.responses.org_pages[0][2]["private"] = {
                            "public": False,
                            "private": True,
                            "unverified": None,
                        }[visibility]
                    transport.responses.installation_pages = [
                        transport.page(transport.repos[:2]),
                    ]
                    original = copy.deepcopy(transport.issues.issues)
                    _, output, error = self.invoke(transport, dry_run)
                    self.assertIsNotNone(error)
                    self.assertNotIn("PRIVATE_", output)
                    expected = int(not dry_run and visibility != "public")
                    self.assertEqual(len(transport.issues.writes), expected)
                    for _, payload in transport.issues.writes:
                        self.assertEqual(set(payload), {"_method", "body"})
                        self.assertNotIn("PRIVATE_", payload["body"])
                        self.assertIn("Owner notes.", payload["body"])
                        self.assertIn(
                            "- `lgtm-hq/gamma`: `scripts/check.sh`",
                            payload["body"],
                        )
                    for before, after in zip(
                        original,
                        transport.issues.issues,
                        strict=True,
                    ):
                        self.assertEqual({**before, "body": ""}, {**after, "body": ""})
                    writes = copy.deepcopy(transport.issues.writes)
                    self.assertIsNotNone(self.invoke(transport, dry_run)[2])
                    self.assertEqual(transport.issues.writes, writes)

    def test_live_transport_end_to_end(self) -> None:
        """Live transport end to end."""
        repos = [
            {
                "id": 1,
                "owner": {"id": 42, "login": "lgtm-hq", "type": "Organization"},
                "full_name": "lgtm-hq/left",
                "private": False,
                "archived": False,
                "default_branch": "main",
            },
            {
                "id": 2,
                "owner": {"id": 42, "login": "lgtm-hq", "type": "Organization"},
                "full_name": "lgtm-hq/right",
                "private": False,
                "archived": False,
                "default_branch": "main",
            },
            {
                "id": 3,
                "owner": {"id": 42, "login": "lgtm-hq", "type": "Organization"},
                "full_name": "lgtm-hq/empty",
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
        ) -> subprocess.CompletedProcess[Any]:
            if args[0] == "openssl":
                return subprocess.CompletedProcess(args, 0, b"signature", b"")
            result: Any
            blob: dict[str, Any]
            endpoint = args[2]
            token = kwargs["env"].get("GH_TOKEN")
            if endpoint == "orgs/lgtm-hq/installation":
                result = {
                    "id": 123,
                    "account": repos[0]["owner"],
                    "repository_selection": "all",
                    "permissions": {"contents": "read"},
                }
            elif endpoint == "app/installations/123/access_tokens":
                self.assertEqual(
                    json.loads(kwargs["input"]),
                    {"permissions": {"contents": "read"}},
                )
                result = {
                    "token": "independent-read",
                    "repository_selection": "all",
                    "permissions": {"contents": "read"},
                }
            elif endpoint.startswith("orgs/"):
                self.assertEqual(token, "read")
                result = repos
            elif endpoint.startswith("installation/repositories"):
                self.assertIn(token, ("read", "independent-read"))
                result = {
                    "total_count": 3,
                    "repositories": repos,
                }
            elif endpoint in {f"repos/{repo['full_name']}" for repo in repos}:
                self.assertEqual(token, "read")
                name = endpoint.removeprefix("repos/")
                result = next(repo for repo in repos if repo["full_name"] == name)
            elif "git/trees" in endpoint:
                self.assertEqual(token, "read")
                if "lgtm-hq/empty/" in endpoint:
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
                    "DUPLICATION_SCAN_APP_ID": "app",
                    "DUPLICATION_SCAN_APP_PRIVATE_KEY": "test-key",
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
