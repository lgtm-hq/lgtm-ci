# SPDX-License-Identifier: MIT
"""Scoped reopen-transaction and YAML-context regressions for PR #1244."""

from __future__ import annotations

import copy
import json
import re
import subprocess
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_support import FakeGitHub, FixtureCase, model, scan, syntax

TRANSACTION = "a" * 32
EXPLANATION = (
    "The duplication scanner found this copy again on the default branch; "
    "reopening for adoption triage."
)


def receipt(state: str, transaction: str = TRANSACTION) -> str:
    """Build the bounded issue-body recovery record."""
    return f"<!-- lgtm-ci:dup-reopen:{transaction}:{state} -->"


def explanation(transaction: str = TRANSACTION) -> str:
    """Bind an explanation to this reopen, rather than any prior closure."""
    return EXPLANATION + f"\n\n<!-- lgtm-ci:dup-reopen-comment:{transaction} -->"


def comment(body: Any, *, login: str = "github-actions[bot]") -> dict[str, Any]:
    """Return the REST fields needed to prove scanner-authored delivery."""
    return {"id": 42, "body": body, "user": {"login": login, "type": "Bot"}}


@contextmanager
def comment_transport(
    api: FakeGitHub,
    *,
    lookup: subprocess.CompletedProcess[str] | None = None,
    post_error: BaseException | None = None,
    accept: bool = False,
    post_response: subprocess.CompletedProcess[str] | None = None,
) -> Iterator[None]:
    """Run real gh response parsing; keep issue PATCHes and state offline."""
    request = api.api

    def route(endpoint: str, **kwargs: Any) -> Any:
        if "/comments" not in endpoint:
            return request(endpoint, **kwargs)
        if kwargs.get("read", True):
            if lookup is None:
                return request(endpoint, **kwargs)
            assert kwargs.get("source") is False
            with patch.object(scan.subprocess, "run", return_value=lookup) as run:
                result = scan.GitHub.api(api, endpoint, **kwargs)
            assert "--paginate" in run.call_args.args[0]
            return result
        if post_error is None and post_response is None:
            return request(endpoint, **kwargs)
        if accept:
            request(endpoint, **kwargs)
        response = post_response or subprocess.CompletedProcess([], 1, "", "HTTP 502")
        with patch.object(
            scan.subprocess,
            "run",
            return_value=response,
            side_effect=post_error,
        ):
            return scan.GitHub.api(api, endpoint, **kwargs)

    with patch.object(api, "api", side_effect=route):
        yield


