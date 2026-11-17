# SPDX-License-Identifier: MIT
"""Tests for the optional tooling App credential (#1622).

The rules live in ``scripts/ci/quality/tooling_app_credential.py`` and run as
part of ``validate_tooling_token.py``. Every case starts from a copy of the
real pilot, so the generated blocks under test are the ones that ship. The
check step's shell is run from the block source with a clean environment.
The condition and ambient rules are in ``test_tooling_app_conditions.py``;
what the steps and consumers do at run time in ``test_tooling_app_runtime.py``.
"""

from __future__ import annotations

import importlib
import os
import subprocess  # nosec B404 - runs the generated step's own bash
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that
from tooling_app_tree import (
    FLAGS_SOURCE,
    FORWARD_BLOCK,
    MINT_SOURCE,
    PILOT,
    ROOT,
    TOKEN_BLOCK,
    VALIDATOR,
    Tree,
)

REQUESTED = (
    "(secrets.LGTM_CI_TOOLING_APP_CLIENT_ID != '' "
    "|| secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY != '')"
)
GRANTED = "(steps.tooling-app-token.outputs.token || 'no-tooling-app-token')"
STORED = "secrets.LGTM_CI_TOOLING_TOKEN"
APP_TOKEN = "${{ " + f"{REQUESTED} && {GRANTED} || {STORED} || github.token" + " }}"
APP_FORWARD = "${{ " + f"{REQUESTED} && {GRANTED} || {STORED}" + " }}"
FALLBACK_LINE = "            || secrets.LGTM_CI_TOOLING_TOKEN || github"
# The first slice's consumer, which fell back to weaker credentials.
PILOT_ONE_TOKEN = (
    "${{ steps.tooling-app-token.outputs.token "
    "|| secrets.LGTM_CI_TOOLING_TOKEN || github.token }}"
)
OLD_TOKEN = "${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}"
OLD_FORWARD = "${{ secrets.LGTM_CI_TOOLING_TOKEN }}"
PIN = "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510"
MINT_LINE = f"        uses: {PIN} # v3.3.0\n"
PERMISSION = "          permission-contents: read\n"
TARGET_OUTPUT = "${{ steps.tooling-app-target.outputs.repository }}"
REPOSITORIES = f"          repositories: {TARGET_OUTPUT}\n"
OWNER = "          owner: ${{ steps.tooling-app-target.outputs.owner }}\n"
MINT_IF = "        if: steps.tooling-app-target.outputs.repository != ''\n"
ID_SET = "${{ secrets.LGTM_CI_TOOLING_APP_CLIENT_ID != '' }}"
KEY_SET = "${{ secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY != '' }}"
FLAG_ID = f"      LGTM_CI_TOOLING_APP_ID_SET: {ID_SET}\n"
FLAG_KEY = f"      LGTM_CI_TOOLING_APP_KEY_SET: {KEY_SET}\n"
TOOLING_CHECKOUT = "      - name: Checkout lgtm-ci tooling\n"
LATER_STEP = "      - name: Prepare semantic PR lists\n"
END_MINT = "      # lgtm-ci-inline:end tooling-app-mint\n"
WORKFLOW_REPOSITORY = "${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}"
TARGET_REPOSITORY = f"          TOOLING_REPOSITORY: {WORKFLOW_REPOSITORY}\n"
KEY_DECLARATION = "      LGTM_CI_TOOLING_APP_PRIVATE_KEY:\n"
LEAK = "[leak] `{}` may appear only in the generated tooling App blocks"
STEPS_LEAK = "[leak] the expression reads the steps context as a whole or by index"
NEEDS_ONE = "[app] the job needs exactly one `tooling-app-target` and one "
MISPLACED = "[app] `tooling-app-target` and `tooling-app-token` must be the two steps"
FOREIGN = "is not part of the generated step (generated block tooling-app-mint)"
LATER_RUN = (
    "      - name: Late reader\n"
    "        shell: bash\n"
    "        env:\n"
    "          VALUE: {}\n"
    "        run: echo done\n"
)


