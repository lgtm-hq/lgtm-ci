# SPDX-License-Identifier: MIT
"""Pins, Renovate and error messages for the tooling App credential (#1622).

The validator writes no pin of its own: the minting action's pin is read from
the block source, and the other actions allowed before the mint must use the
one pin the workflows use. These tests apply a Renovate-style bump of each
action to a scratch copy of the repository (every occurrence in workflows,
actions, examples and block sources, as the grouped pull request would) and
check that the sync check and the validator pass with no other edit.
"""

from __future__ import annotations

import json
import re
import shutil
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from tooling_app_tree import ROOT, VALIDATOR, Tree, pinned, source_uses_line

NEW_PIN = "0123456789abcdef0123456789abcdef01234567"
ACTIONS = (
    "step-security/harden-runner",
    "actions/checkout",
    "actions/create-github-app-token",
)
MINT_SOURCE = "scripts/ci/bootstrap/tooling-app-mint.yml"
SYNC = "scripts/ci/bootstrap/sync_inline_blocks.py"
REPOSITORY_STEP = "      - name: Checkout repository\n"


@pytest.fixture(name="validator")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which loads the App rules beside it."""
    return load_script(VALIDATOR)


@pytest.fixture(name="tree")
def fixture_tree(tmp_path: Path, validator: ModuleType) -> Tree:
    """Return scratch copies of the real pilot and composite."""
    return Tree(tmp_path / ".github", validator)


def _scratch(root: Path, sync: ModuleType) -> Path:
    """Copy what the sync check and the validator read into ``root``."""
    shutil.copytree(ROOT / ".github", root / ".github")
    shutil.copytree(ROOT / "examples", root / "examples")
    for block in sync.BLOCKS.values():
        target = root / block.script
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / block.script, target)
    return root


def _bump(root: Path, action: str, pin: str) -> int:
    """Replace every pin of ``action`` with ``pin`` and its version comment."""
    pattern = re.compile(rf"{re.escape(action)}@[0-9a-f]{{40}} # v[\d.]+")
    changed = 0
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix not in (".yml", ".yaml", ".sh"):
            continue
        text = path.read_text(encoding="utf-8")
        new, count = pattern.subn(f"{action}@{pin} # v99.0.0", text)
        if count:
            path.write_text(new, encoding="utf-8")
            changed += count
    return changed


def _check(
    validator: ModuleType,
    root: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[int, list[str]]:
    """Run the sync check and the validator against a scratch copy."""
    ambient = validator.app.ambient
    sync = ambient.sync_inline_blocks
    monkeypatch.setattr(ambient, "SOURCE_ROOT", root)
    workflows = root / ".github" / "workflows"
    status = sync.sync([workflows, root / "examples"], check=True, root=root)
    findings, _ = validator.validate(
        workflows_dir=workflows,
        actions_dir=root / ".github" / "actions",
    )
    return status, [finding.render() for finding in findings]


@pytest.mark.parametrize("action", ACTIONS)
def test_renovate_bump_needs_no_other_edit(
    validator: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    action: str,
) -> None:
    """A bump of every copy, as one grouped pull request makes it, passes."""
    root = _scratch(tmp_path, validator.app.ambient.sync_inline_blocks)

    assert_that(_bump(root, action, NEW_PIN)).is_greater_than(1)
    status, findings = _check(validator, root, monkeypatch)

    assert_that(findings).is_empty()
    assert_that(status).is_equal_to(0)
    assert_that(validator.app.ambient.mint_uses()).starts_with(
        "actions/create-github-app-token@",
    )


def test_split_mint_bump_fails_both_checks(
    validator: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Workflows bumped without the block source: why the bump is grouped."""
    root = _scratch(tmp_path, validator.app.ambient.sync_inline_blocks)
    source = (root / MINT_SOURCE).read_text(encoding="utf-8")
    _bump(root / ".github", "actions/create-github-app-token", NEW_PIN)
    (root / MINT_SOURCE).write_text(source, encoding="utf-8")

    status, findings = _check(validator, root, monkeypatch)

    assert_that(status).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains("differs from its source")
    assert_that(findings).is_length(1)
    assert_that(findings[0]).contains(
        "[app] `tooling-app-token.uses` must be exactly",
        f"source {MINT_SOURCE}; run uv run python {SYNC}",
    )