class ReopenCases(FixtureCase):
    """Exercise real comment transport against stateful offline issue PATCHes."""

    def pending(self, state: str | None = None) -> FakeGitHub:
        """Preserve human notes around an otherwise unchanged finding."""
        _, title, body = self.findings[0]
        return FakeGitHub(
            [
                {
                    "number": 1,
                    "title": title,
                    "state": "open" if state else "closed",
                    "state_reason": None if state else "completed",
                    "body": "Owner notes before.\n"
                    + body
                    + "\nOwner notes after.\n"
                    + (receipt(state) + "\n" if state else ""),
                }
            ]
        )

    def reconcile(self, api: FakeGitHub, **kwargs: Any) -> Any:
        """Run one invocation; no live GitHub calls are possible."""
        return scan.reconcile(api, self.findings[:1], cap=5, dry_run=False, **kwargs)

    def test_reopen_pre_send_recovery(self) -> None:
        """A real PATCH success and unstarted POST recover on the next invocation."""
        api = self.pending()
        with (
            comment_transport(api, post_error=FileNotFoundError()),
            self.assertRaises((RuntimeError, OSError)),
        ):
            self.reconcile(api)
        self.assertEqual(api.issues[0]["state"], "open")
        # Reconstruct the process from persistent GitHub state alone.
        next_run = FakeGitHub(api.issues)
        self.reconcile(next_run)
        self.assertEqual(len(next_run.comments.get(1, [])), 1)
        self.assertRegex(api.issues[0]["body"], r"dup-reopen:[a-f0-9]{32}:ready")
        self.assertIn(EXPLANATION, next_run.comments[1][0]["body"])
        self.assertIn(":delivered -->", next_run.issues[0]["body"])
        self.assertIn("Owner notes before.\n", next_run.issues[0]["body"])
        self.assertTrue(next_run.issues[0]["body"].endswith("\nOwner notes after.\n"))
        writes = len(next_run.writes)
        self.reconcile(next_run)
        self.assertEqual(len(next_run.writes), writes)
        self.assertEqual(len(next_run.comments[1]), 1)

    def test_reopen_lost_response_and_interruption(self) -> None:
        """Uncertain delivery is visible and never blindly re-posted."""
        for accepted in (False, True):
            for interrupted in (False, True):
                with self.subTest(accepted=accepted, interrupted=interrupted):
                    api = self.pending()
                    response = subprocess.CompletedProcess([], 1, "", "HTTP 502")
                    with (
                        comment_transport(
                            api,
                            accept=accepted,
                            post_response=response,
                            post_error=KeyboardInterrupt() if interrupted else None,
                        ),
                        self.assertRaises((RuntimeError, KeyboardInterrupt)),
                    ):
                        self.reconcile(api)
                    self.assertEqual(api.issues[0]["state"], "open")
                    self.assertIn(":sending -->", api.issues[0]["body"])
                    next_run = FakeGitHub(api.issues)
                    next_run.comments = copy.deepcopy(api.comments)
                    if accepted:
                        self.reconcile(next_run)
                        self.assertIn(":delivered -->", next_run.issues[0]["body"])
                    else:
                        with self.assertRaisesRegex(RuntimeError, "uncertain"):
                            self.reconcile(next_run)
                        self.assertIn(":sending -->", next_run.issues[0]["body"])
                    self.assertFalse(
                        any(path.endswith("/comments") for path, _ in next_run.writes),
                    )

    def test_reopen_existing_comment_and_pagination(self) -> None:
        """Inspect every comment page and require both author and transaction."""
        for state in ("ready", "sending"):
            api = self.pending(state)
            pages = [
                [
                    comment(explanation("b" * 32)),
                    comment(explanation(), login="other[bot]"),
                ],
                [comment(explanation())],
            ]

            response = subprocess.CompletedProcess(
                [], 0, "\n".join(json.dumps(page) for page in pages), ""
            )
            with comment_transport(api, lookup=response):
                self.reconcile(api)
            self.assertEqual(len(api.writes), 1)
            self.assertIn(":delivered -->", api.issues[0]["body"])

    def test_reopen_unrelated_comments_and_invalid_receipts(self) -> None:
        """Neither another bot nor an old transaction proves this POST delivered."""
        for state in ("ready", "sending"):
            api = self.pending(state)
            api.comments[1] = [
                comment(explanation("b" * 32)),
                comment(explanation(), login="other[bot]"),
                {
                    **comment(explanation()),
                    "user": {
                        "login": "github-actions[bot]",
                        "type": "User",
                    },
                },
            ]
            if state == "ready":
                self.reconcile(api)
                self.assertEqual(len(api.comments[1]), 4)
                self.assertEqual(api.comments[1][-1]["body"], explanation())
            else:
                with self.assertRaisesRegex(RuntimeError, "uncertain"):
                    self.reconcile(api)
                self.assertEqual(len(api.comments[1]), 3)
                self.assertEqual(api.writes, [])
        for output in ("", "{}", "[]", "NOT_JSON", json.dumps(comment("other"))):
            api = self.pending("ready")
            response = subprocess.CompletedProcess([], 0, output, "")
            with (
                comment_transport(api, accept=True, post_response=response),
                self.assertRaises((RuntimeError, ValueError)),
            ):
                self.reconcile(api)
            self.assertIn(":sending -->", api.issues[0]["body"])
            self.reconcile(api)
            self.assertEqual(len(api.comments[1]), 1)

    def test_reopen_comment_lookup_failures(self) -> None:
        """Failed, malformed or mixed pages must never license a POST."""
        bad_pages = [
            "",
            "{}",
            "null",
            "[null]",
            '[{"id": 1}]',
            json.dumps([comment(123)]),
            json.dumps([comment(explanation())]) + "\n{}",
            json.dumps([comment(explanation())]) + "\nNOT_JSON",
        ]
        for output in [*bad_pages, None]:
            for state in ("ready", "sending"):
                with self.subTest(output=output, state=state):
                    api = self.pending(state)
                    original = copy.deepcopy(api.issues)
                    response = subprocess.CompletedProcess(
                        [], 1 if output is None else 0, output or "", "HTTP 503"
                    )
                    with (
                        comment_transport(api, lookup=response),
                        self.assertRaises((RuntimeError, ValueError)),
                    ):
                        self.reconcile(api)
                    self.assertEqual(api.issues, original)
                    self.assertEqual(api.writes, [])

    def test_reopen_receipt_failure_and_new_transaction(self) -> None:
        """An accepted POST survives receipt failure and later reopens get new IDs."""
        api = self.pending("ready")
        request = api.api

        def fail_receipt(endpoint: str, **kwargs: Any) -> Any:
            if ":delivered -->" in kwargs.get("payload", {}).get("body", ""):
                raise scan.GitHubError(False, 500)
            return request(endpoint, **kwargs)

        with (
            patch.object(api, "api", side_effect=fail_receipt),
            self.assertRaises(scan.GitHubError),
        ):
            self.reconcile(api)
        self.assertEqual(len(api.comments[1]), 1)
        self.assertIn(":sending -->", api.issues[0]["body"])
        self.reconcile(api)
        self.assertEqual(len(api.comments[1]), 1)
        api.issues[0].update(state="closed", state_reason="completed")
        self.reconcile(api)
        self.assertEqual(len(api.comments[1]), 2)
        self.assertNotEqual(api.comments[1][0]["body"], api.comments[1][1]["body"])
        records = re.findall(r"dup-reopen:[a-f0-9]{32}:", api.issues[0]["body"])
        self.assertEqual(len(records), 1)

    def test_reopen_policy_and_no_write_controls(self) -> None:
        """Pending explanations respect dry-run, coverage, rejection and privacy."""
        api = self.pending("ready")
        original = copy.deepcopy(api.issues)
        scan.reconcile(api, self.findings[:1], cap=5, dry_run=True)
        self.assertEqual(api.writes, [])
        self.assertEqual(api.issues, original)
        api.skipped["invalid source"] = 1
        counts = self.reconcile(api)
        self.assertEqual(counts["blocked"], 1)
        self.assertEqual(api.writes, [])
        api.skipped.clear()
        for reason in ("not_planned", None):
            api.issues[0].update(state="closed", state_reason=reason)
            self.reconcile(api)
            self.assertEqual(api.writes, [])
        api = self.pending("ready")
        rejected = {
            **api.issues[0],
            "number": 2,
            "state": "closed",
            "state_reason": "not_planned",
        }
        api.issues.append(rejected)
        self.reconcile(api)
        self.assertEqual(api.writes, [])
        api = self.pending()
        api.issues[0].update(state="open", state_reason=None)
        self.reconcile(api)
        self.assertEqual(api.writes, [])
        # Recovery is independent of whether this cluster is found again.
        api = self.pending("ready")
        scan.reconcile(api, [], cap=5, dry_run=False, public_repositories=set())
        self.assertEqual(len(api.comments[1]), 1)
        self.assertNotIn("Public example from", api.issues[0]["body"])
        self.assertIn("Owner notes after.", api.issues[0]["body"])


