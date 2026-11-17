# SPDX-License-Identifier: MIT
"""Tests for when the tooling App mint runs and what reaches it (#1622).

Covers two rules of ``tooling_app_credential.py``, each on a copy of the
real pilot: the mint sits right before the job's first tooling consumer of
either kind, and its condition (``LGTM_CI_TOOLING_APP_NEEDED``) is the
Boolean of the consumers' conditions. What may run before the mint is in
``test_tooling_app_premint.py``.
"""

from __future__ import annotations

import importlib
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from tooling_app_tree import VALIDATOR, Tree

NEEDED_KEY = "      LGTM_CI_TOOLING_APP_NEEDED: "
BOOLEAN = " && 'true' || 'false' }}\n"
NEEDED_LINE = NEEDED_KEY + "${{ (github.event_name != 'merge_group')" + BOOLEAN
PULL_REQUEST = "github.event_name == 'pull_request'"
MERGE_GROUP_IF = "        if: github.event_name != 'merge_group'\n"
CHECKOUT_STEP = "      - name: Checkout lgtm-ci tooling\n"
HARDEN_STEP = "      - name: Checkout and harden\n"
REPOSITORY_STEP = "      - name: Checkout repository\n"
BEGIN_MINT = "      # lgtm-ci-inline:begin tooling-app-mint\n"
JOB_ENV = "    env:\n      # Every tooling consumer below"


def _job_env(line: str) -> str:
    """Return the pilot job's ``env:`` opening with one more entry."""
    return JOB_ENV.replace("    env:\n", f"    env:\n      {line}\n")


MISPLACED = (
    "[app] `tooling-app-target` and `tooling-app-token` must be the two steps "
    "right before the job's first tooling consumer"
)
STALE = "[app] `env.LGTM_CI_TOOLING_APP_NEEDED` must be exactly"
VERIFY_GUARD = "[app] the harden-runner verification runs only when"
SHA = "0123456789abcdef0123456789abcdef01234567"


@pytest.fixture(name="validator")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which loads the App rules beside it."""
    return load_script(VALIDATOR)


@pytest.fixture(name="tree")
def fixture_tree(tmp_path: Path, validator: ModuleType) -> Tree:
    """Return scratch copies of the real pilot and composite."""
    return Tree(tmp_path / ".github", validator)


def _step(tree: Tree, name: str) -> str:
    """Return the text of one top-level step of the pilot job."""
    pilot: str = tree.pilot
    start = pilot.index(name)
    end = pilot.index("      - name: ", start + len(name))
    return pilot[start:end]


# Item 4: the mint anchors on the earliest consumer of either kind.


def test_composite_only_job_passes(tree: Tree) -> None:
    """A job whose only consumer is checkout-and-harden mints right before it."""
    tree.edit(_step(tree, CHECKOUT_STEP), "")

    assert_that(tree.run()).is_empty()


def test_composite_call_before_the_mint_fails(tree: Tree) -> None:
    """A checkout-and-harden call ahead of the mint is a consumer without a token."""
    harden = _step(tree, HARDEN_STEP)
    tree.edit(harden, "")
    tree.edit(BEGIN_MINT, harden + BEGIN_MINT)

    assert_that(tree.findings()).contains(MISPLACED)


def test_step_between_check_and_mint_fails(tree: Tree) -> None:
    """Nothing may run between the check step and the mint."""
    tree.edit(
        "      - name: Mint tooling App token\n",
        "      - name: Between\n        run: echo between\n"
        "      - name: Mint tooling App token\n",
    )

    assert_that(tree.findings()).contains(MISPLACED)


def test_lower_case_secret_name_takes_the_pair(tree: Tree) -> None:
    """A secret named in another letter case still puts the file under the rules."""
    tree.write(
        "reusable-plain.yml",
        "---\nname: Plain\non:\n  workflow_call:\n"
        "jobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - run: echo done\n"
        "        env:\n          KEY: ${{ secrets.lgtm_ci_tooling_app_private_key }}\n",
    )

    assert_that(tree.findings()).contains(
        "reusable-plain.yml:1: [app] names the tooling App credential but does not "
        "declare secret LGTM_CI_TOOLING_APP_CLIENT_ID",
    )


# Item 3: the mint runs only when a consumer will.


def test_needed_value_joins_distinct_conditions(validator: ModuleType) -> None:
    """Any consumer running is enough; one unconditional consumer is all."""
    app = validator.app

    assert_that(app.needed_value(["a == 'x'", "a == 'x'"])).is_equal_to(
        "${{ (a == 'x') && 'true' || 'false' }}",
    )
    assert_that(app.needed_value(["a", "b", "a"])).is_equal_to(
        "${{ ((a) || (b)) && 'true' || 'false' }}",
    )
    assert_that(app.needed_value([None, "b"])).is_none()


def test_condition_unwraps_and_collapses(validator: ModuleType) -> None:
    """``${{ }}`` and line breaks do not make two conditions differ."""
    reader = importlib.import_module("tooling_token_yaml")
    root, _ = reader.parse("a:\n  if: >-\n    ${{ x ==\n    'y' }}\nb:\n  if: ''\n")

    assert_that(validator.app.condition(reader.descend(root, "a"))).is_equal_to(
        "x == 'y'",
    )
    assert_that(validator.app.condition(reader.descend(root, "b"))).is_none()


def test_condition_keeps_string_literals_as_written(validator: ModuleType) -> None:
    """Whitespace inside a literal is meaning, so it is never collapsed."""
    reader = importlib.import_module("tooling_token_yaml")
    root, _ = reader.parse(
        "a:\n  if: \"inputs.types   ==  'a  b' &&  x == 'it''s  ok'\"\n",
    )

    assert_that(validator.app.condition(reader.descend(root, "a"))).is_equal_to(
        "inputs.types == 'a  b' && x == 'it''s  ok'",
    )


def test_literal_whitespace_is_compared_as_written(tree: Tree) -> None:
    """A NEEDED value with the literal's spacing changed is stale."""
    literal = "        if: inputs.types == 'a  b'\n"
    tree.pilot = tree.pilot.replace(MERGE_GROUP_IF, literal)
    tree.edit(NEEDED_LINE, NEEDED_KEY + "${{ (inputs.types == 'a b')" + BOOLEAN)

    assert_that(tree.findings()).contains(STALE)


