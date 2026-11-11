# SPDX-License-Identifier: MIT
"""Least-privilege contracts for release GitHub App installation tokens."""

from pathlib import Path

import pytest
import yaml
from assertpy import assert_that

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


@pytest.mark.parametrize(
    "workflow",
    ["reusable-release-version-pr.yml", "reusable-release-multi-ecosystem.yml"],
)
def test_version_pr_write_token_permissions(workflow: str) -> None:
    """Version PR writes need repository contents and pull requests only."""
    document = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8"))
    steps = document["jobs"]["version-pr"]["steps"]
    mint = next(step for step in steps if step.get("id") == "app-token")
    grants = mint["with"]
    permissions = {k: v for k, v in grants.items() if k.startswith("permission-")}
    assert_that(permissions).is_equal_to(
        {"permission-contents": "write", "permission-pull-requests": "write"},
    )


@pytest.mark.parametrize(
    "workflow",
    sorted(path.name for path in WORKFLOWS.glob("reusable-release-*.yml")),
)
def test_release_app_token_mints_declare_permissions(workflow: str) -> None:
    """Every release mint explicitly limits its installation permissions."""
    document = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8"))
    for job_name, job in document["jobs"].items():
        for step in job.get("steps", []):
            if not step.get("uses", "").startswith("actions/create-github-app-token@"):
                continue
            permissions = {
                key: value
                for key, value in step.get("with", {}).items()
                if key.startswith("permission-") and value
            }
            assert_that(permissions).described_as(
                f"{workflow}:{job_name}:{step.get('id', step.get('name'))}",
            ).is_not_empty()
