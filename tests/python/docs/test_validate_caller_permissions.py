# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/docs/validate-caller-permissions.py``.

Covers the union computation (workflow-level, job-level, nested calls,
``read`` versus ``write``, shorthands), the governing-block lookup for
complete snippets and fragments, Markdown fence extraction with the brevity
marker, the detect-changes derivation (#669), and the parser layouts the
first review round showed could be silently accepted or misclassified:
quoted ``uses:`` values, steps that start with ``- name:``, indentless step
sequences, indented and tilde fences, markers leaking across fences, quoted
scope levels, nested calls behind an explicit job block, and the cycle guard.

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

DEMO_CALL = "lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml"
DETECT = "lgtm-hq/lgtm-ci/.github/actions/detect-changes@<sha>"

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

OUTER_WORKFLOW = """---
on:
  workflow_call:
jobs:
  call:
    uses: ./.github/workflows/reusable-demo.yml
    permissions:
      contents: read
  loop:
    uses: ./.github/workflows/reusable-outer.yml
"""

FULL_BLOCK = "  contents: read\n  issues: write\n  pull-requests: write\n"


@pytest.fixture
def repo(caller_repo: Callable[[dict[str, str]], Path]) -> Path:
    """Fixture repository: a demo workflow nesting a second, plus a self-caller."""
    return caller_repo(
        {
            "reusable-demo.yml": DEMO_WORKFLOW,
            "reusable-nested.yml": NESTED_WORKFLOW,
            "reusable-outer.yml": OUTER_WORKFLOW,
        },
    )


# ---------------------------------------------------------------- unions


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


def test_explicit_job_block_bounds_nested_call_and_cycles_terminate(
    permissions_validator: ModuleType,
    repo: Path,
) -> None:
    """A job's own block is the nested-call boundary; self-calls do not recurse."""
    union = permissions_validator.workflow_union(
        name="reusable-outer.yml",
        workflows_dir=repo / ".github" / "workflows",
    )

    assert_that(union).is_equal_to({"contents": "read"})


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


def test_union_flag_reports_unparseable_workflow(
    permissions_validator: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``--union`` on a workflow with an expression level reports, not crashes."""
    (repo / ".github" / "workflows" / "reusable-bad.yml").write_text(
        "on:\n  workflow_call:\njobs:\n  j:\n    runs-on: x\n"
        "    permissions:\n      contents: ${{ inputs.level }}\n",
        encoding="utf-8",
    )

    code = permissions_validator.main(
        argv=["--repo-root", str(repo), "--union", "reusable-bad.yml"],
    )

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "ERROR: unparseable permissions block",
        "reusable-bad.yml",
    )


# ------------------------------------------------------- block parsing


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("{}", {}),
        (
            "{ contents: read, id-token: write }",
            {"contents": "read", "id-token": "write"},
        ),
        ("{ contents: 'read' }", {"contents": "read"}),
    ],
    ids=["empty-map", "flow-map", "quoted-level"],
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


def test_quoted_block_level_parses(
    permissions_validator: ModuleType,
) -> None:
    """``contents: "read"`` in a block is a valid level."""
    lines = permissions_validator.parse_lines(text='permissions:\n  contents: "read"\n')
    block = permissions_validator.block_permissions(lines=lines, index=0)

    assert_that(block).is_equal_to({"contents": "read"})


# ------------------------------------------------------ documented sites


def test_complete_snippet_without_block_fails(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A complete snippet must carry the block even when marked."""
    (repo / "docs" / "guide.md").write_text(
        "_Fragment: permissions omitted for brevity._\n\n"
        f"```yaml\njobs:\n  demo:\n    uses: {DEMO_CALL}@<sha>\n```\n",
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
        "*Fragment: permissions omitted for brevity, not copyable as-is.*\n\n"
        f"```yaml\ndemo:\n  uses: {DEMO_CALL}@<sha>\n```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains(
        "OK: 1 documented caller call site(s)",
    )


@pytest.mark.parametrize(
    ("opener", "closer"),
    [
        ("```yaml", "```"),
        ("~~~yaml", "~~~"),
        ("````yaml title=ci.yml", "````"),
        ("```yml {linenos}", "```"),
    ],
    ids=["plain", "tilde", "four-backticks-with-attrs", "three-with-attrs"],
)
def test_unmarked_fragment_without_block_fails(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    opener: str,
    closer: str,
) -> None:
    """An unmarked blockless fragment fails in every fence style."""
    (repo / "docs" / "guide.md").write_text(
        f"{opener}\ndemo:\n  uses: {DEMO_CALL}@<sha>\n{closer}\n",
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
        f"jobs:\n  demo:\n    uses: {DEMO_CALL}@main\n"
        "    permissions:\n      contents: read\n      pull-requests: read\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "examples")

    assert_that(code).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("ci.yml:3: reusable-demo.yml needs issues: write")
    assert_that(err).contains("issues: write, pull-requests: write")


def test_quoted_uses_value_is_checked(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A quoted ``uses:`` scalar is a call site, not a skip."""
    (repo / "examples" / "ci.yml").write_text(
        f'permissions: {{}}\njobs:\n  demo:\n    uses: "{DEMO_CALL}@main"\n',
        encoding="utf-8",
    )

    code = run_validator(repo, "examples")

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "reusable-demo.yml needs contents: read",
    )


@pytest.mark.parametrize(
    "layout",
    [
        f"permissions:\n{FULL_BLOCK}jobs:\n  demo:\n    uses: {DEMO_CALL}@main\n",
        "- Step\n\n  ```yaml\n  permissions:\n"
        + FULL_BLOCK.replace("  ", "    ")
        + f"  jobs:\n    demo:\n      uses: {DEMO_CALL}@<sha>\n  ```\n",
    ],
    ids=["example-file", "list-indented-fence"],
)
def test_workflow_level_block_governs_complete_snippet(
    run_validator: Callable[..., int],
    repo: Path,
    layout: str,
) -> None:
    """A job without its own block inherits the workflow-level block."""
    target = "examples/ci.yml" if layout.startswith("permissions:") else "docs/guide.md"
    (repo / target).write_text(layout, encoding="utf-8")

    assert_that(run_validator(repo, target.partition("/")[0])).is_equal_to(0)


def test_indented_fence_complete_snippet_cannot_use_marker(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A list-indented fence with top-level ``jobs:`` is still complete."""
    (repo / "docs" / "guide.md").write_text(
        "1. Step\n\n   _Permissions omitted for brevity._\n\n"
        f"   ```yaml\n   jobs:\n     demo:\n       uses: {DEMO_CALL}@<sha>\n   ```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "complete snippet calls reusable-demo.yml",
    )


def test_marker_does_not_leak_onto_next_fence(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A marker above one fence does not exempt the fence after it."""
    (repo / "docs" / "guide.md").write_text(
        "_Permissions omitted for brevity._\n\n"
        f"```yaml\na:\n  uses: {DEMO_CALL}@x\n```\n\n"
        f"```yaml\nb:\n  uses: {DEMO_CALL}@y\n```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains("guide.md:10: unmarked fragment")


def test_top_level_uses_fragment_needs_marker(
    run_validator: Callable[..., int],
    repo: Path,
) -> None:
    """A fragment whose ``uses:`` sits at column zero follows the marker rule."""
    guide = repo / "docs" / "guide.md"
    fence = f"```yaml\nuses: {DEMO_CALL}@<sha>\nwith:\n  x: 1\n```\n"
    guide.write_text(fence, encoding="utf-8")
    assert_that(run_validator(repo, "docs")).is_equal_to(1)

    guide.write_text("Permissions omitted for brevity.\n\n" + fence, encoding="utf-8")
    assert_that(run_validator(repo, "docs")).is_equal_to(0)


# --------------------------------------------------- detect-changes (#669)


@pytest.mark.parametrize(
    "steps",
    [
        f"    steps:\n      - uses: {DETECT}\n",
        f"    steps:\n      - name: Detect\n        uses: {DETECT}\n",
        f"    steps:\n    - uses: {DETECT}\n",
        f'    steps:\n      - id: detect\n        uses: "{DETECT}"\n',
    ],
    ids=["uses-first", "name-first", "indentless-sequence", "id-first-quoted"],
)
def test_detect_changes_requires_pull_requests_read(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    steps: str,
) -> None:
    """Every step layout running detect-changes with only contents: read is flagged."""
    (repo / "docs" / "guide.md").write_text(
        "```yaml\njobs:\n  changes:\n    runs-on: ubuntu-24.04\n"
        "    permissions:\n      contents: read\n" + steps + "```\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "actions/detect-changes needs pull-requests: read",
    )
