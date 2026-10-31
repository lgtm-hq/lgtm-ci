# SPDX-License-Identifier: MIT
"""Shared typed fixture and transport for offline duplication scanner cases."""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/ci/maintenance"))
import duplication_model as model  # noqa: E402  # pylint: disable=wrong-import-position
import duplication_scan as scan  # noqa: E402  # pylint: disable=wrong-import-position

# pylint: disable-next=wrong-import-position
import duplication_sources as syntax  # noqa: E402

__all__ = [
    "FIXTURES",
    "ROOT",
    "MALFORMED_SOURCE_RESPONSES",
    "FakeGitHub",
    "FixtureCase",
    "failed_source_inventory",
    "model",
    "scan",
    "syntax",
]

FIXTURES = ROOT / "tests/fixtures/duplication-scan"

# Endpoint, JSON payload, and expected original source-inventory failure.
MALFORMED_SOURCE_RESPONSES: dict[str, tuple[str, Any, type[Exception]]] = {
    "raw-tree-html": ("tree", "<html>PRIVATE_TREE_CANARY</html>", ValueError),
    "raw-tree-trailing": ("tree", "{}\nPRIVATE_TREE_CANARY", ValueError),
    "raw-blob-html": ("graphql", "<html>PRIVATE_BLOB_CANARY</html>", ValueError),
    "raw-blob-incomplete": ("graphql", '{"PRIVATE_BLOB_CANARY":', ValueError),
    "missing-tree": ("tree", {"truncated": False}, KeyError),
    "null-tree": ("tree", {"tree": None}, TypeError),
    "missing-tree-type": ("tree", {"tree": [{"path": "scripts/check.sh"}]}, KeyError),
    "null-tree-item": ("tree", {"tree": [None]}, TypeError),
    "missing-data": ("graphql", {}, KeyError),
    "missing-repository": ("graphql", {"data": {}}, KeyError),
    "missing-alias": ("graphql", {"data": {"repository": {}}}, KeyError),
    "null-data": ("graphql", {"data": None}, TypeError),
    "list-data": ("graphql", {"data": []}, TypeError),
    "list-repository": ("graphql", {"data": {"repository": []}}, RuntimeError),
    "missing-binary": (
        "graphql",
        {"data": {"repository": {"f0": {"text": "echo fixture"}}}},
        KeyError,
    ),
    "missing-text": (
        "graphql",
        {"data": {"repository": {"f0": {"isBinary": False}}}},
        KeyError,
    ),
    "list-blob": (
        "graphql",
        {"data": {"repository": {"f0": ["PRIVATE_BLOB_CANARY"]}}},
        TypeError,
    ),
}


class FakeGitHub(scan.GitHub):
    """Stateful issue transport: no process, network or credentials."""

    def __init__(
        self,
        issues: list[dict[str, Any]] | None = None,
        repositories: list[dict[str, Any]] | None = None,
    ) -> None:
        super().__init__()
        self.issues: list[dict[str, Any]] = copy.deepcopy(issues or [])
        self.repositories = repositories
        self.writes: list[tuple[str, dict[str, Any]]] = []
        self.reads: list[tuple[str, bool]] = []

    def files(self, repository: dict[str, Any]) -> dict[str, str]:
        """Return only in-memory fixture source."""
        files: dict[str, str] = repository["files"]
        return files

    def verify_source_coverage(self, repositories: list[dict[str, Any]]) -> None:
        """Trust only this in-memory fixture; real coverage has transport tests."""

    def api(
        self,
        endpoint: str,
        *,
        payload: Any = None,
        read: bool = True,
        source: bool = True,
        all_pages: bool = False,
    ) -> Any:
        """Record issue mutations and serve fixture repository/issue reads."""
        if read:
            self.reads.append((endpoint, source))
            if endpoint.startswith("orgs/") and self.repositories is not None:
                result = copy.deepcopy(self.repositories)
            else:
                if "state=all" not in endpoint:
                    raise AssertionError("must include closed issues")
                result = copy.deepcopy(self.issues)
            return [result] if all_pages else result
        assert isinstance(payload, dict)
        self.writes.append((endpoint, copy.deepcopy(payload)))
        if endpoint.endswith("/comments"):
            return [{}] if all_pages else {}
        if payload.get("_method") == "PATCH":
            number = int(endpoint.rsplit("/", 1)[1])
            issue = next(item for item in self.issues if item["number"] == number)
            issue.update(
                {key: value for key, value in payload.items() if key != "_method"},
            )
        else:
            self.issues.append(
                {
                    **payload,
                    "state": "open",
                    "number": len(self.issues) + 1,
                },
            )
        return [{}] if all_pages else {}


@contextmanager
def failed_source_inventory(api: FakeGitHub, failure: str) -> Iterator[None]:
    """Exercise real source reads while retaining stateful offline issue writes."""
    github = scan.GitHub

    def transport(
        args: list[str],
        **_kwargs: Any,
    ) -> subprocess.CompletedProcess[str]:
        endpoint = args[2]
        if (failure == "tree" and "git/trees" in endpoint) or (
            failure == "blob" and endpoint == "graphql"
        ):
            return subprocess.CompletedProcess(
                args,
                1,
                "",
                "PRIVATE_TRANSPORT_CANARY (HTTP 403)",
            )
        if "git/trees" in endpoint:
            result = {
                "truncated": failure == "truncated",
                "tree": [
                    {
                        "type": "blob",
                        "path": "scripts/check.sh",
                        "sha": "a" * 40,
                    }
                ],
            }
        else:
            assert endpoint == "graphql"
            result = (
                {"errors": [{"message": "PRIVATE_GRAPHQL_CANARY"}]}
                if failure == "graphql"
                else {"data": {"repository": {"f0": None}}}
            )
        if failure in MALFORMED_SOURCE_RESPONSES:
            boundary, malformed, _ = MALFORMED_SOURCE_RESPONSES[failure]
            if boundary == ("graphql" if endpoint == "graphql" else "tree"):
                if failure.startswith("raw-"):
                    return subprocess.CompletedProcess(args, 0, malformed, "")
                result = malformed
        return subprocess.CompletedProcess(args, 0, json.dumps(result), "")

    def request(endpoint: str, **kwargs: Any) -> Any:
        if failure == "enumeration" and endpoint.startswith("orgs/"):
            raise scan.GitHubError(True, 403)
        if "git/trees" in endpoint or endpoint == "graphql":
            # Only source transport is real; issue reads/writes remain offline.
            with patch.object(subprocess, "run", side_effect=transport):
                return github.api(api, endpoint, **kwargs)
        return FakeGitHub.api(api, endpoint, **kwargs)

    def inventory(repository: dict[str, Any]) -> dict[str, str]:
        if repository["full_name"] == "org/unrelated":
            return dict(github.files(api, repository))
        return dict(FakeGitHub.files(api, repository))

    with (
        patch.object(api, "files", side_effect=inventory),
        patch.object(api, "api", side_effect=request),
    ):
        yield


class FixtureCase(unittest.TestCase):
    """Load fixture units without any network activity."""

    def setUp(self) -> None:
        """Build the public and private fixture inventory."""
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
            (
                group[0][0].fingerprint,
                *model.render(group, 0.8),
            )
            for group in self.groups
        ]
