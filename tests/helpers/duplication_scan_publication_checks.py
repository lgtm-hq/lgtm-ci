# SPDX-License-Identifier: MIT
"""Publication-time visibility transitions through the real offline CLI transport."""

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

from duplication_scan_coverage_checks import HISTORICAL_ISSUE_STATES, Transport
from duplication_scan_coverage_checks import Cases as CoverageCases
from duplication_scan_support import ROOT, FakeGitHub, model, scan


class PublicationTransport(Transport):
    """Change metadata during historical pagination or after an issue write."""

    def __init__(self, boundary: str, visibility: str = "private") -> None:
        super().__init__()
        self.boundary = boundary
        self.visibility = visibility
        self.changed = False
        self.events: list[str] = []
        self.source_files = {}
        for name in ("alpha", "beta", "gamma"):
            public = name == "gamma"
            job = "public-job" if public else f"LATE_JOB_CANARY_{name}"
            source = "/public-safe/" if public else "/LATE_SOURCE_CANARY/"
            stages = [f"echo stage-{letter}" for letter in "abcdefghijkl"]
            near_source = "\n".join([*stages, f"echo finish-{name}"])
            self.source_files[name] = {
                ".github/workflows/copy.yml": (
                    f"jobs:\n  {job}:\n    runs-on: ubuntu-latest\n    steps:\n"
                    "      - uses: actions/setup-node@v4\n        with:\n"
                    "          node-version: '20'\n"
                    f"      - run: echo {source}\n"
                ),
                "scripts/LATE_NEAR_PATH_CANARY.sh": near_source,
            }

    def change_visibility(self) -> None:
        """Keep source-grant evidence stable; only publication metadata changes."""
        self.changed = True
        for name, metadata in self.metadata.items():
            if self.visibility == "public" or (
                self.visibility == "mixed" and name.endswith("/gamma")
            ):
                continue
            if self.visibility in ("private", "mixed"):
                metadata.update(private=True, visibility="private")
            elif self.visibility == "malformed":
                metadata["visibility"] = "LATE_METADATA_CANARY"
            elif self.visibility == "missing":
                del metadata["private"]
            elif self.visibility == "identity":
                metadata["id"] += 100
            elif self.visibility == "unreadable":
                self.unreadable_metadata = True

    def __call__(
        self,
        args: list[str],
        **kwargs: Any,
    ) -> subprocess.CompletedProcess[Any]:
        response: subprocess.CompletedProcess[Any]
        if args[0] == "openssl":
            response = super().__call__(args, **kwargs)
            return response
        endpoint = args[2]
        self.events.append(endpoint)
        writer_token = kwargs["env"].get("GH_TOKEN")
        writer_query = endpoint == "graphql" and writer_token == "write-canary"
        if "git/trees" in endpoint or (endpoint == "graphql" and not writer_query):
            if self.unreadable and endpoint.startswith(self.unreadable):
                response = super().__call__(args, **kwargs)
                return response
            self.check_credentials(args, kwargs["env"])
            result: dict[str, Any]
            if endpoint == "graphql":
                query = json.loads(kwargs["input"])["query"]
                name = query.split('name: "', 1)[1].split('"', 1)[0]
                files = self.source_files[name]
                result = {
                    "data": {
                        "repository": {
                            f"f{index}": {"text": files[path], "isBinary": False}
                            for index, path in enumerate(sorted(files))
                        }
                    }
                }
            else:
                paths = sorted(self.source_files["alpha"])
                result = {
                    "tree": [
                        {"type": "blob", "path": path, "sha": f"{index:040x}"}
                        for index, path in enumerate(paths, start=1)
                    ]
                }
            return subprocess.CompletedProcess(args, 0, json.dumps(result), "")
        response = super().__call__(args, **kwargs)
        if endpoint.startswith("repos/lgtm-hq/lgtm-ci/issues?"):
            # gh --paginate returns consecutive JSON pages. Flip while reading
            # the final page, after any earlier publication metadata requests.
            issues = json.loads(response.stdout)
            response.stdout = json.dumps(issues[:1]) + "\n" + json.dumps(issues[1:])
            if self.boundary == "history" and not self.changed:
                self.change_visibility()
        elif "/issues" in endpoint and "--method" in args:
            if self.boundary == "write" and not self.changed:
                self.change_visibility()
        return response


