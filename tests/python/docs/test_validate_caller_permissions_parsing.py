# SPDX-License-Identifier: MIT
"""Parser-robustness tests for ``validate-caller-permissions.py``.

Each case pins a YAML or Markdown layout the first review round showed the
parser could silently accept or misclassify: quoted ``uses:`` values, steps
that start with ``- name:``, indentless step sequences, indented and tilde
fences, markers leaking across fences, quoted scope levels, nested calls
behind an explicit job block, and the cycle guard.

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
on:
  workflow_call:
jobs:
  work:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      pull-requests: write
    steps:
      - run: echo work
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


@pytest.fixture
def repo(caller_repo: Callable[[dict[str, str]], Path]) -> Path:
    """Fixture repository with a demo workflow and a self-calling outer one."""
    return caller_repo(
        {"reusable-demo.yml": DEMO_WORKFLOW, "reusable-outer.yml": OUTER_WORKFLOW},
    )


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
    "steps",
    [
        f"    steps:\n      - name: Detect\n        uses: {DETECT}\n",
        f"    steps:\n    - uses: {DETECT}\n",
        f'    steps:\n      - id: detect\n        uses: "{DETECT}"\n',
    ],
    ids=["name-first", "indentless-sequence", "id-first-quoted"],
)
def test_detect_changes_step_layouts_are_derived(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    steps: str,
) -> None:
    """Every step layout running detect-changes is held to #669."""
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


def test_indented_fence_workflow_level_block_governs(
    run_validator: Callable[..., int],
    repo: Path,
) -> None:
    """A list-indented complete snippet inherits its workflow-level block."""
    (repo / "docs" / "guide.md").write_text(
        "- Step\n\n  ```yaml\n  permissions:\n    contents: read\n"
        f"    pull-requests: write\n  jobs:\n    demo:\n      uses: {DEMO_CALL}@<sha>\n"
        "  ```\n",
        encoding="utf-8",
    )

    assert_that(run_validator(repo, "docs")).is_equal_to(0)


@pytest.mark.parametrize(
    ("opener", "closer"),
    [
        ("~~~yaml", "~~~"),
        ("````yaml title=ci.yml", "````"),
        ("```yml {linenos}", "```"),
    ],
    ids=["tilde", "four-backticks-with-attrs", "three-with-attrs"],
)
def test_other_fence_styles_are_scanned(
    run_validator: Callable[..., int],
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    opener: str,
    closer: str,
) -> None:
    """Tilde, longer and attributed fences are scanned like plain ones."""
    (repo / "docs" / "guide.md").write_text(
        f"{opener}\ndemo:\n  uses: {DEMO_CALL}@<sha>\n{closer}\n",
        encoding="utf-8",
    )

    code = run_validator(repo, "docs")

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "unmarked fragment calls reusable-demo.yml",
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


def test_quoted_scope_levels_parse(
    permissions_validator: ModuleType,
) -> None:
    """``contents: "read"`` and ``{ contents: 'read' }`` are valid levels."""
    parse = permissions_validator.parse_inline_permissions
    inline = parse(value="{ contents: 'read' }")
    lines = permissions_validator.parse_lines(text='permissions:\n  contents: "read"\n')
    block = permissions_validator.block_permissions(lines=lines, index=0)

    assert_that(inline).is_equal_to({"contents": "read"})
    assert_that(block).is_equal_to({"contents": "read"})


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
