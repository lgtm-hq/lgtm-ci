# SPDX-License-Identifier: MIT
"""Tests for the tooling token contract of the reusable workflows (#1451)."""

from collections.abc import Callable, Collection
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = "scripts/ci/quality/validate_tooling_token.py"
PILOT = "reusable-semantic-pr-title.yml"
ALLOWLIST = ROOT / "scripts/ci/quality/tooling-token-allowlist.txt"

TOKEN = "          token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}\n"
PERSIST = "          persist-credentials: false\n"
FORWARD = "          tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}\n"
OPTIONAL = "        required: false\n"
EXPR = "${{ secrets.LGTM_CI_TOOLING_TOKEN }}"
FALLBACK = "${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}"
MISSING_TOKEN = f"[token] missing `token: {FALLBACK}`"
MISSING_FORWARD = f"[composite-call] missing `tooling-token: {EXPR}`"
WHOLE_SECRETS = "[leak] the expression reads the secrets context as a whole or by index"
NOT_OPTIONAL = "[declaration] secret LGTM_CI_TOOLING_TOKEN must be declared with"
DESCRIPTION = "        description: Optional read-only tooling token\n"
NESTED_SECRET = "      LGTM_CI_TOOLING_TOKEN: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}\n"

COMPOSITE = """---
name: Checkout and harden
inputs:
  tooling-ref:
    required: true
  tooling-token:
    description: Read-only token for the tooling repository
    required: false
    default: ""
runs:
  using: composite
  steps:
    - name: Checkout lgtm-ci tooling
      uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v7
      with:
        path: .lgtm-ci-tooling
        ref: ${{ inputs.tooling-ref }}
        token: ${{ inputs.tooling-token || github.token }}
        persist-credentials: false
    - name: Resolve scripts directory
      shell: bash
      run: |
        echo "scripts-dir=${GITHUB_WORKSPACE}/.lgtm-ci-tooling/scripts"
"""

CONVERTED = f"""---
name: Converted
on:
  workflow_call:
    inputs:
      tooling-ref:
        type: string
    secrets:
      LGTM_CI_TOOLING_TOKEN:
        description: Optional read-only tooling token
{OPTIONAL}
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v7
        with:
          persist-credentials: false
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # tooling
        with:
          path: .lgtm-ci-tooling
          sparse-checkout: |
            .github/actions/checkout-and-harden
{TOKEN}{PERSIST}      - name: Checkout and harden
        uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
        with:
          tooling-ref: ${{{{ inputs.tooling-ref }}}}
{FORWARD}      - name: Run
        run: |
          echo "uses: ./.github/workflows/not-a-step.yml"
"""

UNCONVERTED = """---
name: Unconverted
on:
  workflow_call:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v7
        with:
          path: .lgtm-ci-tooling
          persist-credentials: false
      - name: Checkout and harden
        uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
        with:
          tooling-ref: abc
"""

WRAPPER = f"""---
name: Wrapper
on:
  workflow_call:
    secrets:
      LGTM_CI_TOOLING_TOKEN:
{OPTIONAL}
jobs:
  inner:
    uses: ./.github/workflows/reusable-converted.yml
    secrets:
{NESTED_SECRET}"""

NO_TOOLING = """---
name: No tooling
on:
  workflow_call:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
"""