@pytest.fixture(name="validator")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which loads the App rules beside it."""
    return load_script(VALIDATOR)


@pytest.fixture(name="tree")
def fixture_tree(tmp_path: Path, validator: ModuleType) -> Tree:
    """Return scratch copies of the real pilot and composite."""
    return Tree(tmp_path / ".github", validator)


def test_pilot_copy_passes(tree: Tree) -> None:
    """The pilot as shipped satisfies every rule, the App rules included."""
    assert_that(tree.run()).is_empty()
    assert_that(tree.pilot).contains(TOKEN_BLOCK, FORWARD_BLOCK)
    workflow = yaml.safe_load(tree.pilot)
    steps = workflow["jobs"]["semantic-title"]["steps"]
    values = {
        key: step["with"][key]
        for step in steps
        for key in ("token", "tooling-token")
        if key in step.get("with", {})
    }
    assert_that(values).is_equal_to({"token": APP_TOKEN, "tooling-token": APP_FORWARD})


def test_pilot_takes_the_pair(validator: ModuleType) -> None:
    """The pilot is read as a file that takes the App credential."""
    check = validator.WorkflowCheck(ROOT / ".github" / "workflows" / PILOT)

    assert_that(check.run()).is_empty()
    assert_that(check.pair).is_true()
    assert_that(check.tooling_uses).is_length(1)
    assert_that(check.composite_uses).is_length(1)


def _source_steps() -> list[dict[str, Any]]:
    """Return the two steps of the mint block source."""
    steps: list[dict[str, Any]] = yaml.safe_load(
        MINT_SOURCE.read_text(encoding="utf-8"),
    )
    assert_that(steps).is_length(2)
    return steps


def test_rule_constants_match_the_block_source(validator: ModuleType) -> None:
    """The validator's exact shapes are the generated block, field for field."""
    app = importlib.import_module("tooling_app_credential")
    target, mint = _source_steps()
    flags = yaml.safe_load(FLAGS_SOURCE.read_text(encoding="utf-8"))

    assert_that(target).is_equal_to(app.TARGET_STEP)
    assert_that(mint).is_equal_to(app.MINT_STEP)
    assert_that(flags).is_equal_to(app.FLAGS)
    assert_that(validator.app).is_same_as(app)


def test_mint_is_tooling_only_and_read_only() -> None:
    """The mint names the tooling repository and asks for contents: read only."""
    _, mint = _source_steps()
    inputs = mint["with"]

    assert_that(mint["uses"]).is_equal_to(PIN)
    assert_that(sorted(inputs)).is_equal_to(
        ["client-id", "owner", "permission-contents", "private-key", "repositories"],
    )
    assert_that([key for key in inputs if key.startswith("permission-")]).is_equal_to(
        ["permission-contents"],
    )
    assert_that(inputs["permission-contents"]).is_equal_to("read")
    assert_that(inputs).does_not_contain_key("skip-token-revoke", "github-api-url")


def test_release_workflows_use_the_same_pin() -> None:
    """No second minting action or pin: the release workflows use this one."""
    workflows = ROOT / ".github" / "workflows"
    release = (workflows / "reusable-release-auto-tag.yml").read_text(encoding="utf-8")

    assert_that(release).contains(f"uses: {PIN} # v3.3.0\n")


