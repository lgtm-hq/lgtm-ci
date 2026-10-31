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
from contextlib import redirect_stdout
from typing import Any
from unittest.mock import patch

from duplication_scan_support import FakeGitHub, FixtureCase, model, scan


class Transport:
    """Exercise real gh parsing, source reads and persistent issue mutations."""

    def __init__(self) -> None:
        self.repos = [
            {
                "id": index,
                "full_name": f"lgtm-hq/{name}",
                "owner": {"id": 42, "login": "lgtm-hq", "type": "Organization"},
                "private": False,
                "archived": False,
                "default_branch": "main",
            }
            for index, name in enumerate(("alpha", "beta", "gamma"), start=1)
        ]
        self.org_pages: list[Any] = [copy.deepcopy(self.repos)]
        self.installation_pages: list[Any] = [self.page(self.repos)]
        self.raw: dict[str, str] = {}
        self.unreadable = ""
        self.source_calls: list[str] = []
        self.rotate_token = False
        self.issues = FakeGitHub()

    @staticmethod
    def page(repos: list[dict[str, Any]], total: int | None = None) -> dict[str, Any]:
        """Return the actual installation-repositories response envelope."""
        return {
            "total_count": len(repos) if total is None else total,
            "repository_selection": "all",
            "repositories": copy.deepcopy(repos),
        }

    def __call__(
        self,
        args: list[str],
        **kwargs: Any,
    ) -> subprocess.CompletedProcess[str]:
        """Route subprocess calls without network, signing or live writes."""
        assert args[:2] == ["gh", "api"]
        endpoint = args[2]
        source = "/issues" not in endpoint
        expected_token = "source-canary" if source else "write-canary"
        assert kwargs["env"].get("GH_TOKEN") == expected_token
        if source:
            assert "GITHUB_TOKEN" not in kwargs["env"]
            self.source_calls.append(endpoint)
        if endpoint.startswith(self.unreadable) and self.unreadable:
            return subprocess.CompletedProcess(
                args,
                1,
                "",
                "PRIVATE_AUTH_CANARY (HTTP 403)",
            )
        if endpoint.startswith("installation/repositories"):
            assert "--paginate" in args
            result = self.installation_pages
            if self.rotate_token:
                os.environ["GH_READ_TOKEN"] = "different-source-canary"
        elif endpoint.startswith("orgs/lgtm-hq/repos"):
            assert "--paginate" in args
            result = self.org_pages
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
            result = [
                {
                    "data": {
                        "repository": {
                            f"f{index}": {"text": f"echo {name}", "isBinary": False}
                            for index, name in enumerate(("check", "new", "other"))
                        }
                    }
                }
            ]
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
        matching = (v for k, v in self.raw.items() if endpoint.startswith(k))
        raw = next(matching, None)
        stdout = "\n".join(json.dumps(page) for page in result) if raw is None else raw
        return subprocess.CompletedProcess(args, 0, stdout, "")