@pytest.fixture(name="validator")
def fixture_validator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator as a module."""
    return load_script(SCRIPT_PATH)


class Tree:
    """A throwaway ``.github`` tree with a valid composite and no workflows.

    Args:
        root: Directory to build under.
        validator: The loaded validator module.
    """

    def __init__(self, root: Path, validator: ModuleType) -> None:
        self.validator = validator
        self.workflows = root / ".github" / "workflows"
        self.actions = root / ".github" / "actions"
        self.allowlist = root / "tooling-token-allowlist.txt"
        self.workflows.mkdir(parents=True)
        self.composite(COMPOSITE)

    def composite(self, text: str) -> None:
        """Write ``checkout-and-harden/action.yml``.

        Args:
            text: The file content.
        """
        target = self.actions / "checkout-and-harden"
        target.mkdir(parents=True, exist_ok=True)
        (target / "action.yml").write_text(text)

    def workflow(self, name: str, text: str) -> None:
        """Write one reusable workflow.

        Args:
            name: File name under ``.github/workflows``.
            text: The file content.
        """
        (self.workflows / name).write_text(text)

    def allow(self, *entries: str) -> None:
        """Write the allowlist.

        Args:
            *entries: File names, in the order given.
        """
        self.allowlist.write_text("# header\n\n" + "".join(f"{e}\n" for e in entries))

    def run(self, baseline: Collection[str] | None = None) -> list[str]:
        """Validate the tree.

        Args:
            baseline: The names the allowlist must hold, or None to leave
                the comparison out.

        Returns:
            list[str]: The rendered violations.
        """
        findings, _, _ = self.validator.validate(
            workflows_dir=self.workflows,
            actions_dir=self.actions,
            allowlist=self.allowlist if self.allowlist.is_file() else None,
            baseline=baseline,
        )
        return [finding.render() for finding in findings]


@pytest.fixture(name="tree")
def fixture_tree(tmp_path: Path, validator: ModuleType) -> Tree:
    """Return an empty tree with a valid composite."""
    return Tree(tmp_path, validator)


def line_of(text: str, needle: str) -> int:
    """Return the 1-based number of the first line containing ``needle``."""
    for number, line in enumerate(text.splitlines(), start=1):
        if needle in line:
            return number
    raise AssertionError(f"{needle!r} not in fixture")


def test_converted_tree_passes(tree: Tree) -> None:
    """A converted reusable, its wrapper and an allowlisted one pass together."""
    tree.workflow("reusable-converted.yml", CONVERTED)
    tree.workflow("reusable-wrapper.yml", WRAPPER)
    tree.workflow("reusable-no-tooling.yml", NO_TOOLING)
    tree.workflow("reusable-unconverted.yml", UNCONVERTED)
    tree.workflow("ci.yml", UNCONVERTED.replace("workflow_call:", "push:"))
    tree.allow("reusable-unconverted.yml")

    assert_that(tree.run(baseline=["reusable-unconverted.yml"])).is_empty()


def test_main_reports_counts(tree: Tree, capsys: pytest.CaptureFixture[str]) -> None:
    """The command line prints how many reusables are converted and listed."""
    tree.workflow("reusable-converted.yml", CONVERTED)
    tree.workflow("reusable-unconverted.yml", UNCONVERTED)
    tree.allow("reusable-unconverted.yml")

    code = tree.validator.main(
        [
            "--workflows-dir",
            str(tree.workflows),
            "--actions-dir",
            str(tree.actions),
            "--allowlist",
            str(tree.allowlist),
            "--baseline",
            "reusable-unconverted.yml",
        ],
    )

    assert_that(code).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains("1 converted, 1 allowlisted")


@pytest.mark.parametrize(
    ("old", "new", "needle", "expected"),
    [
        pytest.param(
            TOKEN,
            "",
            "# tooling",
            MISSING_TOKEN,
            id="a-token-missing",
        ),
        pytest.param(
            TOKEN,
            "          token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}\n",
            "token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}",
            "[token] `token` must be exactly",
            id="a-token-without-fallback",
        ),
        pytest.param(
            TOKEN,
            "          token: ${{ secrets.OTHER_TOKEN || github.token }}\n",
            "secrets.OTHER_TOKEN",
            "[token] `token` must be exactly",
            id="a-token-other-secret",
        ),
        pytest.param(
            TOKEN + PERSIST,
            TOKEN,
            "# tooling",
            "[token] missing `persist-credentials: false`",
            id="a-persist-missing",
        ),
        pytest.param(
            TOKEN + PERSIST,
            TOKEN + "          persist-credentials: true\n",
            "persist-credentials: true",
            "[token] `persist-credentials` must be exactly `false`, found `true`",
            id="a-persist-true",
        ),
        pytest.param(
            FORWARD,
            "",
            "uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden",
            MISSING_FORWARD,
            id="b-forward-missing",
        ),
        pytest.param(
            FORWARD,
            "          tooling-token: ${{ github.token }}\n",
            "tooling-token: ${{ github.token }}",
            "[composite-call] `tooling-token` must be exactly",
            id="b-forward-other-value",
        ),
        pytest.param(
            OPTIONAL,
            "        required: true\n",
            "      LGTM_CI_TOOLING_TOKEN:",
            NOT_OPTIONAL,
            id="c-required-true",
        ),
        pytest.param(
            OPTIONAL,
            "",
            "      LGTM_CI_TOOLING_TOKEN:",
            NOT_OPTIONAL,
            id="c-required-absent",
        ),
        pytest.param(
            "      - name: Run\n",
            "      - name: Leak\n        env:\n"
            "          TOKEN: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}\n"
            "        run: echo leak\n      - name: Run\n",
            "TOKEN: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}",
            "[leak] LGTM_CI_TOOLING_TOKEN may only be declared",
            id="e-env",
        ),
        pytest.param(
            '          echo "uses: ./.github/workflows/not-a-step.yml"\n',
            '          echo "${{ secrets.LGTM_CI_TOOLING_TOKEN }}"\n',
            'echo "${{ secrets.LGTM_CI_TOOLING_TOKEN }}"',
            "[leak] LGTM_CI_TOOLING_TOKEN may only be declared",
            id="e-run",
        ),
        pytest.param(
            "          tooling-ref: ${{ inputs.tooling-ref }}\n",
            "          tooling-ref: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}\n",
            "tooling-ref: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}",
            "[leak] LGTM_CI_TOOLING_TOKEN may only be declared",
            id="e-other-with",
        ),
        pytest.param(
            '          echo "uses: ./.github/workflows/not-a-step.yml"\n',
            "          echo '${{ toJSON(secrets) }}'\n",
            "toJSON(secrets)",
            WHOLE_SECRETS,
            id="e-tojson",
        ),
    ],
)
def test_converted_workflow_violations(
    tree: Tree,
    old: str,
    new: str,
    needle: str,
    expected: str,
) -> None:
    """Each rule on a converted reusable names the file and the line."""
    assert_that(CONVERTED).contains(old)
    text = CONVERTED.replace(old, new)
    tree.workflow("reusable-converted.yml", text)

    found = tree.run()

    assert_that(found).is_length(1)
    assert_that(found[0]).starts_with(
        f"reusable-converted.yml:{line_of(text, needle)}: {expected}",
    )


def test_undeclared_secret_is_reported_at_first_use(tree: Tree) -> None:
    """Rule c: a file that uses the token must declare the secret."""
    text = CONVERTED.replace(
        "    secrets:\n      LGTM_CI_TOOLING_TOKEN:\n" + DESCRIPTION + OPTIONAL,
        "",
    )
    tree.workflow("reusable-converted.yml", text)

    line = line_of(text, "path: .lgtm-ci-tooling") - 2
    assert_that(tree.run()).is_equal_to(
        [
            f"reusable-converted.yml:{line}: [declaration] uses the tooling token "
            "but does not declare secret LGTM_CI_TOOLING_TOKEN under "
            "on.workflow_call.secrets with `required: false`",
        ],
    )


def test_unconverted_workflow_reports_every_rule(tree: Tree) -> None:
    """A reusable off the allowlist fails rules a, b and c at once."""
    tree.workflow("reusable-unconverted.yml", UNCONVERTED)

    assert_that(tree.run()).is_equal_to(
        [
            "reusable-unconverted.yml:10: [declaration] uses the tooling token but "
            "does not declare secret LGTM_CI_TOOLING_TOKEN under "
            "on.workflow_call.secrets with `required: false`",
            "reusable-unconverted.yml:10: [token] missing `token: "
            "${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}`",
            "reusable-unconverted.yml:15: [composite-call] missing `tooling-token: "
            "${{ secrets.LGTM_CI_TOOLING_TOKEN }}`",
        ],
    )


@pytest.mark.parametrize(
    "path_line",
    [
        "path: ./.lgtm-ci-tooling",
        'path: ".lgtm-ci-tooling"',
        "path: '.lgtm-ci-tooling/'",
    ],
)
def test_tooling_path_spellings_are_recognised(tree: Tree, path_line: str) -> None:
    """Quoting or a leading ``./`` does not hide a tooling checkout."""
    text = UNCONVERTED.replace("path: .lgtm-ci-tooling", path_line)
    tree.workflow("reusable-unconverted.yml", text)

    assert_that("\n".join(tree.run())).contains("[token] missing `token:")


@pytest.mark.parametrize(
    ("old", "new", "expected"),
    [
        pytest.param(
            "    secrets:\n" + NESTED_SECRET,
            "",
            "reusable-wrapper.yml:11: [forward] missing `LGTM_CI_TOOLING_TOKEN: "
            "${{ secrets.LGTM_CI_TOOLING_TOKEN }}`",
            id="d-not-forwarded",
        ),
        pytest.param(
            NESTED_SECRET,
            "      OTHER: ${{ secrets.OTHER }}\n",
            "reusable-wrapper.yml:11: [forward] missing `LGTM_CI_TOOLING_TOKEN: "
            "${{ secrets.LGTM_CI_TOOLING_TOKEN }}`",
            id="d-other-secret-only",
        ),
        pytest.param(
            NESTED_SECRET,
            "      LGTM_CI_TOOLING_TOKEN: ${{ github.token }}\n",
            "reusable-wrapper.yml:13: [forward] `LGTM_CI_TOOLING_TOKEN` must be "
            "exactly `${{ secrets.LGTM_CI_TOOLING_TOKEN }}`, found "
            "`${{ github.token }}`",
            id="d-other-value",
        ),
        pytest.param(
            "    secrets:\n" + NESTED_SECRET,
            "    secrets: inherit\n",
            "reusable-wrapper.yml:12: [leak] `secrets: inherit` hands every secret, "
            "LGTM_CI_TOOLING_TOKEN included, to reusable-converted.yml; forward "
            "secrets by name",
            id="d-inherit",
        ),
    ],
)
def test_nested_call_must_forward(
    tree: Tree,
    old: str,
    new: str,
    expected: str,
) -> None:
    """Rule d: a wrapper forwards the secret to a target that declares it."""
    assert_that(WRAPPER).contains(old)
    tree.workflow("reusable-converted.yml", CONVERTED)
    tree.workflow("reusable-wrapper.yml", WRAPPER.replace(old, new))

    assert_that(tree.run()).is_equal_to([expected])


def test_wrapper_without_declaration_fails(tree: Tree) -> None:
    """Rules c and d: a wrapper that only forwards still declares the secret."""
    text = WRAPPER.replace(
        "    secrets:\n      LGTM_CI_TOOLING_TOKEN:\n" + OPTIONAL,
        "",
    )
    tree.workflow("reusable-converted.yml", CONVERTED)
    tree.workflow("reusable-wrapper.yml", text)

    assert_that(tree.run()).is_equal_to(
        [
            "reusable-wrapper.yml:8: [declaration] uses the tooling token but does "
            "not declare secret LGTM_CI_TOOLING_TOKEN under "
            "on.workflow_call.secrets with `required: false`",
        ],
    )


def test_forwarding_to_an_undeclared_target_fails(tree: Tree) -> None:
    """Rule d: forwarding to a callee that does not declare the secret fails."""
    tree.workflow("reusable-converted.yml", UNCONVERTED)
    tree.workflow("reusable-wrapper.yml", WRAPPER)
    tree.allow("reusable-converted.yml")

    assert_that(tree.run()).is_equal_to(
        [
            "reusable-wrapper.yml:13: [forward] forwards LGTM_CI_TOOLING_TOKEN to "
            "reusable-converted.yml, which does not declare it",
        ],
    )


def test_nested_call_to_unconverted_target_needs_nothing(tree: Tree) -> None:
    """A wrapper of an unconverted reusable has nothing to forward yet."""
    wrapper = """---
name: Wrapper
on:
  workflow_call:
jobs:
  inner:
    uses: ./.github/workflows/reusable-unconverted.yml
  missing:
    uses: ./.github/workflows/reusable-absent.yml