@pytest.mark.parametrize(
    ("old", "new", "expected"),
    [
        pytest.param(
            PERMISSION,
            "          permission-contents: write\n",
            "[app] `tooling-app-token.with.permission-contents` must be exactly `read`",
            id="contents-write",
        ),
        pytest.param(
            PERMISSION,
            PERMISSION + "          permission-pull-requests: write\n",
            f"[app] `tooling-app-token.with.permission-pull-requests` {FOREIGN}",
            id="extra-permission",
        ),
        pytest.param(
            REPOSITORIES,
            "          repositories: other-repo\n",
            "[app] `tooling-app-token.with.repositories` must be exactly",
            id="other-repository",
        ),
        pytest.param(
            REPOSITORIES,
            "",
            "[app] `tooling-app-token.with.repositories` is missing",
            id="every-repository",
        ),
        pytest.param(
            OWNER,
            "          owner: example-org\n",
            "[app] `tooling-app-token.with.owner` must be exactly",
            id="other-owner",
        ),
        pytest.param(
            PERMISSION,
            PERMISSION + "          github-api-url: https://example.invalid\n",
            f"[app] `tooling-app-token.with.github-api-url` {FOREIGN}",
            id="other-api",
        ),
        pytest.param(
            PERMISSION,
            PERMISSION + '          skip-token-revoke: "true"\n',
            f"[app] `tooling-app-token.with.skip-token-revoke` {FOREIGN}",
            id="no-revoke",
        ),
        pytest.param(
            MINT_LINE,
            "        uses: actions/create-github-app-token@v3\n",
            "[app] `tooling-app-token.uses` must be exactly",
            id="unpinned",
        ),
        pytest.param(
            MINT_LINE,
            f"        uses: example-org/mint-token@{'0' * 40}\n",
            "[app] `tooling-app-token.uses` must be exactly",
            id="other-action",
        ),
        pytest.param(
            MINT_IF,
            "        if: always()\n",
            "[app] `tooling-app-token.if` must be exactly",
            id="mint-if",
        ),
        pytest.param(
            "          env.LGTM_CI_TOOLING_APP_NEEDED != 'false'\n",
            "          true\n",
            "[app] `tooling-app-target.if` must be exactly",
            id="target-if-ignores-consumers",
        ),
        pytest.param(
            "          && (env.LGTM_CI_TOOLING_APP_ID_SET == 'true' "
            "|| env.LGTM_CI_TOOLING_APP_KEY_SET == 'true')\n",
            "          && env.LGTM_CI_TOOLING_APP_ID_SET == 'true'\n",
            "[app] `tooling-app-target.if` must be exactly",
            id="target-if-one-flag",
        ),
        pytest.param(
            TARGET_REPOSITORY,
            "          TOOLING_REPOSITORY: example-org/other\n",
            "[app] `tooling-app-target.env.TOOLING_REPOSITORY` must be exactly",
            id="target-repository",
        ),
        pytest.param(
            "=~ ${SHAPE} ]]",
            "=~ ^(.*)/(.*)$ ]]",
            "[app] `tooling-app-target.run` must be exactly",
            id="target-run",
        ),
        pytest.param(
            "/([A-Za-z0-9._-]+)$\n",
            "/(.+)$\n",
            "[app] `tooling-app-target.env.SHAPE` must be exactly",
            id="target-shape",
        ),
        pytest.param(
            "        id: tooling-app-token\n",
            "        id: other-token\n",
            "[app] the job needs exactly one `tooling-app-target` and one "
            "`tooling-app-token` step",
            id="mint-renamed",
        ),
        pytest.param(
            FLAG_ID,
            "",
            "[app] the job's `env:` is missing `LGTM_CI_TOOLING_APP_ID_SET:",
            id="flag-missing",
        ),
        pytest.param(
            FLAG_KEY,
            "      LGTM_CI_TOOLING_APP_KEY_SET: ${{ true }}\n",
            "[app] `env.LGTM_CI_TOOLING_APP_KEY_SET` must be exactly",
            id="flag-forced",
        ),
        pytest.param(
            FLAG_KEY,
            "      LGTM_CI_TOOLING_APP_KEY_SET: {value: true}\n",
            "found `a mapping`",
            id="flag-mapping",
        ),
        pytest.param(
            KEY_DECLARATION,
            "      OTHER_SECRET:\n",
            "[app] names the tooling App credential but does not declare secret "
            "LGTM_CI_TOOLING_APP_PRIVATE_KEY",
            id="undeclared",
        ),
        pytest.param(
            "          with the App's client ID (#1622).\n        required: false\n",
            "          with the App's client ID (#1622).\n        required: true\n",
            "[app] secret LGTM_CI_TOOLING_APP_PRIVATE_KEY must be declared with "
            "`required: false`",
            id="required",
        ),
        pytest.param(
            TOKEN_BLOCK,
            f"          token: {OLD_TOKEN}\n",
            f"[token] `token` must be exactly `{APP_TOKEN}`",
            id="checkout-skips-app",
        ),
        pytest.param(
            TOKEN_BLOCK,
            "          token: ${{ steps.tooling-app-token.outputs.token }}\n",
            f"[token] `token` must be exactly `{APP_TOKEN}`",
            id="checkout-app-only",
        ),
        pytest.param(
            TOKEN_BLOCK,
            f"          token: {PILOT_ONE_TOKEN}\n",
            f"[token] `token` must be exactly `{APP_TOKEN}`",
            id="checkout-falls-back",
        ),
        pytest.param(
            "'no-tooling-app-token')\n" + FALLBACK_LINE,
            "'')\n" + FALLBACK_LINE,
            f"[token] `token` must be exactly `{APP_TOKEN}`",
            id="checkout-empty-sentinel",
        ),
        pytest.param(
            FORWARD_BLOCK,
            f"          tooling-token: {OLD_FORWARD}\n",
            f"[composite-call] `tooling-token` must be exactly `{APP_FORWARD}`",
            id="composite-skips-app",
        ),
        pytest.param(
            "'no-tooling-app-token')\n            || secrets.LGTM_CI_TOOLING_TOKEN }}",
            "'no-tooling-app-token')\n            || secrets.LGTM_CI_TOOLING_TOKEN "
            "|| github.token }}",
            f"[composite-call] `tooling-token` must be exactly `{APP_FORWARD}`",
            id="composite-falls-back",
        ),
    ],
)
def test_mint_shape_violations(tree: Tree, old: str, new: str, expected: str) -> None:
    """Anything but the exact generated mint, flags and declarations fails."""
    tree.edit(old, new)

    assert_that("\n".join(tree.run())).contains(expected)


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        pytest.param(
            "${{ steps.tooling-app-token.outputs.token }}",
            LEAK.format("tooling-app-token"),
            id="output",
        ),
        pytest.param(
            "${{ steps['tooling-app-token'].outputs.token }}",
            LEAK.format("tooling-app-token"),
            id="output-by-index",
        ),
        pytest.param(
            "${{ steps.Tooling-App-Token.outputs.token }}",
            LEAK.format("Tooling-App-Token"),
            id="output-other-case",
        ),
        pytest.param("${{ toJSON(steps) }}", STEPS_LEAK, id="whole-steps"),
        pytest.param(
            "${{ steps[format('tooling-app-{0}', 'token')].outputs.token }}",
            STEPS_LEAK,
            id="computed-index",
        ),
        pytest.param(
            "${{ secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY }}",
            LEAK.format("LGTM_CI_TOOLING_APP_PRIVATE_KEY"),
            id="private-key",
        ),
        pytest.param(
            "${{ secrets.lgtm_ci_tooling_app_client_id }}",
            LEAK.format("lgtm_ci_tooling_app_client_id"),
            id="client-id-lower-case",
        ),
        pytest.param(
            "${{ steps.tooling-app-target.outputs.owner }}",
            LEAK.format("tooling-app-target"),
            id="target-output",
        ),
        pytest.param(
            "${{ env.LGTM_CI_TOOLING_APP_ID_SET }}",
            LEAK.format("LGTM_CI_TOOLING_APP_ID_SET"),
            id="flag",
        ),
    ],
)
def test_later_readers_are_leaks(tree: Tree, value: str, expected: str) -> None:
    """No later step reads the token, the secrets or the flags."""
    tree.edit(LATER_STEP, LATER_RUN.format(value) + LATER_STEP)

    assert_that("\n".join(tree.run())).contains(expected)