@pytest.mark.parametrize(
    ("old", "new", "field"),
    [
        pytest.param("@", f"@{NEW_PIN}#", "tooling-app-token.uses", id="mint-pin"),
        pytest.param(
            "permission-contents: read",
            "permission-contents: write",
            "tooling-app-token.with.permission-contents",
            id="mint-permission",
        ),
    ],
)
def test_one_mismatch_is_one_error(tree: Tree, old: str, new: str, field: str) -> None:
    """A generated step that differs is one error, not a cascade of leaks."""
    line = f"        {source_uses_line()}\n"
    if old == "@":
        changed = line.split("@", maxsplit=1)[0] + f"@{NEW_PIN} # v99.0.0\n"
        tree.edit(line, changed)
    else:
        tree.edit(old, new)

    findings = tree.run()

    assert_that(findings).is_length(1)
    assert_that(findings[0]).contains(f"[app] `{field}` must be exactly")


def test_unlisted_action_message_names_the_list(tree: Tree) -> None:
    """The message names the action found, the accepted pins and what to edit."""
    step = "      - name: Early\n        uses: example-org/setup@" + NEW_PIN + "\n"
    tree.edit(REPOSITORY_STEP, step + REPOSITORY_STEP)

    findings = tree.findings()

    assert_that(findings).contains(
        f"it uses `example-org/setup@{NEW_PIN}`, which is not an action "
        "PRE_MINT_ACTIONS in scripts/ci/quality/tooling_app_ambient.py allows "
        "before the mint (accepted: ",
        pinned("actions/checkout"),
        pinned("step-security/harden-runner"),
    )


@pytest.mark.parametrize(
    ("ref", "reason"),
    [
        ("main", "must be pinned at the full commit the repository uses for it"),
        ("v4", "must be pinned at the full commit the repository uses for it"),
        ("v4.2.2", "must be pinned at the full commit the repository uses for it"),
        (NEW_PIN, "at more than one commit"),
    ],
)
def test_listed_action_at_another_ref_is_refused(
    tree: Tree,
    ref: str,
    reason: str,
) -> None:
    """A listed action before the mint must use the repository's one commit.

    A branch or a tag adds nothing to the counted pins, so the step's own ref
    is compared; another full commit makes a second pin and is refused too.
    """
    step = f"      - name: Early\n        uses: actions/checkout@{ref}\n"
    tree.edit(REPOSITORY_STEP, step + REPOSITORY_STEP)

    early = [line for line in tree.findings().splitlines() if "`Early`" in line]

    assert_that(early).is_length(1)
    assert_that(early[0]).contains(f"it uses `actions/checkout@{ref}`", reason)


def test_env_message_names_the_list(tree: Tree) -> None:
    """An unlisted env key says where to add it."""
    job_env = "    env:\n      # Every tooling consumer below"
    tree.edit(job_env, job_env.replace("    env:\n", "    env:\n      MY_SETTING: x\n"))

    assert_that(tree.findings()).contains(
        "may not set `MY_SETTING`: only the names on the reviewed list may reach "
        "the tooling App mint; if this one is safe, add it with its reason to "
        "ENV_KEYS in scripts/ci/quality/tooling_app_ambient.py",
    )


def test_renovate_manager_matches_the_block_source(
    load_script: Callable[[str], ModuleType],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The regex manager reads the minting action and its version there."""
    matcher = load_script("scripts/ci/maintenance/match-renovate-pins.py")
    version = source_uses_line().rsplit("# v", 1)[1]

    assert_that(matcher.main(argv=[MINT_SOURCE])).is_equal_to(0)
    rows = [line.split("\t") for line in capsys.readouterr().out.splitlines()[1:]]
    assert_that([row[:3] for row in rows]).contains(
        [MINT_SOURCE, "actions/create-github-app-token", version],
    )


@pytest.mark.parametrize(
    "action",
    ["actions/create-github-app-token", "step-security/harden-runner"],
)
def test_renovate_groups_every_copy(action: str) -> None:
    """Workflow and non-workflow copies of a pin land in one pull request."""
    config = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
    groups = [
        rule.get("groupName")
        for rule in config.get("packageRules", [])
        if rule.get("matchPackageNames") == [action]
    ]

    assert_that(groups).is_equal_to([action])