"""
    tree.workflow("reusable-unconverted.yml", UNCONVERTED)
    tree.workflow("reusable-wrapper.yml", wrapper)
    tree.allow("reusable-unconverted.yml")

    assert_that(tree.run()).is_empty()


def test_leak_applies_to_allowlisted_files(tree: Tree) -> None:
    """Rule e is not waived by the allowlist."""
    text = UNCONVERTED + (
        "      - name: Leak\n"
        "        env:\n"
        "          TOKEN: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}\n"
        "        run: echo leak\n"
    )
    tree.workflow("reusable-unconverted.yml", text)
    tree.allow("reusable-unconverted.yml")

    assert_that(tree.run()).is_equal_to(
        [
            "reusable-unconverted.yml:20: [leak] LGTM_CI_TOOLING_TOKEN may only be "
            "declared, passed to the tooling checkout's `token`, to "
            "checkout-and-harden's `tooling-token` and to a nested reusable's "
            "`secrets`",
        ],
    )


def test_comments_may_name_the_secret(tree: Tree) -> None:
    """A comment that mentions the secret is not a leak."""
    text = CONVERTED.replace(
        "      - name: Run\n",
        "      # LGTM_CI_TOOLING_TOKEN: checkout only.\n      - name: Run\n",
    )
    tree.workflow("reusable-converted.yml", text)

    assert_that(tree.run()).is_empty()


@pytest.mark.parametrize(
    ("old", "new", "expected"),
    [
        pytest.param(
            "        token: ${{ inputs.tooling-token || github.token }}\n",
            "",
            "checkout-and-harden/action.yml:14: [composite] tooling checkout is "
            "missing `token: ${{ inputs.tooling-token || github.token }}`",
            id="f-token-missing",
        ),
        pytest.param(
            "        token: ${{ inputs.tooling-token || github.token }}\n",
            "        token: ${{ inputs.tooling-token }}\n",
            "checkout-and-harden/action.yml:18: [composite] `token` must be exactly "
            "`${{ inputs.tooling-token || github.token }}`, found "
            "`${{ inputs.tooling-token }}`",
            id="f-token-without-fallback",
        ),
        pytest.param(
            "        persist-credentials: false\n",
            "        persist-credentials: ${{ inputs.persist-credentials }}\n",
            "checkout-and-harden/action.yml:19: [composite] `persist-credentials` "
            "must be exactly `false`, found `${{ inputs.persist-credentials }}`",
            id="f-persist-from-input",
        ),
        pytest.param(
            "      shell: bash\n",
            "      shell: bash\n      env:\n        T: ${{ inputs.tooling-token }}\n",
            "checkout-and-harden/action.yml:23: [composite] only the tooling "
            "checkout's `token:` may read inputs.tooling-token",
            id="f-env",
        ),
        pytest.param(
            '        echo "scripts-dir=',
            '        echo "${{ inputs.tooling-token }}"\n        echo "scripts-dir=',
            "checkout-and-harden/action.yml:23: [composite] only the tooling "
            "checkout's `token:` may read inputs.tooling-token",
            id="f-run",
        ),
        pytest.param(
            "        ref: ${{ inputs.tooling-ref }}\n",
            "        ref: ${{ inputs['tooling-token'] }}\n",
            "checkout-and-harden/action.yml:17: [composite] only the tooling "
            "checkout's `token:` may read inputs.tooling-token",
            id="f-index-syntax",
        ),
        pytest.param(
            '        echo "scripts-dir=',
            "        echo '${{ toJSON(inputs) }}'\n        echo \"scripts-dir=",
            "checkout-and-harden/action.yml:23: [composite] only the tooling "
            "checkout's `token:` may read inputs.tooling-token",
            id="f-tojson",
        ),
        pytest.param(
            "  tooling-token:\n"
            "    description: Read-only token for the tooling repository\n"
            '    required: false\n    default: ""\n',
            "",
            "checkout-and-harden/action.yml:3: [composite] input `tooling-token` is "
            "not declared",
            id="f-input-undeclared",
        ),
        pytest.param(
            "        path: .lgtm-ci-tooling\n",
            "        path: elsewhere\n",
            "checkout-and-harden/action.yml:1: [composite] no checkout with "
            "`path: .lgtm-ci-tooling` found",
            id="f-no-tooling-checkout",
        ),
    ],
)
def test_composite_violations(tree: Tree, old: str, new: str, expected: str) -> None:
    """Rule f: only the composite's checkout step reads the token input."""
    assert_that(COMPOSITE).contains(old)
    tree.composite(COMPOSITE.replace(old, new, 1))

    assert_that(tree.run()).contains(expected)


def test_missing_composite_fails(tree: Tree) -> None:
    """Rule f: the composite has to exist."""
    (tree.actions / "checkout-and-harden" / "action.yml").unlink()

    assert_that(tree.run()).is_equal_to(
        ["checkout-and-harden/action.yml:1: [composite] file not found"],
    )


def test_allowlisted_converted_file_fails(tree: Tree) -> None:
    """The allowlist only shrinks: a converted entry has to be removed."""
    tree.workflow("reusable-converted.yml", CONVERTED)
    tree.allow("reusable-converted.yml")

    assert_that(tree.run()).is_equal_to(
        [
            "tooling-token-allowlist.txt:3: [allowlist] reusable-converted.yml is "
            "already converted; remove the entry",
        ],
    )


def test_allowlisted_file_without_tooling_fails(tree: Tree) -> None:
    """An entry for a reusable that never checks out tooling is stale."""
    tree.workflow("reusable-no-tooling.yml", NO_TOOLING)
    tree.allow("reusable-no-tooling.yml")

    assert_that(tree.run()).is_equal_to(
        [
            "tooling-token-allowlist.txt:3: [allowlist] reusable-no-tooling.yml has "
            "no tooling; remove the entry",
        ],
    )


def test_allowlisted_missing_file_fails(tree: Tree) -> None:
    """An entry that names no file is an error."""
    tree.workflow("reusable-unconverted.yml", UNCONVERTED)
    tree.allow("reusable-gone.yml", "reusable-unconverted.yml")

    assert_that(tree.run()).is_equal_to(
        [
            "tooling-token-allowlist.txt:3: [allowlist] reusable-gone.yml does not "
            "exist in workflows; remove the entry",
        ],
    )


def test_allowlist_must_be_sorted_and_unique(tree: Tree) -> None:
    """Order and duplicates are checked so the diff of a slice stays readable."""
    tree.workflow("reusable-a.yml", UNCONVERTED)
    tree.workflow("reusable-b.yml", UNCONVERTED)
    tree.allow("reusable-b.yml", "reusable-a.yml", "reusable-a.yml")

    assert_that(tree.run()).is_equal_to(
        [
            "tooling-token-allowlist.txt:4: [allowlist] entries must be sorted; "
            "reusable-a.yml follows reusable-b.yml",
            "tooling-token-allowlist.txt:5: [allowlist] duplicate entry reusable-a.yml",
        ],
    )


def test_main_prints_violations(tree: Tree, capsys: pytest.CaptureFixture[str]) -> None:
    """A violation exits 1 and goes to stderr."""
    tree.workflow("reusable-unconverted.yml", UNCONVERTED)

    code = tree.validator.main(
        [
            "--workflows-dir",
            str(tree.workflows),
            "--actions-dir",
            str(tree.actions),
            "--baseline",
        ],
    )

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "ERROR: tooling token contract violations:",
        "  - reusable-unconverted.yml:10: [token]",
    )


@pytest.mark.parametrize(
    ("flag", "expected"),
    [
        ("--workflows-dir", "ERROR: workflows directory not found"),
        ("--actions-dir", "ERROR: actions directory not found"),
        ("--allowlist", "ERROR: allowlist not found"),
    ],
)
def test_main_rejects_missing_paths(
    tree: Tree,
    capsys: pytest.CaptureFixture[str],
    flag: str,
    expected: str,
) -> None:
    """A path that does not exist exits 2 before anything is checked."""
    args = {
        "--workflows-dir": str(tree.workflows),
        "--actions-dir": str(tree.actions),
        "--allowlist": str(tree.allowlist),
    }
    tree.allow()
    args[flag] = str(tree.workflows / "absent")

    code = tree.validator.main([part for pair in args.items() for part in pair])

    assert_that(code).is_equal_to(2)
    assert_that(capsys.readouterr().err).contains(expected)


def test_repository_passes(validator: ModuleType) -> None:
    """The real tree satisfies the contract with the committed allowlist."""
    findings, converted, allowlisted = validator.validate(
        workflows_dir=ROOT / ".github" / "workflows",
        actions_dir=ROOT / ".github" / "actions",
        allowlist=ALLOWLIST,
        baseline=validator.ALLOWLIST_BASELINE,
    )

    assert_that([finding.render() for finding in findings]).is_empty()
    assert_that(converted).is_greater_than_or_equal_to(1)
    assert_that(allowlisted).is_equal_to(
        len(
            [
                line
                for line in ALLOWLIST.read_text().splitlines()
                if line and not line.startswith("#")
            ],
        ),
    )


