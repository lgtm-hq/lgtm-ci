# SPDX-License-Identifier: MIT
"""Tests for when the tooling App mint runs and what reaches it (#1622).

Covers three rules of ``tooling_app_credential.py`` and
``tooling_app_ambient.py``, each on a copy of the real pilot: the mint sits
right before the job's first tooling consumer of either kind; its condition
(``LGTM_CI_TOOLING_APP_NEEDED``) equals the consumers' conditions; and no
``env:`` or earlier step can hand the minting action extra inputs.
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
NEEDED_LINE = NEEDED_KEY + "${{ github.event_name != 'merge_group' }}\n"
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
        "${{ a == 'x' }}",
    )
    assert_that(app.needed_value(["a", "b", "a"])).is_equal_to("${{ (a) || (b) }}")
    assert_that(app.needed_value([None, "b"])).is_none()


def test_condition_unwraps_and_collapses(validator: ModuleType) -> None:
    """``${{ }}`` and line breaks do not make two conditions differ."""
    reader = importlib.import_module("tooling_token_yaml")
    root, _ = reader.parse("a:\n  if: >-\n    ${{ x ==\n    'y' }}\nb:\n  if: ''\n")

    assert_that(validator.app.condition(reader.descend(root, "a"))).is_equal_to(
        "x == 'y'",
    )
    assert_that(validator.app.condition(reader.descend(root, "b"))).is_none()


def test_missing_needed_fails(tree: Tree) -> None:
    """Conditional consumers without the job variable would mint on every event."""
    tree.edit(NEEDED_LINE, "")

    assert_that(tree.findings()).contains(
        "[app] every tooling consumer is conditional, so the job's `env:` must set "
        "`LGTM_CI_TOOLING_APP_NEEDED: ${{ github.event_name != 'merge_group' }}`",
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


# Item 1: nothing outside the mint's own `with:` reaches it as an input.

AMBIENT = "[app] {} may not set `{}`: the tooling App mint would read it"


@pytest.mark.parametrize(
    ("old", "new", "expected"),
    [
        pytest.param(
            JOB_ENV,
            _job_env("INPUT_PERMISSION-issues: write"),
            AMBIENT.format("job `semantic-title` env", "INPUT_PERMISSION-issues"),
            id="job-input",
        ),
        pytest.param(
            JOB_ENV,
            _job_env("input_permission-ISSUES: write"),
            AMBIENT.format("job `semantic-title` env", "input_permission-ISSUES"),
            id="job-input-lower-case",
        ),
        pytest.param(
            JOB_ENV,
            _job_env("INPUT-PERMISSION-issues: write"),
            AMBIENT.format("job `semantic-title` env", "INPUT-PERMISSION-issues"),
            id="job-input-hyphen",
        ),
        pytest.param(
            JOB_ENV,
            _job_env("NODE_OPTIONS: --require ./x.js"),
            AMBIENT.format("job `semantic-title` env", "NODE_OPTIONS"),
            id="job-node-options",
        ),
        pytest.param(
            "env:\n  # Egress presets",
            "env:\n  INPUT_PERMISSION-ISSUES: write\n  # Egress presets",
            AMBIENT.format("workflow `env:`", "INPUT_PERMISSION-ISSUES"),
            id="workflow-input",
        ),
        pytest.param(
            "env:\n  # Egress presets",
            "env:\n  HTTPS_PROXY: http://proxy.example:3128\n  # Egress presets",
            AMBIENT.format("workflow `env:`", "HTTPS_PROXY"),
            id="workflow-proxy",
        ),
        pytest.param(
            JOB_ENV,
            _job_env("${{ matrix.name }}: write"),
            AMBIENT.format("job `semantic-title` env", "${{ matrix.name }}"),
            id="job-key-expression",
        ),
        pytest.param(
            JOB_ENV,
            "    env: ${{ fromJSON(inputs.job-env) }}\n    x-unused:\n"
            "      # Every tooling consumer below",
            "[app] job `semantic-title` env must be a mapping",
            id="job-env-expression",
        ),
        pytest.param(
            "    timeout-minutes: ${{ inputs.timeout-minutes }}\n",
            "    timeout-minutes: ${{ inputs.timeout-minutes }}\n"
            "    container:\n"
            f"      image: example.invalid/image@sha256:{'0' * 64}\n"
            "      env:\n        INPUT_PERMISSION-issues: write\n",
            AMBIENT.format(
                "job `semantic-title` container env",
                "INPUT_PERMISSION-issues",
            ),
            id="container-input",
        ),
    ],
)
def test_ambient_inputs_are_refused(
    tree: Tree,
    old: str,
    new: str,
    expected: str,
) -> None:
    """Workflow, job and container ``env:`` cannot add a mint input."""
    tree.edit(old, new)

    assert_that(tree.findings()).contains(expected)


BEFORE_MINT = "[app] step `Early` runs before the tooling App mint"


@pytest.mark.parametrize(
    ("step", "expected"),
    [
        pytest.param(
            "        env:\n"
            "          INPUT_PERMISSION-issues: write\n"
            "        run: echo early\n",
            "[app] step `Early` `env:` may not set `INPUT_PERMISSION-issues`",
            id="step-env-input",
        ),
        pytest.param(
            "        run: echo 'MODE=fast' >> \"$GITHUB_ENV\"\n",
            f"{BEFORE_MINT} and its `run:` has `GITHUB_ENV`",
            id="github-env-write",
        ),
        pytest.param(
            "        run: printf '%s=write\\n' input_permission-issues\n",
            f"{BEFORE_MINT} and its `run:` has `input_permission`",
            id="input-text",
        ),
        pytest.param(
            "        run: bash ./scripts/setup.sh\n",
            f"{BEFORE_MINT} and its `run:` has `bash`",
            id="caller-script",
        ),
        pytest.param(
            "        run: ./setup\n",
            f"{BEFORE_MINT} and its `run:` has `./`",
            id="relative-path",
        ),
        pytest.param(
            "        run: echo ok\n        working-directory: sub\n",
            f"{BEFORE_MINT} and may not set `working-directory`",
            id="working-directory",
        ),
        pytest.param(
            "        uses: ./.github/actions/setup\n",
            f"{BEFORE_MINT}: it must use a remote action pinned to a full commit",
            id="local-action",
        ),
        pytest.param(
            "        uses: example-org/setup@v1\n",
            f"{BEFORE_MINT}: it must use a remote action pinned to a full commit",
            id="unpinned-action",
        ),
        pytest.param(
            "        uses: docker://example.invalid/setup:1\n",
            f"{BEFORE_MINT}: it must use a remote action pinned to a full commit",
            id="container-action",
        ),
    ],
)
def test_no_caller_code_before_the_mint(tree: Tree, step: str, expected: str) -> None:
    """Steps ahead of the mint run no caller code and write no GITHUB_ENV."""
    tree.edit(REPOSITORY_STEP, "      - name: Early\n" + step + REPOSITORY_STEP)

    assert_that(tree.findings()).contains(expected)


def test_pinned_remote_action_before_the_mint_passes(tree: Tree) -> None:
    """A remote action pinned to a commit may run before the mint."""
    early = f"      - name: Early\n        uses: example-org/setup@{SHA}\n"
    tree.edit(REPOSITORY_STEP, early + REPOSITORY_STEP)

    assert_that(tree.run()).is_empty()


def test_step_input_variable_after_the_mint_passes(tree: Tree) -> None:
    """A step's own ``INPUT_*`` after the mint reaches only that step."""
    later = "      - name: Prepare semantic PR lists\n"
    tree.edit(
        later,
        "      - name: Late\n        env:\n          INPUT_NAME: value\n"
        '        run: echo "${INPUT_NAME}"\n' + later,
    )

    assert_that(tree.run()).is_empty()


