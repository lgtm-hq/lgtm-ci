# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/docs/validate-caller-permissions.py``.

Covers the union computation (workflow-level, job-level, nested calls,
``read`` versus ``write``, shorthands), the governing-block lookup for
complete snippets and fragments, Markdown fence extraction with the brevity
marker, and the detect-changes derivation (#669).

Fixtures ``permissions_validator``, ``caller_repo`` and ``run_validator``
come from ``tests/python/conftest.py``.
"""

# pytest injects fixtures by parameter name; the shadowing is the mechanism.
# pylint: disable=redefined-outer-name
from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

DEMO_WORKFLOW = """---
name: Demo
on:
  workflow_call:
permissions:
  contents: read
jobs:
  work:
    runs-on: ubuntu-24.04
    permissions:
      pull-requests: read
    steps:
      - run: echo work
  publish:
    runs-on: ubuntu-24.04
    permissions:
      pull-requests: write # trailing comments are stripped
    steps:
      - run: echo publish
  nested:
    uses: ./.github/workflows/reusable-nested.yml
"""

NESTED_WORKFLOW = """---
name: Nested
on:
  workflow_call:
jobs:
  issue:
    runs-on: ubuntu-24.04
    permissions: { issues: write }
    steps:
      - run: echo issue
"""


@pytest.fixture
def repo(caller_repo: Callable[[dict[str, str]], Path]) -> Path:
    """Fixture repository whose demo workflow nests a second one."""
    return caller_repo(
        {"reusable-demo.yml": DEMO_WORKFLOW, "reusable-nested.yml": NESTED_WORKFLOW},
    )


def test_union_merges_levels_and_nested_calls(
    permissions_validator: ModuleType,
    repo: Path,
) -> None:
    """The union takes the stronger level per scope and follows nested calls."""
    union = permissions_validator.workflow_union(
        name="reusable-demo.yml",
        workflows_dir=repo / ".github" / "workflows",
    )

    assert_that(union).is_equal_to(
        {"contents": "read", "pull-requests": "write", "issues": "write"},
    )


def test_union_of_missing_workflow_is_none(
    permissions_validator: ModuleType,
    repo: Path,
) -> None:
    """A call to a workflow that does not exist resolves to no union."""
    union = permissions_validator.workflow_union(
        name="reusable-gone.yml",
        workflows_dir=repo / ".github" / "workflows",
    )

    assert_that(union).is_none()


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("{}", {}),
        (
            "{ contents: read, id-token: write }",
            {"contents": "read", "id-token": "write"},
        ),
    ],
    ids=["empty-map", "flow-map"],
)
def test_inline_permissions_parse(
    permissions_validator: ModuleType,
    value: str,
    expected: dict[str, str],
) -> None:
    """Inline ``permissions:`` values parse to scope mappings."""
    parsed = permissions_validator.parse_inline_permissions(value=value)

    assert_that(parsed).is_equal_to(expected)


@pytest.mark.parametrize(
    ("value", "level"),
    [("read-all", "read"), ("write-all", "write")],
)
def test_inline_permissions_shorthands(
    permissions_validator: ModuleType,
    value: str,
    level: str,
) -> None:
    """``read-all`` / ``write-all`` expand to every known scope at that level."""
    parsed = permissions_validator.parse_inline_permissions(value=value)

    assert_that(set(parsed.values())).is_equal_to({level})
    assert_that(parsed).contains_key("contents", "pull-requests", "id-token")


def test_inline_permissions_rejects_expressions(
    permissions_validator: ModuleType,
) -> None:
    """An expression where a level is expected is reported, not skipped."""
    with pytest.raises(ValueError, match="unparseable"):
        permissions_validator.parse_inline_permissions(value="${{ inputs.perms }}")


def test_complete_snippet_without_block_fails(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A complete snippet must carry the block even when marked."""
    (repo / "docs" / "guide.md").write_text(
        "_Fragment: permissions omitted for brevity._\n\n"
        "```yaml\njobs:\n  demo:\n"
        "    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>\n```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("guide.md:6: complete snippet calls reusable-demo.yml")
    assert_that(err).contains("with no permissions block")


def test_marked_fragment_without_block_passes(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A fragment marked above its fence may omit the block."""
    (repo / "docs" / "guide.md").write_text(
        "Permissions omitted for brevity; see the contract.\n\n"
        "```yaml\ndemo:\n"
        "  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>\n```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains(
        "OK: 1 documented caller call site(s)",
    )


def test_unmarked_fragment_without_block_fails(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An unmarked blockless fragment is the silent-omission class and fails."""
    (repo / "docs" / "guide.md").write_text(
        "```yaml\ndemo:\n"
        "  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>\n```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "unmarked fragment calls reusable-demo.yml",
    )


def test_understated_block_names_missing_scopes(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An under-grant reports the exact missing scopes and levels."""
    (repo / "examples" / "ci.yml").write_text(
        "jobs:\n  demo:\n"
        "    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main\n"
        "    permissions:\n      contents: read\n      pull-requests: read\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "examples")

    assert_that(code).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("ci.yml:3: reusable-demo.yml needs issues: write")
    assert_that(err).contains("issues: write, pull-requests: write")


def test_workflow_level_block_governs_complete_snippet(
    run_validator: Callable[..., int],
    repo: Path,
) -> None:
    """A job without its own block inherits the workflow-level block."""
    (repo / "examples" / "ci.yml").write_text(
        "permissions:\n  contents: read\n  issues: write\n  pull-requests: write\n"
        "jobs:\n  demo:\n"
        "    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "examples")

    assert_that(code).is_equal_to(0)


def test_detect_changes_requires_pull_requests_read(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A job running detect-changes with only contents: read is flagged (#669)."""
    (repo / "docs" / "guide.md").write_text(
        "```yaml\njobs:\n  changes:\n    runs-on: ubuntu-24.04\n"
        "    permissions:\n      contents: read\n    steps:\n"
        "      - uses: lgtm-hq/lgtm-ci/.github/actions/detect-changes@<sha>\n```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "docs/guide.md:8: actions/detect-changes needs pull-requests: read",
    )


def test_union_flag_prints_sorted_scopes(
    permissions_validator: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``--union`` prints the union one scope per line, sorted."""
    code = permissions_validator.main(
        argv=["--repo-root", str(repo), "--union", "reusable-demo.yml"],
    )

    assert_that(code).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_equal_to(
        "contents: read\nissues: write\npull-requests: write\n",
    )