def test_pilot_and_composite_are_converted(validator: ModuleType) -> None:
    """The pilot is off the allowlist and passes every rule on its own."""
    workflows = ROOT / ".github" / "workflows"
    report = validator.WorkflowCheck(workflows / PILOT).run()

    assert_that(ALLOWLIST.read_text().splitlines()).does_not_contain(PILOT)
    assert_that(report.uses_tooling).is_true()
    assert_that(report.conversion + report.always).is_empty()
    assert_that(
        validator.check_composite(
            ROOT / ".github" / "actions" / "checkout-and-harden" / "action.yml",
        ),
    ).is_empty()


def test_self_test_caller_passes_the_job_token() -> None:
    """lgtm-ci's own caller exercises the secret with ``github.token``."""
    caller = (ROOT / ".github" / "workflows" / "semantic-pr-title.yml").read_text()

    assert_that(caller).contains(
        "    secrets:\n",
        "      LGTM_CI_TOOLING_TOKEN: ${{ github.token }}\n",
    )
    assert_that(caller).does_not_contain("secrets: inherit\n")


SHA = "0123456789abcdef0123456789abcdef01234567"
HEAD = """---
name: Shape
on:
  workflow_call:
    secrets:
      LGTM_CI_TOOLING_TOKEN:
        required: false
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
"""
UNDECLARED_HEAD = HEAD.replace(
    "    secrets:\n      LGTM_CI_TOOLING_TOKEN:\n        required: false\n",
    "",
)
GOOD_CHECKOUT = f"""      - uses: actions/checkout@{SHA}
        with:
          path: .lgtm-ci-tooling
          token: {FALLBACK}
          persist-credentials: false
"""
WRAPPER_HEAD = HEAD.replace("  check:\n    runs-on: ubuntu-latest\n    steps:\n", "")
UNCLASSIFIED_PATH = "[unclassified] checkout `path: "
REMOTE = "example-org/example-ci"
FLOW_PATH = "{path: .lgtm-ci-tooling}"
NESTED_USES = "./.github/workflows/reusable-converted.yml"
SUBPATH = "./.lgtm-ci-tooling/.github/actions/checkout-and-harden/sub"
CALLER_ACTION = "./.github/actions/checkout-and-harden"
REMOTE_ACTION = f"{REMOTE}/.github/actions/checkout-and-harden@{SHA}"
NOT_STAGED = (
    "[unclassified] `uses: {}` names checkout-and-harden but is not "
    "`./.lgtm-ci-tooling/.github/actions/checkout-and-harden`, the staged copy "
    "and the only one this check has read"
)
MERGE_KEY = "[yaml] merge keys (`<<`) are not read by GitHub Actions"


def shape(body: str, *, head: str = HEAD) -> str:
    """Return a reusable whose job body is ``body``."""
    return head + body


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        pytest.param(
            f"      - uses: actions/checkout@{SHA}\n"
            "        with: {path: .lgtm-ci-tooling, persist-credentials: true}\n",
            [
                f"reusable-shape.yml:12: {MISSING_TOKEN}",
                "reusable-shape.yml:13: [token] `persist-credentials` must be "
                "exactly `false`, found `true`",
            ],
            id="flow-with",
        ),
        pytest.param(
            f"      - {{uses: actions/checkout@{SHA}, with: {FLOW_PATH}}}\n",
            [
                "reusable-shape.yml:12: [token] missing `persist-credentials: false`",
                f"reusable-shape.yml:12: {MISSING_TOKEN}",
            ],
            id="flow-step",
        ),
        pytest.param(
            "      - name: Upload\n"
            "        uses: actions/upload-artifact@v4\n"
            "        with: &tooling\n"
            "          path: .lgtm-ci-tooling\n"
            "          persist-credentials: true\n"
            f"      - uses: actions/checkout@{SHA}\n"
            "        with: *tooling\n",
            [
                "reusable-shape.yml:13: [unclassified] `uses: "
                "actions/upload-artifact@v4` writes to .lgtm-ci-tooling but is not "
                "actions/checkout, so its token cannot be checked",
                "reusable-shape.yml:16: [token] `persist-credentials` must be "
                "exactly `false`, found `true`",
                f"reusable-shape.yml:17: {MISSING_TOKEN}",
            ],
            id="anchor-with",
        ),
        pytest.param(
            f"      - uses: actions/checkout@{SHA}\n"
            "        with:\n"
            "          path: >-\n"
            "            .lgtm-ci-tooling\n"
            "          persist-credentials: false\n",
            [f"reusable-shape.yml:12: {MISSING_TOKEN}"],
            id="folded-path",
        ),
        pytest.param(
            f"      - uses: actions/checkout@{SHA}\n"
            "        with:\n"
            '          path: "\\x2elgtm-ci-tooling"\n'
            "          persist-credentials: false\n",
            [f"reusable-shape.yml:12: {MISSING_TOKEN}"],
            id="escaped-path",
        ),
        pytest.param(
            f'      - "uses": >-\n          actions/checkout@{SHA}\n'
            '        "with":\n'
            "          'path': '.lgtm-ci-tooling'\n"
            "          persist-credentials: false\n",
            [f"reusable-shape.yml:12: {MISSING_TOKEN}"],
            id="quoted-keys-folded-uses",
        ),
        pytest.param(
            f"      - uses: Actions/Checkout@{SHA}\n"
            "        with:\n"
            "          path: sub/../.LGTM-CI-TOOLING/\n"
            "          persist-credentials: false\n",
            [f"reusable-shape.yml:12: {MISSING_TOKEN}"],
            id="case-and-dot-segments",
        ),
        pytest.param(
            "      - {uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden}\n",
            [f"reusable-shape.yml:12: {MISSING_FORWARD}"],
            id="flow-composite-call",
        ),
        pytest.param(
            "      - uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden/\n",
            [f"reusable-shape.yml:12: {MISSING_FORWARD}"],
            id="composite-trailing-slash",
        ),
        pytest.param(
            f"      - uses: {REMOTE}/.github/actions/checkout-and-harden@{SHA}\n",
            [f"reusable-shape.yml:12: {NOT_STAGED.format(REMOTE_ACTION)}"],
            id="composite-remote",
        ),
        pytest.param(
            "      - uses: ./.github/actions/checkout-and-harden\n"
            "        with: {tooling-ref: abc}\n",
            [f"reusable-shape.yml:12: {NOT_STAGED.format(CALLER_ACTION)}"],
            id="composite-local",
        ),
    ],
)
def test_yaml_shape_does_not_hide_a_step(
    tree: Tree,
    body: str,
    expected: list[str],
) -> None:
    """A tooling step is seen however it is written, and wherever it lives."""
    tree.workflow("reusable-shape.yml", shape(body))

    assert_that(tree.run()).is_equal_to(expected)


@pytest.mark.parametrize(
    ("job", "expected"),
    [
        pytest.param(
            "  inner: {uses: ./.github/workflows/reusable-converted.yml}\n",
            f"reusable-shape.yml:9: [forward] missing `LGTM_CI_TOOLING_TOKEN: {EXPR}`",
            id="flow-job",
        ),
        pytest.param(
            f"  inner:\n    uses: >-\n      {NESTED_USES}\n",
            f"reusable-shape.yml:10: [forward] missing `LGTM_CI_TOOLING_TOKEN: {EXPR}`",
            id="folded-uses",
        ),
        pytest.param(
            "  inner:\n"
            f"    uses: {REMOTE}/.github/workflows/reusable-converted.yml@{SHA}\n"
            "    secrets: {OTHER: x}\n",
            f"reusable-shape.yml:10: [unclassified] `uses: {REMOTE}/.github/"
            f"workflows/reusable-converted.yml@{SHA}` is not a local workflow "
            "file, so whether it takes LGTM_CI_TOOLING_TOKEN cannot be checked; "
            "in a file that names the secret a nested call must be "
            "`./.github/workflows/<file>`",
            id="remote-form",
        ),
        pytest.param(
            "  inner:\n"
            "    uses: ./.github/workflows/reusable-converted.yml\n"
            "    secrets: {LGTM_CI_TOOLING_TOKEN: '${{ github.token }}'}\n",
            "reusable-shape.yml:11: [forward] `LGTM_CI_TOOLING_TOKEN` must be "
            f"exactly `{EXPR}`, found `${{{{ github.token }}}}`",
            id="flow-secrets-other-value",
        ),
    ],
)
def test_nested_call_shape_does_not_hide_a_missing_forward(
    tree: Tree,
    job: str,
    expected: str,
) -> None:
    """Rule d holds for a nested call in flow, folded or remote form."""
    tree.workflow("reusable-converted.yml", CONVERTED)
    tree.workflow("reusable-shape.yml", shape(job, head=WRAPPER_HEAD))

    assert_that(tree.run()).is_equal_to([expected])