def test_job_output_of_the_token_is_a_leak(tree: Tree) -> None:
    """The token cannot leave the job through a job output."""
    tree.edit(
        "    env:\n      # Every tooling consumer below",
        "    outputs:\n      token: ${{ steps.tooling-app-token.outputs.token }}\n"
        "    env:\n      # Every tooling consumer below",
    )

    assert_that("\n".join(tree.run())).contains(LEAK.format("tooling-app-token"))


def test_mint_must_be_right_before_the_tooling_checkout(tree: Tree) -> None:
    """A step between the mint and the tooling checkout fails."""
    tree.edit(END_MINT, END_MINT + "      - name: Between\n        run: echo between\n")

    assert_that("\n".join(tree.run())).contains(MISPLACED)


def test_mint_after_the_tooling_checkout_fails(tree: Tree) -> None:
    """The steps cannot move after the checkout they serve."""
    start = tree.pilot.index("      # lgtm-ci-inline:begin tooling-app-mint\n")
    end = tree.pilot.index(END_MINT) + len(END_MINT)
    block = tree.pilot[start:end]
    tree.edit(block, "")
    harden = "      - name: Checkout and harden\n"
    tree.edit(harden, block + harden)

    assert_that("\n".join(tree.run())).contains(MISPLACED)


def test_second_mint_fails(tree: Tree) -> None:
    """One mint per job: a copy elsewhere in the job fails."""
    start = tree.pilot.index("      - name: Mint tooling App token\n")
    block = tree.pilot[start : tree.pilot.index(END_MINT)]
    tree.edit(LATER_STEP, block + LATER_STEP)

    assert_that("\n".join(tree.run())).contains(
        NEEDS_ONE,
    )