@pytest.mark.parametrize(
    "late",
    [
        "runner.os == 'Linux'",
        "contains(toJSON(runner), 'Linux')",
        "contains(toJSON(env), 'x')",
        "steps['a'].outcome == 'success'",
        "job.status == 'success'",
        "always()",
        "success() && inputs.a",
        "failure()",
        "cancelled()",
        "hashFiles('x') != ''",
    ],
)
def test_late_contexts_are_found(validator: ModuleType, late: str) -> None:
    """Every way of reading a late context or status is found."""
    app = validator.app

    assert_that(app.LATE.search(app.blank_literals(late))).is_not_none()


@pytest.mark.parametrize(
    "early",
    [
        "inputs.runner == 'x'",
        "github.event_name == 'job'",
        "needs.steps.result == 'success'",
        "contains(inputs.list, 'always()')",
    ],
)
def test_early_contexts_are_not_late(validator: ModuleType, early: str) -> None:
    """A word inside a literal or after a dot is not a context read."""
    app = validator.app

    assert_that(app.LATE.search(app.blank_literals(early))).is_none()


def test_missing_needed_fails(tree: Tree) -> None:
    """Conditional consumers without the job variable would mint on every event."""
    tree.edit(NEEDED_LINE, "")

    assert_that(tree.findings()).contains(
        "[app] every tooling consumer is conditional, so the job's `env:` must set "
        "`LGTM_CI_TOOLING_APP_NEEDED: "
        "${{ (github.event_name != 'merge_group') && 'true' || 'false' }}`",
    )


def test_stale_needed_fails(tree: Tree) -> None:
    """A mint condition that no longer matches the consumers fails."""
    tree.edit(
        NEEDED_LINE,
        NEEDED_KEY + "${{ " + PULL_REQUEST + " }}\n",
    )

    assert_that(tree.findings()).contains(STALE)


def test_edited_consumer_condition_leaves_needed_stale(tree: Tree) -> None:
    """Editing a checkout's ``if:`` alone is caught: the mint would not follow it."""
    checkout = _step(tree, CHECKOUT_STEP)
    tree.edit(
        checkout,
        checkout.replace(MERGE_GROUP_IF, f"        if: {PULL_REQUEST}\n"),
    )

    findings = tree.findings()
    assert_that(findings).contains(STALE, VERIFY_GUARD)


def test_needed_with_an_unconditional_consumer_fails(tree: Tree) -> None:
    """When a consumer always runs, the mint must too: the variable is refused."""
    checkout = _step(tree, CHECKOUT_STEP)
    tree.edit(checkout, checkout.replace(MERGE_GROUP_IF, ""))

    assert_that(tree.findings()).contains(
        "[app] `LGTM_CI_TOOLING_APP_NEEDED` must be absent",
        VERIFY_GUARD,
    )


def test_unconditional_job_keeps_the_simple_form(tree: Tree) -> None:
    """Without conditions on the consumers or the verification, no variable."""
    tree.edit(NEEDED_LINE, "")
    tree.pilot = tree.pilot.replace(MERGE_GROUP_IF, "")
    tree.write("reusable-semantic-pr-title.yml", tree.pilot)

    assert_that(tree.run()).is_empty()


def test_late_condition_fails(tree: Tree) -> None:
    """A condition the job env cannot evaluate cannot steer the mint."""
    late = "        if: runner.os == 'Linux'\n"
    tree.pilot = tree.pilot.replace(MERGE_GROUP_IF, late)
    tree.edit(NEEDED_LINE, "")

    assert_that(tree.findings()).contains(
        "[app] consumer condition `runner.os == 'Linux'` cannot be evaluated when "
        "the job starts",
    )


def test_non_scalar_checkout_path_is_unknown(validator: ModuleType) -> None:
    """A ``path`` that is a collection cannot be told apart from the tooling."""
    del validator
    reader = importlib.import_module("tooling_token_yaml")
    shared = importlib.import_module("tooling_token_check")
    root, _ = reader.parse("path: [a, b]\n")

    assert_that(shared.classify_path(reader.descend(root, "path"))).is_equal_to(
        shared.PATH_UNKNOWN,
    )