def test_inherit_to_a_declaring_target_fails_without_naming_the_secret(
    tree: Tree,
) -> None:
    """``secrets: inherit`` is not a way to forward, even in an undeclared file."""
    job = "  inner:\n    uses: ./.github/workflows/reusable-converted.yml\n"
    head = "---\nname: Shape\non:\n  workflow_call:\njobs:\n"
    tree.workflow("reusable-converted.yml", CONVERTED)
    tree.workflow("reusable-shape.yml", head + job + "    secrets: inherit\n")

    assert_that(tree.run()).is_equal_to(
        [
            "reusable-shape.yml:7: [declaration] uses the tooling token but does "
            "not declare secret LGTM_CI_TOOLING_TOKEN under "
            "on.workflow_call.secrets with `required: false`",
            "reusable-shape.yml:8: [forward] `secrets: inherit` is not accepted; "
            "forward LGTM_CI_TOOLING_TOKEN to reusable-converted.yml",
        ],
    )


@pytest.mark.parametrize(
    "path",
    [
        "${{ github.workspace }}/.lgtm-ci-tooling",
        "${{ matrix.p }}",
        "${{ inputs.dir }}/",
        "src/${{ inputs.dir }}/..",
        ".lgtm-ci-${{ inputs.suffix }}",
        "/home/runner/work/repo/repo/.lgtm-ci-tooling",
        ".lgtm-ci-tooling/nested",
    ],
)
@pytest.mark.parametrize("allowlisted", [False, True])
def test_unclassifiable_checkout_path_fails(
    tree: Tree,
    path: str,
    allowlisted: bool,
) -> None:
    """A path that may be the tooling directory is an error, listed or not."""
    body = (
        f"      - uses: actions/checkout@{SHA}\n"
        f"        with:\n          path: {path}\n          persist-credentials: false\n"
    )
    tree.workflow("reusable-shape.yml", shape(body, head=UNDECLARED_HEAD))
    tree.workflow("reusable-unconverted.yml", UNCONVERTED)
    tree.allow(
        *(["reusable-shape.yml"] if allowlisted else []),
        "reusable-unconverted.yml",
    )

    found = "\n".join(tree.run())

    assert_that(found).contains(f"reusable-shape.yml:11: {UNCLASSIFIED_PATH}{path}`")


@pytest.mark.parametrize(
    "path",
    [
        "${{ inputs.working-directory }}/src",
        "${{ runner.temp }}/trivy-sarif/",
        "caller",
    ],
)
def test_path_that_cannot_be_the_tooling_directory_passes(
    tree: Tree,
    path: str,
) -> None:
    """A literal last component other than the tooling directory is enough."""
    body = (
        f"      - uses: actions/checkout@{SHA}\n"
        f"        with:\n          path: {path}\n          persist-credentials: false\n"
        "      - uses: actions/upload-artifact@v4\n"
        "        with:\n          path: .lgtm-ci-tooling/report.json\n"
    )
    tree.workflow("reusable-shape.yml", shape(body, head=UNDECLARED_HEAD))

    assert_that(tree.run()).is_empty()


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        pytest.param(
            f"      - uses: {SUBPATH}\n",
            f"reusable-shape.yml:9: {NOT_STAGED.format(SUBPATH)}",
            id="composite-subpath",
        ),
        pytest.param(
            "      - uses: someone/checkout@v1\n"
            "        with:\n          path: .lgtm-ci-tooling\n",
            "reusable-shape.yml:9: [unclassified] `uses: someone/checkout@v1` "
            "writes to .lgtm-ci-tooling but is not actions/checkout, so its token "
            "cannot be checked",
            id="other-checkout-action",
        ),
        pytest.param(
            f"      - uses: actions/checkout@{SHA}\n        with: tooling\n",
            f"reusable-shape.yml:10: [unclassified] `with` of `actions/checkout@{SHA}"
            "` is not a mapping, so its inputs cannot be checked",
            id="with-not-a-mapping",
        ),
    ],
)
def test_unclassified_reference_fails(tree: Tree, body: str, expected: str) -> None:
    """A mention of the tooling that fits no known form is an error."""
    tree.workflow("reusable-shape.yml", shape(body, head=UNDECLARED_HEAD))

    assert_that(tree.run()).contains(expected)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        pytest.param(
            shape("      - run: [unterminated\n"),
            "[yaml] not valid YAML:",
            id="syntax-error",
        ),
        pytest.param(
            shape(
                GOOD_CHECKOUT + "        with:\n          path: .lgtm-ci-tooling\n",
            ),
            "reusable-shape.yml:17: [yaml] key `with` is repeated",
            id="repeated-key",
        ),
        pytest.param(
            shape(
                "      - &base\n        name: Base\n        run: echo ok\n"
                "      - <<: *base\n        name: Merged\n",
            ),
            f"reusable-shape.yml:15: {MERGE_KEY}",
            id="merge-key",
        ),
        pytest.param(
            shape("      - &loop\n        with: *loop\n"),
            "reusable-shape.yml:12: [yaml] an alias refers to its own anchor",
            id="recursive-alias",
        ),
    ],
)
@pytest.mark.parametrize("allowlisted", [False, True])
def test_unreadable_file_fails(
    tree: Tree,
    text: str,
    expected: str,
    allowlisted: bool,
) -> None:
    """A file that GitHub would read differently, or not at all, is an error."""
    tree.workflow("reusable-shape.yml", text)
    tree.allow(*(["reusable-shape.yml"] if allowlisted else []))

    assert_that("\n".join(tree.run())).contains(expected)


@pytest.mark.parametrize(
    ("name", "trigger"),
    [
        ("reusable-other.yaml", "on:\n  workflow_call:\n"),
        ("called.yml", "on:\n  workflow_call:\n"),
        ("called.yaml", "on:\n  push:\n  workflow_call:\n    inputs: {}\n"),
        ("called-list.yml", "on: [push, workflow_call]\n"),
        ("called-scalar.yml", "on: workflow_call\n"),
        ("called-quoted.yml", '"on":\n  "workflow_call":\n'),
        ("reusable-renamed.yml", "on:\n  push:\n"),
    ],
)
def test_reusables_are_found_by_extension_and_trigger(
    tree: Tree,
    name: str,
    trigger: str,
) -> None:
    """``.yaml`` files and callable workflows under any name are checked."""
    text = UNCONVERTED.replace("on:\n  workflow_call:\n", trigger)
    assert_that(text).contains(trigger)
    tree.workflow(name, text)

    assert_that("\n".join(tree.run())).contains(f"{name}:", MISSING_TOKEN)


def test_allowlist_names_a_yaml_or_renamed_reusable(tree: Tree) -> None:
    """An allowlist entry covers a callable workflow under any name."""
    tree.workflow("called.yaml", UNCONVERTED)
    tree.allow("called.yaml")

    assert_that(tree.run(baseline=["called.yaml"])).is_empty()


LEAK_STEP = "      - name: Leak\n        env:\n          T: {}\n        run: true\n"
NAME_LEAK = "[leak] LGTM_CI_TOOLING_TOKEN may only be declared"
INHERIT_JOB = f"  inner:\n    uses: {REMOTE}/.github/workflows/build.yml@v1\n"