def test_mint_in_a_job_without_tooling_fails(tree: Tree) -> None:
    """A mint with no tooling checkout to serve is refused."""
    start = tree.pilot.index("      - name: Check tooling App credential\n")
    block = tree.pilot[start : tree.pilot.index(END_MINT)]
    extra = "  other:\n    runs-on: ubuntu-latest\n    steps:\n" + block
    tree.write(PILOT, tree.pilot + extra)

    findings = "\n".join(tree.run())
    assert_that(findings).contains(
        "[app] a tooling App step in a job without a tooling consumer",
    )


def test_unconverted_file_may_not_read_the_mint(tree: Tree) -> None:
    """In a file without the pair, the App words are leaks, not a token."""
    text = (
        "---\nname: Plain\non:\n  workflow_call:\n    secrets:\n"
        "      LGTM_CI_TOOLING_TOKEN:\n        required: false\n"
        "jobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567\n"
        "        with:\n          path: .lgtm-ci-tooling\n"
        f"          token: {PILOT_ONE_TOKEN}\n"
        "          persist-credentials: false\n"
    )
    tree.write("reusable-plain.yml", text)

    findings = "\n".join(tree.run())
    assert_that(findings).contains(
        f"reusable-plain.yml:15: [token] `token` must be exactly `{OLD_TOKEN}`",
    )


def test_unconverted_file_naming_a_flag_is_a_leak(tree: Tree) -> None:
    """Without the pair, even a flag name is out of place."""
    text = (
        "---\nname: Plain\non:\n  workflow_call:\n"
        "jobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n"
        "      - run: echo ${{ env.LGTM_CI_TOOLING_APP_ID_SET }}\n"
    )
    tree.write("reusable-plain.yml", text)

    assert_that("\n".join(tree.run())).contains(
        "reusable-plain.yml:9: " + LEAK.format("LGTM_CI_TOOLING_APP_ID_SET"),
    )


APP_DECLARATIONS = "".join(
    f"      {name}:\n        required: false\n"
    for name in ("LGTM_CI_TOOLING_APP_CLIENT_ID", "LGTM_CI_TOOLING_APP_PRIVATE_KEY")
)
WRAPPER = (
    "---\nname: Wrapper\non:\n  workflow_call:\n    secrets:\n"
    "      LGTM_CI_TOOLING_TOKEN: {{required: false}}\n" + APP_DECLARATIONS + """jobs:
  inner:
    uses: {uses}
    secrets:
      LGTM_CI_TOOLING_TOKEN: ${{{{ secrets.LGTM_CI_TOOLING_TOKEN }}}}
{forwarded}"""
)
FORWARD_BOTH = "".join(
    f"      {name}: ${{{{ secrets.{name} }}}}\n"
    for name in ("LGTM_CI_TOOLING_APP_CLIENT_ID", "LGTM_CI_TOOLING_APP_PRIVATE_KEY")
)
NESTED_TOKEN = "      LGTM_CI_TOOLING_TOKEN: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}\n"
LOCAL_PILOT = f"./.github/workflows/{PILOT}"


def test_wrapper_forwarding_both_passes(tree: Tree) -> None:
    """A wrapper forwards the pair by name to a local target that declares it."""
    wrapper = WRAPPER.format(uses=LOCAL_PILOT, forwarded=FORWARD_BOTH)
    tree.write("reusable-wrapper.yml", wrapper)

    assert_that(tree.run()).is_empty()


