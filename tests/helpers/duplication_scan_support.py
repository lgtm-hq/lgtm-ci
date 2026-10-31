# SPDX-License-Identifier: MIT
"""Shared typed fixture and transport for offline duplication scanner cases."""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path
from typing import Any

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
    "FakeGitHub",
    "FixtureCase",
    "model",
    "scan",
    "syntax",
]

FIXTURES = ROOT / "tests/fixtures/duplication-scan"


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

    def api(
        self,
        endpoint: str,
        *,
        payload: Any = None,
        read: bool = True,
        source: bool = True,
    ) -> Any:
        """Record issue mutations and serve fixture repository/issue reads."""
        if read:
            self.reads.append((endpoint, source))
            if endpoint.startswith("orgs/") and self.repositories is not None:
                return copy.deepcopy(self.repositories)
            if "state=all" not in endpoint:
                raise AssertionError("must include closed issues")
            return copy.deepcopy(self.issues)
        assert isinstance(payload, dict)
        self.writes.append((endpoint, copy.deepcopy(payload)))
        if endpoint.endswith("/comments"):
            return {}
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
        return {}


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