@pytest.mark.parametrize(
    ("body", "line", "expected"),
    [
        pytest.param(
            LEAK_STEP.format("${{ secrets.lgtm_ci_tooling_token }}"),
            19,
            NAME_LEAK,
            id="lower-case",
        ),
        pytest.param(
            LEAK_STEP.format("${{ SECRETS.Lgtm_Ci_Tooling_Token }}"),
            19,
            NAME_LEAK,
            id="mixed-case",
        ),
        pytest.param(
            LEAK_STEP.format("${{ secrets[format('LGTM_CI_{0}', 'TOOLING_TOKEN')] }}"),
            19,
            WHOLE_SECRETS,
            id="index-computed",
        ),
        pytest.param(
            LEAK_STEP.format("${{ secrets [ inputs.name ] }}"),
            19,
            WHOLE_SECRETS,
            id="index-spaced",
        ),
        pytest.param(
            LEAK_STEP.format("${{ join(secrets.*, ',') }}"),
            19,
            WHOLE_SECRETS,
            id="star",
        ),
        pytest.param(
            LEAK_STEP.format("${{ toJSON( secrets ) }}"),
            19,
            WHOLE_SECRETS,
            id="tojson-spaced",
        ),
        pytest.param(
            LEAK_STEP.format("${{ TOJSON(Secrets) }}"),
            19,
            WHOLE_SECRETS,
            id="tojson-case",
        ),
        pytest.param(
            "      - if: contains(toJSON(secrets), 'x')\n        run: echo leak\n",
            17,
            WHOLE_SECRETS,
            id="bare-if",
        ),
        pytest.param(
            "      - run: |\n          echo ok\n"
            "          echo '${{ secrets[github.event.inputs.n] }}'\n",
            19,
            WHOLE_SECRETS,
            id="run-block",
        ),
        pytest.param(
            INHERIT_JOB + "    secrets: inherit\n",
            19,
            "[leak] `secrets: inherit` hands every secret, LGTM_CI_TOOLING_TOKEN "
            f"included, to {REMOTE}/.github/workflows/build.yml; forward secrets "
            "by name",
            id="inherit",
        ),
        pytest.param(
            INHERIT_JOB + "    secrets: >-\n      Inherit\n",
            19,
            "[leak] `secrets: inherit` hands every secret",
            id="inherit-folded",
        ),
    ],
)
@pytest.mark.parametrize("allowlisted", [False, True])
def test_leak_follows_expression_semantics(
    tree: Tree,
    body: str,
    line: int,
    expected: str,
    allowlisted: bool,
) -> None:
    """Rule e: case, index access and whole-context reads are all leaks."""
    tree.workflow("reusable-shape.yml", shape(GOOD_CHECKOUT + body))
    tree.allow(*(["reusable-shape.yml"] if allowlisted else []))

    found = [text for text in tree.run() if "[allowlist]" not in text]

    assert_that(found).is_length(1)
    assert_that(found[0]).starts_with(f"reusable-shape.yml:{line}: {expected}")


def test_index_access_by_name_is_reported_under_both_leak_messages(
    tree: Tree,
) -> None:
    """``secrets['NAME']`` names the secret and reads the context by index."""
    body = LEAK_STEP.format("${{ secrets['lgtm_ci_tooling_token'] }}")
    tree.workflow("reusable-shape.yml", shape(GOOD_CHECKOUT + body))

    found = tree.run()

    assert_that(found).is_length(2)
    assert_that(found[0]).starts_with(f"reusable-shape.yml:19: {NAME_LEAK}")
    assert_that(found[1]).starts_with(f"reusable-shape.yml:19: {WHOLE_SECRETS}")


def test_reads_of_other_secrets_are_not_leaks(tree: Tree) -> None:
    """Another secret by dotted name, a property and a script word are left alone."""
    body = (
        "      - name: Fine\n"
        "        if: inputs.secrets != '' && secrets.OTHER != ''\n"
        "        env:\n"
        "          A: ${{ secrets.OTHER || secrets . THIRD }}\n"
        "          C: ${{ needs.plan.outputs.secrets }}\n"
        "        run: echo 'secrets[0] and toJSON(secrets) in a script'\n"
    )
    tree.workflow("reusable-shape.yml", shape(GOOD_CHECKOUT + body))

    assert_that(tree.run()).is_empty()


@pytest.mark.parametrize(
    "read",
    [
        "${{ format('}}{0}', toJSON(secrets)) }}",
        "x }} ${{ toJSON(secrets) }}",
        "it's ${{ toJSON(secrets) }} it's",
        "${{ format('{0}', secrets) }}",
        "${{ secrets['OTHER'] }}",
        "${{ format('{0}', 'toJSON(secrets)') }}",
        "${{ github.event_name != 'secrets' }}",
    ],
)
@pytest.mark.parametrize("allowlisted", [False, True])
def test_scalar_is_searched_as_a_whole_for_secrets(
    tree: Tree,
    read: str,
    allowlisted: bool,
) -> None:
    """Rule e: no quote and no ``}}`` hides a read of the secrets context.

    A string literal that holds the word fails too: the check does not parse
    expressions, so it cannot tell that literal from code.
    """
    tree.workflow("reusable-shape.yml", shape(GOOD_CHECKOUT + LEAK_STEP.format(read)))
    tree.allow(*(["reusable-shape.yml"] if allowlisted else []))

    found = [text for text in tree.run() if "[allowlist]" not in text]

    assert_that(found).is_length(1)
    assert_that(found[0]).starts_with(f"reusable-shape.yml:19: {WHOLE_SECRETS}")


def test_whole_context_read_passes_without_the_secret(tree: Tree) -> None:
    """A file that never names the secret cannot leak it."""
    step = "      - run: echo '${{ toJSON(secrets) }}'\n"
    body = step + INHERIT_JOB + "    secrets: inherit\n"
    tree.workflow("reusable-shape.yml", shape(body, head=UNDECLARED_HEAD))

    assert_that(tree.run()).is_empty()


@pytest.mark.parametrize(
    "read",
    [
        "${{ inputs.Tooling-Token }}",
        "${{ INPUTS.TOOLING-TOKEN }}",
        "${{ inputs . tooling-token }}",
        "${{ inputs['tooling-token'] }}",
        "${{ inputs[ 'TOOLING-TOKEN' ] }}",
        "${{ inputs[format('tooling-{0}', 'token')] }}",
        "${{ join(inputs.*, ',') }}",
        "${{ toJSON( inputs ) }}",
        "${{ ToJson(Inputs) }}",
    ],
)
def test_composite_read_follows_expression_semantics(tree: Tree, read: str) -> None:
    """Rule f: case, index access and whole-context reads are all reads."""
    old = "      shell: bash\n"
    assert_that(COMPOSITE).contains(old)
    tree.composite(COMPOSITE.replace(old, f"{old}      env:\n        T: {read}\n"))

    assert_that(tree.run()).is_equal_to(
        [
            "checkout-and-harden/action.yml:23: [composite] only the tooling "
            "checkout's `token:` may read inputs.tooling-token",
        ],
    )


@pytest.mark.parametrize(
    ("old", "new", "expected"),
    [
        pytest.param(
            "      with:\n        path: .lgtm-ci-tooling\n"
            "        ref: ${{ inputs.tooling-ref }}\n"
            "        token: ${{ inputs.tooling-token || github.token }}\n"
            "        persist-credentials: false\n",
            "      with: {path: .lgtm-ci-tooling, persist-credentials: true}\n",
            [
                "checkout-and-harden/action.yml:14: [composite] tooling checkout is "
                "missing `token: ${{ inputs.tooling-token || github.token }}`",
                "checkout-and-harden/action.yml:15: [composite] "
                "`persist-credentials` must be exactly `false`, found `true`",
            ],
            id="flow-with",
        ),
        pytest.param(
            "        path: .lgtm-ci-tooling\n",
            "        path: ${{ github.workspace }}/.lgtm-ci-tooling\n",
            [
                "checkout-and-harden/action.yml:1: [composite] no checkout with "
                "`path: .lgtm-ci-tooling` found",
                "checkout-and-harden/action.yml:16: [composite] checkout `path: "
                "${{ github.workspace }}/.lgtm-ci-tooling` cannot be told apart "
                "from .lgtm-ci-tooling; write the path so that its last component "
                "is a literal",
                "checkout-and-harden/action.yml:18: [composite] only the tooling "
                "checkout's `token:` may read inputs.tooling-token",
            ],
            id="expression-path",
        ),
    ],
)
def test_composite_shape_does_not_hide_the_checkout(
    tree: Tree,
    old: str,
    new: str,
    expected: list[str],
) -> None:
    """Rule f holds for a flow-style or expression-path checkout."""
    assert_that(COMPOSITE).contains(old)
    tree.composite(COMPOSITE.replace(old, new))

    assert_that(tree.run()).is_equal_to(expected)


NOT_IN_BASELINE = (
    "tooling-token-allowlist.txt:3: [allowlist] {} is not in ALLOWLIST_BASELINE "
    "of validate_tooling_token.py: the list only loses names, so convert the "
    "reusable instead of listing it"
)
NOT_LISTED = (
    "[allowlist] {} is in ALLOWLIST_BASELINE of validate_tooling_token.py but not "
    "listed; remove it from the baseline too"
)