@pytest.mark.parametrize(
    ("uses", "forwarded", "expected"),
    [
        pytest.param(
            LOCAL_PILOT,
            "",
            "[forward] missing `LGTM_CI_TOOLING_APP_CLIENT_ID: "
            "${{ secrets.LGTM_CI_TOOLING_APP_CLIENT_ID }}`",
            id="not-forwarded",
        ),
        pytest.param(
            LOCAL_PILOT,
            FORWARD_BOTH.replace(
                "${{ secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY }}",
                "${{ secrets.OTHER_KEY }}",
            ),
            "[forward] `secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY` must be exactly",
            id="other-value",
        ),
        pytest.param(
            LOCAL_PILOT,
            FORWARD_BOTH.replace(
                "${{ secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY }}",
                "{value: key}",
            ),
            "[forward] `secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY` must be exactly",
            id="mapping-value",
        ),
        pytest.param(
            "./.github/workflows/reusable-plain.yml",
            FORWARD_BOTH,
            "[forward] forwards LGTM_CI_TOOLING_APP_CLIENT_ID to "
            "`./.github/workflows/reusable-plain.yml`",
            id="undeclared-target",
        ),
        pytest.param(
            "example-org/example-ci/.github/workflows/"
            f"{PILOT}@0123456789abcdef0123456789abcdef01234567",
            FORWARD_BOTH,
            "[leak] forwards LGTM_CI_TOOLING_APP_CLIENT_ID to `example-org/",
            id="remote-target",
        ),
    ],
)
def test_wrapper_forwarding_violations(
    tree: Tree,
    uses: str,
    forwarded: str,
    expected: str,
) -> None:
    """The pair goes by name, only to a local target that declares it."""
    tree.write(
        "reusable-plain.yml",
        "---\nname: Plain\non:\n  workflow_call:\n    secrets:\n"
        "      LGTM_CI_TOOLING_TOKEN:\n        required: false\n"
        "jobs:\n  check:\n    runs-on: ubuntu-latest\n"
        "    steps:\n      - run: echo ok\n",
    )
    tree.write("reusable-wrapper.yml", WRAPPER.format(uses=uses, forwarded=forwarded))

    assert_that("\n".join(tree.run())).contains(expected)


def test_unconverted_wrapper_must_forward_the_pair(tree: Tree) -> None:
    """A wrapper whose target takes the pair has to take it too."""
    text = WRAPPER.format(uses=LOCAL_PILOT, forwarded="").replace(
        "      LGTM_CI_TOOLING_APP_CLIENT_ID:\n        required: false\n"
        "      LGTM_CI_TOOLING_APP_PRIVATE_KEY:\n        required: false\n",
        "",
    )
    tree.write("reusable-wrapper.yml", text)

    assert_that("\n".join(tree.run())).contains(
        "reusable-wrapper.yml:9: [forward] missing `LGTM_CI_TOOLING_APP_PRIVATE_KEY:",
    )


def test_inherit_in_a_file_with_the_pair_is_a_leak(tree: Tree) -> None:
    """``secrets: inherit`` would hand the App key to the target."""
    text = WRAPPER.format(uses=LOCAL_PILOT, forwarded="").replace(
        "    secrets:\n" + NESTED_TOKEN,
        "    secrets: inherit\n",
    )
    tree.write("reusable-wrapper.yml", text)

    findings = "\n".join(tree.run())
    assert_that(findings).contains("[leak] `secrets: inherit` hands every secret")


def test_non_mapping_job_and_steps_are_skipped(tree: Tree) -> None:
    """A malformed job is left to GitHub; it cannot hide a step."""
    tree.write(PILOT, tree.pilot + "  broken: just-a-string\n")

    assert_that(tree.run()).is_empty()


def test_missing_nested_target_is_not_declared(
    validator: ModuleType,
    tmp_path: Path,
) -> None:
    """A nested target that does not exist declares nothing."""
    app = validator.app

    assert_that(app.target_declares(tmp_path / "absent.yml")).is_none()


def test_differences_on_a_non_mapping(validator: ModuleType) -> None:
    """A step that is not a mapping is reported, not compared."""
    app = validator.app
    node = importlib.import_module("tooling_token_yaml").parse("[a, b]\n")[0]

    assert_that(app.differences(node, {"name": "x"}, "step")).is_equal_to(
        ["`step` must be a mapping"],
    )
    assert_that(app.differences(node, "x", "step")).is_equal_to(
        ["`step` must be exactly `x`, found `a sequence`"],
    )