class ContextCases(unittest.TestCase):
    """Exercise normalized outputs through units, clusters and catalog matching."""

    def unit(
        self,
        repository: str,
        outputs: dict[str, Any],
        *,
        reference: str = "",
    ) -> model.Unit:
        """Parse a complete job through the public unit-building entry point."""
        path = ".github/workflows/ci.yml"
        source = yaml.safe_dump(
            {
                "jobs": {
                    "build": {
                        "runs-on": "ubuntu-26.04",
                        "outputs": outputs,
                        "steps": [{"run": "echo check", "shell": "bash"}],
                    }
                }
            }
        )
        return model.units(repository, False, {path: source}, reference)[0]

    def test_output_name_and_using_negative_pairs(self) -> None:
        """Output names are data, including through nested user mappings."""
        for name in ("name", "using"):
            for nested in (False, True):
                with self.subTest(name=name, nested=nested):

                    first = {name: "${{ steps.build.outputs.first }}"}
                    second = {name: "${{ steps.build.outputs.second }}"}
                    outputs = {"custom": first} if nested else first
                    other = {"custom": second} if nested else second
                    left = self.unit("org/left", outputs)
                    right = self.unit("org/right", other)
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])
                    reference = self.unit(scan.TARGET, outputs, reference="check")
                    self.assertEqual(len(model.clusters([left], [reference], 0.8)), 1)
                    self.assertEqual(model.clusters([right], [reference], 0.8), [])

    def test_output_reserved_keys_are_data(self) -> None:
        """Execution-looking output names cannot invoke execution normalization."""
        outputs = dict.fromkeys(
            ("name", "using", "env", "with", "run", "defaults", "uses", "steps"),
            "${{ steps.build.outputs.first }}",
        )
        left = self.unit("org/left", outputs)
        self.assertEqual(json.loads(left.shape[0])["outputs"], outputs)
        nested = {
            "custom": {key: {"name": "first", "using": "second"} for key in outputs},
        }
        shaped = syntax.operation_shape({"outputs": nested}, "org/left", {})
        self.assertEqual(shaped["outputs"], nested)
        shaped = syntax.operation_shape({"custom": nested}, "org/left", {})
        self.assertEqual(shaped["custom"], nested)
        for key in outputs:
            changed = {**outputs, key: "${{ steps.build.outputs.second }}"}
            self.assertNotEqual(
                left.fingerprint,
                self.unit("org/right", changed).fingerprint,
            )

    def test_execution_display_and_action_positive_controls(self) -> None:
        """Real job/step names and known action parameters retain normalization."""
        path = ".github/workflows/ci.yml"

        def job(label: str, pin: str) -> model.Unit:
            source = yaml.safe_dump(
                {
                    "jobs": {
                        "build": {
                            "name": label,
                            "runs-on": "ubuntu-26.04",
                            "steps": [
                                {
                                    "name": label,
                                    "uses": f"actions/setup-python@{pin}",
                                    "with": {"python-version": label},
                                },
                                {"name": label, "run": "echo check", "shell": "bash"},
                            ],
                        }
                    }
                }
            )
            return model.units(f"org/{label}", False, {path: source})[0]

        left, right = job("first", "abc"), job("second", "def")
        self.assertEqual(left.fingerprint, right.fingerprint)
        self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
        action = ".github/actions/check/action.yml"
        source = yaml.safe_dump(
            {
                "name": "Check",
                "runs": {
                    "using": "composite",
                    "steps": [
                        {"name": "Display", "run": "echo check", "shell": "bash"},
                    ],
                },
            }
        )
        reference = model.units(scan.TARGET, False, {action: source}, "check")[0]
        self.assertEqual(reference.shape[0], "{}")
        self.assertNotIn("name", json.loads(reference.shape[1]))
        # Ordinary image and path parameters retain their existing normalization.
        shapes = [
            syntax.operation_shape(
                {
                    "container": {
                        "image": f"ghcr.io/org/{name}:1",
                        "volumes": [f"/{name}/cache"],
                    }
                },
                f"org/{name}",
                {},
            )
            for name in ("first", "second")
        ]
        self.assertEqual(*shapes)


if __name__ == "__main__":
    unittest.main()