def test_new_unconverted_reusable_cannot_join_the_allowlist(tree: Tree) -> None:
    """The ratchet: a new entry for a new unconverted reusable fails."""
    tree.workflow("reusable-old.yml", UNCONVERTED)
    tree.allow("reusable-old.yml")
    assert_that(tree.run(baseline=["reusable-old.yml"])).is_empty()

    tree.workflow("reusable-new.yml", UNCONVERTED)
    tree.allow("reusable-new.yml", "reusable-old.yml")

    assert_that(tree.run(baseline=["reusable-old.yml"])).is_equal_to(
        [
            NOT_IN_BASELINE.format("reusable-new.yml"),
        ],
    )


def test_allowlist_entry_cannot_be_swapped(tree: Tree) -> None:
    """Converting one reusable does not make room for a new unconverted one."""
    tree.workflow("reusable-old.yml", CONVERTED)
    tree.workflow("reusable-new.yml", UNCONVERTED)
    tree.allow("reusable-new.yml")

    assert_that(tree.run(baseline=["reusable-old.yml"])).is_equal_to(
        [
            "tooling-token-allowlist.txt:1: " + NOT_LISTED.format("reusable-old.yml"),
            NOT_IN_BASELINE.format("reusable-new.yml"),
        ],
    )


def test_baseline_cannot_keep_a_removed_name(tree: Tree) -> None:
    """A slice that removes an entry removes its name from the baseline too."""
    tree.workflow("reusable-old.yml", UNCONVERTED)
    tree.allow("reusable-old.yml")

    assert_that(
        tree.run(baseline=["reusable-gone.yml", "reusable-old.yml"]),
    ).is_equal_to(
        ["tooling-token-allowlist.txt:1: " + NOT_LISTED.format("reusable-gone.yml")],
    )


def test_main_applies_the_committed_baseline(
    tree: Tree,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Without ``--baseline`` the command line uses the committed names."""
    tree.workflow("reusable-old.yml", UNCONVERTED)
    tree.allow("reusable-old.yml")
    args = [
        "--workflows-dir",
        str(tree.workflows),
        "--actions-dir",
        str(tree.actions),
        "--allowlist",
        str(tree.allowlist),
    ]

    code = tree.validator.main(args)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        NOT_IN_BASELINE.format("reusable-old.yml"),
    )
    code = tree.validator.main([*args, "--baseline", "reusable-old.yml"])
    assert_that(code).is_equal_to(0)


def test_committed_baseline_is_the_committed_allowlist(
    validator: ModuleType,
) -> None:
    """The constant and the list move together in every slice."""
    lines = ALLOWLIST.read_text().splitlines()
    entries = [line for line in lines if line and not line.startswith("#")]

    assert_that(sorted(validator.ALLOWLIST_BASELINE)).is_equal_to(entries)


def test_allowlisted_checkout_may_not_misuse_the_token(tree: Tree) -> None:
    """The allowlist waives a missing token, never a misused one."""
    text = UNCONVERTED.replace(
        PERSIST,
        f"          token: {EXPR}\n          persist-credentials: true\n",
    )
    tree.workflow("reusable-unconverted.yml", text)
    tree.allow("reusable-unconverted.yml")

    assert_that(tree.run()).is_equal_to(
        [
            f"reusable-unconverted.yml:13: [token] `token` must be exactly "
            f"`{FALLBACK}`, found `{EXPR}`",
            "reusable-unconverted.yml:14: [token] `persist-credentials` must be "
            "exactly `false`, found `true`",
        ],
    )


@pytest.mark.parametrize(
    ("old", "new", "expected"),
    [
        pytest.param(
            PERSIST,
            TOKEN + "          persist-credentials: true\n",
            "reusable-unconverted.yml:14: [token] `persist-credentials` must be "
            "exactly `false`, found `true`",
            id="exact-token-persisted",
        ),
        pytest.param(
            PERSIST,
            TOKEN,
            "reusable-unconverted.yml:10: [token] missing `persist-credentials: false`",
            id="exact-token-persist-absent",
        ),
        pytest.param(
            "          tooling-ref: abc\n",
            f"          tooling-token: {FALLBACK}\n",
            "reusable-unconverted.yml:17: [composite-call] `tooling-token` must be "
            f"exactly `{EXPR}`, found `{FALLBACK}`",
            id="composite-call-other-expression",
        ),
        pytest.param(
            "          tooling-ref: abc\n",
            f"          tooling-ref: {EXPR}\n",
            f"reusable-unconverted.yml:17: {NAME_LEAK}",
            id="exact-text-wrong-place",
        ),
    ],
)
def test_allowlisted_file_is_exempt_by_text_and_place_together(
    tree: Tree,
    old: str,
    new: str,
    expected: str,
) -> None:
    """A place that may hold the secret is checked for what it says, in every file."""
    assert_that(UNCONVERTED).contains(old)
    tree.workflow("reusable-unconverted.yml", UNCONVERTED.replace(old, new))
    tree.allow("reusable-unconverted.yml")

    found = tree.run()

    assert_that(found).is_length(1)
    assert_that(found[0]).starts_with(expected)


@pytest.mark.parametrize(
    "read",
    [
        "${{ format('}}{0}', toJSON(inputs)) }}",
        "x }} ${{ toJSON(inputs) }}",
        "${{ format('{0}', inputs) }}",
        "${{ inputs[inputs.name] }}",
        "${{ inputs['tooling-ref'] }} ${{ inputs.TOOLING-TOKEN }}",
        "${{ format('{0}', 'inputs.tooling-token') }}",
    ],
)
def test_composite_scalar_is_searched_as_a_whole(tree: Tree, read: str) -> None:
    """Rule f: no quote and no ``}}`` hides a read of the inputs context."""
    old = "      shell: bash\n"
    tree.composite(COMPOSITE.replace(old, f"{old}      env:\n        T: {read}\n"))

    assert_that(tree.run()).is_equal_to(
        [
            "checkout-and-harden/action.yml:23: [composite] only the tooling "
            "checkout's `token:` may read inputs.tooling-token",
        ],
    )


def test_composite_may_read_other_inputs_by_name(tree: Tree) -> None:
    """Rule f: another input by property or by a literal index is left alone."""
    old = "      shell: bash\n"
    env = "      env:\n        T: ${{ inputs['tooling-ref'] || inputs.tooling-ref }}\n"
    tree.composite(COMPOSITE.replace(old, old + env))

    assert_that(tree.run()).is_empty()


EVIL_ACTION = "evil/repo/.github/actions/checkout-and-harden@main"
EVIL_WORKFLOW = "evil/repo/.github/workflows/reusable-semantic-pr-title.yml@main"
ABSENT = "./.github/workflows/reusable-absent.yml"


@pytest.mark.parametrize("allowlisted", [False, True])
def test_secret_to_a_composite_of_another_repository_fails(
    tree: Tree,
    allowlisted: bool,
) -> None:
    """A basename is not an identity: only the staged composite takes the secret."""
    body = (
        GOOD_CHECKOUT
        + f"      - uses: {EVIL_ACTION}\n"
        + f"        with:\n          tooling-token: {EXPR}\n"
    )
    tree.workflow("reusable-shape.yml", shape(body))
    tree.allow(*(["reusable-shape.yml"] if allowlisted else []))

    found = tree.run()

    assert_that(found).is_length(1 if allowlisted else 2)
    assert_that(found[-1]).starts_with(f"reusable-shape.yml:19: {NAME_LEAK}")
    if not allowlisted:
        assert_that(found[0]).is_equal_to(
            f"reusable-shape.yml:17: {NOT_STAGED.format(EVIL_ACTION)}",
        )


@pytest.mark.parametrize("allowlisted", [False, True])
def test_secret_to_a_remote_workflow_is_a_leak(tree: Tree, allowlisted: bool) -> None:
    """A local file with the same basename does not vouch for a remote call."""
    job = f"  inner:\n    uses: {EVIL_WORKFLOW}\n    secrets:\n{NESTED_SECRET}"
    tree.workflow("reusable-semantic-pr-title.yml", CONVERTED)
    tree.workflow("reusable-shape.yml", shape(job, head=WRAPPER_HEAD))
    tree.allow(*(["reusable-shape.yml"] if allowlisted else []))

    found = [text for text in tree.run() if "[allowlist]" not in text]

    assert_that(found).is_equal_to(
        [
            "reusable-shape.yml:12: [leak] forwards LGTM_CI_TOOLING_TOKEN to "
            f"`{EVIL_WORKFLOW}`, which is not a `./.github/workflows/<file>` of this "
            "repository",
        ],
    )


@pytest.mark.parametrize(
    ("job", "expected"),
    [
        pytest.param(
            f"  inner:\n    uses: {ABSENT}\n    secrets:\n{NESTED_SECRET}",
            "reusable-shape.yml:12: [forward] forwards LGTM_CI_TOOLING_TOKEN to "
            "reusable-absent.yml, which does not exist",
            id="forwarded-to-a-missing-file",
        ),
        pytest.param(
            f"  inner:\n    uses: {ABSENT}\n",
            f"reusable-shape.yml:10: [unclassified] `uses: {ABSENT}` does not exist, "
            "so whether it takes LGTM_CI_TOOLING_TOKEN cannot be checked; in a file "
            "that names the secret a nested call must be "
            "`./.github/workflows/<file>`",
            id="missing-file",
        ),
    ],
)
@pytest.mark.parametrize("allowlisted", [False, True])
def test_unresolved_nested_call_fails_in_a_file_that_names_the_secret(
    tree: Tree,
    job: str,
    expected: str,
    allowlisted: bool,
) -> None:
    """A target that cannot be read is an error, not "does not take the secret"."""
    tree.workflow("reusable-shape.yml", shape(job, head=WRAPPER_HEAD))
    tree.allow(*(["reusable-shape.yml"] if allowlisted else []))

    found = [text for text in tree.run() if "[allowlist]" not in text]

    assert_that(found).is_equal_to([expected])


OTHER_COMPOSITE = f"""---
name: Other
inputs:
  path:
    default: ""