# The check step's shell, run from the block source.
def _run_target(
    tmp_path: Path,
    *,
    id_set: str,
    key_set: str,
    repository: str,
) -> tuple[subprocess.CompletedProcess[str], str]:
    """Run the check step's ``run:`` with its ``env:`` and the job flags.

    Returns:
        The finished process and what it wrote to ``GITHUB_OUTPUT``.
    """
    target, _ = _source_steps()
    output = tmp_path / "output"
    output.write_text("", encoding="utf-8")
    script = tmp_path / "target.sh"
    script.write_text(target["run"], encoding="utf-8")
    env = {
        "PATH": os.environ["PATH"],
        "GITHUB_OUTPUT": str(output),
        "LGTM_CI_TOOLING_APP_ID_SET": id_set,
        "LGTM_CI_TOOLING_APP_KEY_SET": key_set,
        "INCOMPLETE": target["env"]["INCOMPLETE"],
        "UNREADABLE": target["env"]["UNREADABLE"],
        "SHAPE": target["env"]["SHAPE"],
        "TOOLING_REPOSITORY": repository,
    }
    result = subprocess.run(  # nosec B603 - fixed bash, generated script
        ["bash", "-e", "-o", "pipefail", str(script)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    return result, output.read_text(encoding="utf-8")


def test_target_splits_the_tooling_repository(tmp_path: Path) -> None:
    """Both secrets set: owner and name go to the step outputs."""
    result, output = _run_target(
        tmp_path,
        id_set="true",
        key_set="true",
        repository="example-org/example-ci.mirror",
    )

    assert_that(result.returncode).is_equal_to(0)
    assert_that(output).is_equal_to("owner=example-org\nrepository=example-ci.mirror\n")


@pytest.mark.parametrize(
    ("id_set", "key_set"),
    [("true", "false"), ("false", "true")],
    ids=["client-id-only", "private-key-only"],
)
def test_target_refuses_half_a_pair(tmp_path: Path, id_set: str, key_set: str) -> None:
    """One secret without the other fails with one message and no output."""
    result, output = _run_target(
        tmp_path,
        id_set=id_set,
        key_set=key_set,
        repository="example-org/example-ci",
    )

    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stdout).is_equal_to(
        "::error title=incomplete tooling App credential::pass both "
        "LGTM_CI_TOOLING_APP_CLIENT_ID and LGTM_CI_TOOLING_APP_PRIVATE_KEY, "
        "or neither\n",
    )
    assert_that(output).is_empty()


@pytest.mark.parametrize(
    "repository",
    [
        "",
        "example-ci",
        "example-org/example-ci/extra",
        "-example-org/example-ci",
        "example-org/example ci",
        "example-org/example-ci\nrepository=other",
    ],
    ids=["empty", "no-owner", "three-parts", "leading-dash", "space", "newline"],
)
def test_target_refuses_an_unreadable_repository(
    tmp_path: Path,
    repository: str,
) -> None:
    """A value that is not exactly owner/name writes no output."""
    result, output = _run_target(
        tmp_path,
        id_set="true",
        key_set="true",
        repository=repository,
    )

    assert_that(result.returncode).is_equal_to(1)
    unreadable = "::error title=unreadable tooling repository::"
    assert_that(result.stdout).starts_with(unreadable)
    assert_that(output).is_empty()


def test_flags_never_carry_a_secret_value() -> None:
    """The job env holds only whether each secret is set."""
    flags = yaml.safe_load(FLAGS_SOURCE.read_text(encoding="utf-8"))

    for value in flags.values():
        assert_that(value).ends_with(" != '' }}")


def test_reader_skips_a_non_scalar_key(validator: ModuleType) -> None:
    """A collection used as a key is neither a repeat nor a merge key."""
    del validator
    reader = importlib.import_module("tooling_token_yaml")

    root, problems = reader.parse("? [a, b]\n: 1\nc: 2\n")

    assert_that(problems).is_empty()
    assert_that(reader.fields(root)).contains_key("c")


def test_reader_bounds_an_alias_bomb(validator: ModuleType) -> None:
    """Expanding aliases past the node budget is reported, not attempted."""
    del validator
    reader = importlib.import_module("tooling_token_yaml")
    levels = ["a0: &a0 [x, x, x, x, x, x, x, x, x, x]"]
    for level in range(1, 7):
        refs = ", ".join([f"*a{level - 1}"] * 10)
        levels.append(f"a{level}: &a{level} [{refs}]")

    root, problems = reader.parse("\n".join(levels) + "\n")

    assert_that(root).is_none()
    assert_that(problems[0][1]).is_equal_to("too many nodes once aliases are expanded")