class Cases(FixtureCase):
    """Bind reconciliation to coverage proven by the source credential itself."""

    def invoke(
        self, transport: Transport, dry_run: bool = False
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
                    # Neither readiness assertions nor another App can prove coverage.
                    "DUPLICATION_SCAN_READY": "true",
                    "DUPLICATION_SCAN_APP_ID": "different-app",
                },
                clear=True,
            ),
            redirect_stdout(output),
        ):
            try:
                status = scan.main()
            except (RuntimeError, ValueError, KeyError, TypeError) as error:
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
            subset.org_pages = [subset.repos[:2]]
            subset.installation_pages = [
                {**subset.page(subset.repos[:2]), "repository_selection": "selected"}
            ]
            self.assert_blocked(subset, dry_run)
            self.assertEqual(subset.issues.issues, original)

    def test_invalid_coverage_metadata(self) -> None:
        """Unknown grants, owners and unreadable or malformed metadata fail closed."""
        invalid: list[Any] = [
            None,
            [],
            {},
            {"repository_selection": "all"},
            {"repository_selection": "all", "total_count": True, "repositories": []},
            {"repository_selection": "all", "total_count": -1, "repositories": []},
            {"repository_selection": "all", "total_count": 0, "repositories": []},
        ]
        fixture = Transport()
        value: Any
        for field, value in (
            ("repository_selection", None),
            ("repository_selection", "selected"),
            ("total_count", "3"),
            ("total_count", 4),
            ("repositories", None),
        ):
            invalid.append({**fixture.page(fixture.repos), field: value})
        for field, value in (
            ("id", None),
            ("id", True),
            ("full_name", "other-org/PRIVATE_REPO_CANARY"),
            ("owner", {"id": 42, "login": "other-org", "type": "Organization"}),
            ("owner", {"id": 42, "login": "lgtm-hq", "type": "User"}),
            ("owner", None),
            ("private", None),
            ("archived", "false"),
            ("fork", "false"),
            ("default_branch", None),
        ):
            repos = copy.deepcopy(fixture.repos)
            repos[0][field] = value
            invalid.append(fixture.page(repos))
        for page in invalid:
            with self.subTest(page=page):
                transport = Transport()
                transport.installation_pages = [page]
                self.assert_blocked(transport)
        invalid_inventories: list[Any] = [None, {}, [None], [{}]]
        for inventory in invalid_inventories:
            transport = Transport()
            transport.org_pages = [inventory]
            self.assert_blocked(transport)
        for endpoint in ("installation/repositories", "orgs/lgtm-hq/repos"):
            malformed = (
                "<html>PRIVATE_METADATA_CANARY</html>",
                '{"PRIVATE_METADATA_CANARY":',
                "",
            )
            for raw in malformed:
                with self.subTest(endpoint=endpoint, raw=raw):
                    transport = Transport()
                    transport.raw[endpoint] = raw
                    self.assert_blocked(transport)
            transport = Transport()
            transport.unreadable = endpoint
            self.assert_blocked(transport)

    def test_coverage_pagination(self) -> None:
        """All object/list pages must agree, be unique and exhaust the total."""
        transport = Transport()
        transport.org_pages = [transport.repos[:1], transport.repos[1:]]
        transport.installation_pages = [
            transport.page(transport.repos[:1], 3),
            transport.page(transport.repos[1:], 3),
        ]
        self.assertEqual(self.invoke(transport)[0], 0)
        self.assertEqual(len(transport.issues.writes), 3)
        for reason in (
            "missing-page",
            "duplicate",
            "changed-total",
            "changed-selection",
            "different-inventory",
            "malformed-tail",
            "org-duplicate",
            "org-malformed-page",
        ):
            with self.subTest(reason=reason):
                broken = Transport()
                broken.installation_pages = [
                    broken.page(broken.repos[:1], 3),
                    broken.page(broken.repos[1:], 3),
                ]
                if reason == "missing-page":
                    broken.installation_pages.pop()
                elif reason == "duplicate":
                    broken.installation_pages[1] = broken.page(broken.repos[:2], 3)
                elif reason == "changed-total":
                    broken.installation_pages[1]["total_count"] = 2
                elif reason == "changed-selection":
                    broken.installation_pages[1]["repository_selection"] = "selected"
                elif reason == "different-inventory":
                    broken.org_pages = [broken.repos[:2]]
                elif reason == "org-duplicate":
                    broken.org_pages = [broken.repos, broken.repos[:1]]
                elif reason == "org-malformed-page":
                    broken.org_pages = [broken.repos, {}]
                else:
                    first = json.dumps(broken.installation_pages[0])
                    malformed = first + "\nPRIVATE_TAIL_CANARY"
                    broken.raw["installation/repositories"] = malformed
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
                        transport.org_pages = [transport.repos[:2]]
                    else:
                        transport.org_pages[0][2]["private"] = {
                            "public": False,
                            "private": True,
                            "unverified": None,
                        }[visibility]
                    transport.installation_pages[0]["repository_selection"] = "selected"
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


if __name__ == "__main__":
    unittest.main()