runs:
  using: composite
  steps:
    - uses: actions/checkout@{SHA}
      with:
        path: PATH
        persist-credentials: false
"""
OTHER_TOOLING = (
    f"[composite] `uses: actions/checkout@{SHA}` has `path: .lgtm-ci-tooling`; only "
    "checkout-and-harden may check out the tooling"
)


def other_composite(tree: Tree, name: str, text: str) -> None:
    """Write a composite other than ``checkout-and-harden``."""
    target = tree.actions / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


@pytest.mark.parametrize(
    ("name", "text", "expected"),
    [
        pytest.param(
            "stage/action.yml",
            OTHER_COMPOSITE.replace("PATH", ".lgtm-ci-tooling"),
            f"stage/action.yml:9: {OTHER_TOOLING}",
            id="tooling-checkout",
        ),
        pytest.param(
            "stage/action.yaml",
            OTHER_COMPOSITE.replace("PATH", "./.LGTM-CI-TOOLING/"),
            f"stage/action.yaml:9: {OTHER_TOOLING}",
            id="yaml-extension",
        ),
        pytest.param(
            "group/stage/action.yml",
            OTHER_COMPOSITE.replace("PATH", ".lgtm-ci-tooling"),
            f"group/stage/action.yml:9: {OTHER_TOOLING}",
            id="nested-directory",
        ),
        pytest.param(
            "stage/action.yml",
            OTHER_COMPOSITE.replace("PATH", "${{ inputs.dir }}"),
            "stage/action.yml:11: [composite] checkout `path: ${{ inputs.dir }}` "
            "cannot be told apart from .lgtm-ci-tooling; write the path so that its "
            "last component is a literal",
            id="expression-path",
        ),
        pytest.param(
            "stage/action.yml",
            OTHER_COMPOSITE.replace("PATH", "${{ inputs.path }}").replace(
                '    default: ""',
                "    default: .lgtm-ci-tooling",
            ),
            "stage/action.yml:11: [composite] checkout `path: ${{ inputs.path }}` "
            "cannot be told apart from .lgtm-ci-tooling; write the path so that its "
            "last component is a literal",
            id="pass-through-with-tooling-default",
        ),
        pytest.param(
            "stage/action.yml",
            "runs: [unterminated\n",
            "stage/action.yml:2: [composite] not valid YAML:",
            id="unparseable",
        ),
    ],
)
def test_other_composite_may_not_check_out_the_tooling(
    tree: Tree,
    name: str,
    text: str,
    expected: str,
) -> None:
    """Every composite is read; only ``checkout-and-harden`` stages the tooling."""
    other_composite(tree, name, text)

    found = tree.run()

    assert_that(found).is_length(1)
    assert_that(found[0]).starts_with(expected)


@pytest.mark.parametrize(
    "path",
    ["${{ inputs.path }}", "elsewhere", "${{ runner.temp }}/report"],
)
def test_other_composite_may_check_out_elsewhere(tree: Tree, path: str) -> None:
    """A path that is not the tooling directory, or the caller's own, passes."""
    other_composite(tree, "stage/action.yml", OTHER_COMPOSITE.replace("PATH", path))

    assert_that(tree.run()).is_empty()


DEEP_FLOW = "[" * 50_000
EMPTY_FILE = "[yaml] the file is empty, so it is not a reusable workflow"
DEEP_BLOCK = "".join(f"{'  ' * level}a:\n" for level in range(200))


@pytest.mark.parametrize(
    ("name", "content", "expected"),
    [
        pytest.param(
            "callable.yml",
            b"[\n",
            "callable.yml:2: [yaml] not valid YAML:",
            id="unparseable-under-another-name",
        ),
        pytest.param(
            "callable.yml",
            DEEP_FLOW.encode(),
            "callable.yml:1: [yaml] not valid YAML: nested too deeply to be parsed",
            id="deep-flow",
        ),
        pytest.param(
            "callable.yml",
            DEEP_BLOCK.encode(),
            "callable.yml:65: [yaml] nested more than 64 levels deep",
            id="deep-block",
        ),
        pytest.param(
            "callable.yml",
            b"\xff\xfe",
            "callable.yml:1: [yaml] cannot be read:",
            id="not-text",
        ),
        pytest.param(
            "reusable-empty.yml",
            b"",
            f"reusable-empty.yml:1: {EMPTY_FILE}",
            id="empty-reusable",
        ),
        pytest.param(
            "reusable-empty.yml",
            b"# nothing yet\n",
            f"reusable-empty.yml:1: {EMPTY_FILE}",
            id="comment-only-reusable",
        ),
        pytest.param(
            "reusable-list.yml",
            b"- name: Not a workflow\n",
            "reusable-list.yml:1: [yaml] the top level is not a mapping",
            id="reusable-not-a-mapping",
        ),
    ],
)
def test_file_that_cannot_be_read_fails_before_it_is_filtered(
    tree: Tree,
    capsys: pytest.CaptureFixture[str],
    name: str,
    content: bytes,
    expected: str,
) -> None:
    """A parse failure or an empty reusable exits 1 with a message, no traceback."""
    (tree.workflows / name).write_bytes(content)

    found = tree.run()
    code = tree.validator.main(
        [
            "--workflows-dir",
            str(tree.workflows),
            "--actions-dir",
            str(tree.actions),
            "--baseline",
        ],
    )

    assert_that(found).is_length(1)
    assert_that(found[0]).starts_with(expected)
    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(expected)


def test_empty_file_under_another_name_is_not_a_reusable(tree: Tree) -> None:
    """An empty file that is not named ``reusable-*`` cannot be called."""
    tree.workflow("ci.yml", "")

    assert_that(tree.run()).is_empty()


def test_repeated_trigger_key_does_not_hide_a_reusable(tree: Tree) -> None:
    """Every ``on`` key is read, so a first ``on: push`` hides nothing."""
    text = UNCONVERTED.replace("on:\n", "on: push\non:\n")
    tree.workflow("called.yml", text)

    found = "\n".join(tree.run())

    assert_that(found).contains("called.yml:4: [yaml] key `on` is repeated")
    assert_that(found).contains(f"called.yml:11: {MISSING_TOKEN}")


def test_unclassified_caller_checkout_is_reported_once(tree: Tree) -> None:
    """A path that cannot be classified is not also called a use of the token."""
    path = "${{ inputs.working-directory }}"
    body = (
        f"      - uses: actions/checkout@{SHA}\n"
        f"        with:\n          path: {path}\n          persist-credentials: false\n"
    )
    tree.workflow("reusable-shape.yml", shape(body, head=UNDECLARED_HEAD))

    assert_that(tree.run()).is_equal_to(
        [
            f"reusable-shape.yml:11: {UNCLASSIFIED_PATH}{path}` cannot be told "
            "apart from .lgtm-ci-tooling; write the path so that its last "
            "component is a literal",
        ],
    )