class Cases(CoverageCases):
    """Retain real argument parsing, metadata validation and stateful issue writes."""

    def invoke_reports(
        self,
        transport: PublicationTransport,
        dry_run: bool = False,
    ) -> str:
        """Assert identical stdout, --report and step-summary publication."""
        with tempfile.TemporaryDirectory(prefix=".publication-", dir=ROOT) as temp:
            report = Path(temp) / "report.md"
            summary = Path(temp) / "summary.md"
            output: str
            status, output, error = self.invoke(
                transport,
                dry_run,
                app_env={"GITHUB_STEP_SUMMARY": str(summary)},
                cli_args=("--report", str(report)),
            )
            self.assertIsNone(error)
            self.assertEqual(status, 0)
            self.assertEqual(report.read_text(), output)
            self.assertEqual(summary.read_text(), output)
        return output

    def assert_redacted(self, text: str, mixed: bool = False) -> None:
        """Private source, job names and input names cannot cross publication."""
        self.assertNotIn("LATE_SOURCE_CANARY", text)
        self.assertNotIn("LATE_JOB_CANARY", text)
        self.assertNotIn("LATE_INPUT_CANARY", text)
        self.assertNotIn("LATE_METADATA_CANARY", text)
        if mixed:
            self.assertIn("echo /public-safe/", text)
        else:
            self.assertNotIn("Action input names:", text)
            self.assertNotIn("Public example from", text)

    def test_late_history_visibility(self) -> None:
        """Re-render creates after all pages; unknown metadata fails closed."""
        for visibility in (
            "private",
            "mixed",
            "malformed",
            "missing",
            "unreadable",
            "identity",
        ):
            for dry_run in (False, True):
                with self.subTest(visibility=visibility, dry_run=dry_run):
                    transport = PublicationTransport("history", visibility)
                    output = self.invoke_reports(transport, dry_run)
                    self.assertTrue(transport.changed)
                    self.assert_redacted(output, visibility == "mixed")
                    self.assertIn(
                        f"Private repositories: {2 if visibility == 'mixed' else 3}",
                        output,
                    )
                    self.assertEqual(len(transport.issues.writes), 0 if dry_run else 1)
                    for _, payload in transport.issues.writes:
                        self.assert_redacted(json.dumps(payload), visibility == "mixed")
                    history = transport.events.index(
                        "repos/lgtm-hq/lgtm-ci/issues?state=all&per_page=100"
                    )
                    self.assertIn(
                        "repos/lgtm-hq/alpha",
                        transport.events[history + 1 :],
                    )

    @staticmethod
    def seed_history(transport: PublicationTransport) -> None:
        """Seed matching decisions and obsolete historical clusters."""
        members = [
            unit
            for name, files in transport.source_files.items()
            for unit in model.units(f"lgtm-hq/{name}", False, files)
            if unit.kind == "steps"
        ]
        _, body = model.render((members, [], 1.0), 0.8)
        issues = []
        for number, state, reason in HISTORICAL_ISSUE_STATES:
            # Separate identities retain unmatched history alongside an active cluster.
            fingerprint = f"{number:024x}"
            existing = body.replace(members[0].fingerprint, fingerprint)
            existing = existing.replace(
                "Action input names: `node-version`.",
                "Action input names: `LATE_INPUT_CANARY`.",
            )
            existing = scan.with_reopen_record(existing, f"{number:032x}", "delivered")
            issues.append(
                {
                    "number": number,
                    "state": state,
                    "state_reason": reason,
                    "title": "Owner adoption plan",
                    "body": existing + "\nOwner notes.\n",
                }
            )
        # The actual cluster is completed; the other two remain unmatched history.
        issues[1]["body"] = issues[1]["body"].replace(
            f"{2:024x}",
            members[0].fingerprint,
        )
        transport.issues = FakeGitHub(issues)

    def test_late_history_lifecycle(self) -> None:
        """Cleanup preserves notes, closed decisions and delivery receipts."""
        for action in ("updated", "reopened", "suppressed"):
            for dry_run in (False, True):
                with self.subTest(action=action, dry_run=dry_run):
                    self.check_history_lifecycle(action, dry_run)

    def check_history_lifecycle(self, action: str, dry_run: bool) -> None:
        """Exercise the same matched identity under each adoption decision."""
        transport = PublicationTransport("history")
        self.seed_history(transport)
        active = transport.issues.issues[1]
        if action == "updated":
            active.update(state="open", state_reason=None)
            active["body"] = active["body"].replace(
                model.MEMBERS_END,
                "- `lgtm-hq/old-member`: `scripts/check.sh`\n" + model.MEMBERS_END,
            )
        elif action == "suppressed":
            active["state_reason"] = "not_planned"
        original = copy.deepcopy(transport.issues.issues)
        output = self.invoke_reports(transport, dry_run)
        self.assert_redacted(output)
        self.assertIn(f'"{action}": 1', output)
        if dry_run:
            self.assertEqual(transport.issues.writes, [])
            self.assertEqual(transport.issues.issues, original)
            return
        self.assertGreaterEqual(len(transport.issues.writes), 3)
        for _, payload in transport.issues.writes:
            self.assert_redacted(json.dumps(payload))
        for before, after in zip(original, transport.issues.issues, strict=True):
            self.assertIn("Owner notes.", after["body"])
            self.assertEqual(after["title"], before["title"])
            if after["number"] == 2 and action == "reopened":
                self.assertEqual(after["state"], "open")
                self.assertEqual(scan.reopen_record(after["body"])[1], "delivered")
                self.assertEqual(len(transport.issues.comments[2]), 1)
            else:
                self.assertEqual(after["state"], before["state"])
                self.assertEqual(after["state_reason"], before["state_reason"])
                self.assertEqual(
                    scan.reopen_record(after["body"]),
                    scan.reopen_record(before["body"]),
                )
        if action != "reopened":
            self.assertEqual(transport.issues.comments, {})
        transport.issues.writes.clear()
        self.invoke_reports(transport)
        self.assertEqual(transport.issues.writes, [])

    def test_late_failure_cleanup_visibility(self) -> None:
        """Coverage and source failures refresh visibility after historical reads."""
        for failure in ("coverage", "tree", "blob"):
            for dry_run in (False, True):
                with self.subTest(failure=failure, dry_run=dry_run):
                    transport = PublicationTransport("history")
                    self.seed_history(transport)
                    if failure == "coverage":
                        transport.responses.installation_pages = [
                            transport.page(transport.repos[:2])
                        ]
                    else:
                        transport.unreadable = {
                            "tree": "repos/lgtm-hq/alpha/git/trees",
                            "blob": "graphql",
                        }[failure]
                    _, output, error = self.invoke(transport, dry_run)
                    self.assertIsNotNone(error)
                    self.assertEqual(output, "")
                    self.assertEqual(len(transport.issues.writes), 0 if dry_run else 3)
                    for _, payload in transport.issues.writes:
                        self.assertEqual(set(payload), {"_method", "body"})
                        self.assert_redacted(payload["body"])
                        self.assertIn("Owner notes.", payload["body"])

    def test_late_report_visibility(self) -> None:
        """A change during issue writes independently redacts all report sinks."""
        for visibility in (
            "private",
            "mixed",
            "malformed",
            "missing",
            "unreadable",
            "identity",
        ):
            with self.subTest(visibility=visibility):
                transport = PublicationTransport("write", visibility)
                output = self.invoke_reports(transport)
                self.assertTrue(transport.changed)
                # The issue was sent while public. Its report must use fresh metadata.
                self.assertIn(
                    "LATE_SOURCE_CANARY",
                    transport.issues.writes[0][1]["body"],
                )
                self.assert_redacted(output, visibility == "mixed")

    def test_late_near_match_visibility(self) -> None:
        """Rebuild near matches at both boundaries, retaining the public control."""
        for boundary in ("history", "write"):
            for visibility in ("public", "private", "mixed", "unreadable"):
                with self.subTest(boundary=boundary, visibility=visibility):
                    transport = PublicationTransport(boundary, visibility)
                    output = self.invoke_reports(transport)
                    if visibility == "public":
                        self.assertIn("## Public near matches", output)
                        self.assertIn("LATE_NEAR_PATH_CANARY", output)
                        self.assertIn("LATE_SOURCE_CANARY", output)
                    else:
                        self.assertNotIn("## Public near matches", output)
                        self.assertNotIn("LATE_NEAR_PATH_CANARY", output)


if __name__ == "__main__":
    unittest.main()