def test_generated_block_before_the_mint_is_trusted(validator: ModuleType) -> None:
    """A ``run:`` that is exactly one generated block skips the text pattern."""
    ambient = validator.app.ambient

    block = "# lgtm-ci-inline:begin x\nmake the agent ready\n# lgtm-ci-inline:end x\n"
    assert_that(ambient.GENERATED.match(block)).is_not_none()
    assert_that(ambient.GENERATED.match(block + "bash ./x\n")).is_none()
    assert_that(ambient.CALLER_CODE.search("make the agent ready")).is_not_none()


def test_non_text_run_before_the_mint_fails(tree: Tree) -> None:
    """A ``run:`` that is not text cannot be read, so it is refused."""
    tree.edit(
        REPOSITORY_STEP,
        "      - name: Early\n        run: [echo, early]\n" + REPOSITORY_STEP,
    )

    expected = f"{BEFORE_MINT} and its `run:` has a non-text script"
    assert_that(tree.findings()).contains(expected)


def test_non_scalar_env_key_fails(tree: Tree) -> None:
    """A collection used as an ``env:`` key cannot be named, so it is refused."""
    tree.edit(JOB_ENV, _job_env("? [a, b]\n      : x"))

    assert_that(tree.findings()).contains(
        AMBIENT.format("job `semantic-title` env", "a non-scalar key"),
    )


def test_unnamed_step_before_the_mint_is_named_by_line(tree: Tree) -> None:
    """A step without ``name`` or ``id`` is reported by its line."""
    tree.edit(REPOSITORY_STEP, "      - run: bash ./x\n" + REPOSITORY_STEP)

    assert_that(tree.findings()).contains("[app] step `line ")


def test_non_scalar_checkout_path_is_unknown(validator: ModuleType) -> None:
    """A ``path`` that is a collection cannot be told apart from the tooling."""
    del validator
    reader = importlib.import_module("tooling_token_yaml")
    shared = importlib.import_module("tooling_token_check")
    root, _ = reader.parse("path: [a, b]\n")

    assert_that(shared.classify_path(reader.descend(root, "path"))).is_equal_to(
        shared.PATH_UNKNOWN,
    )
