# SPDX-License-Identifier: MIT
"""Tests for the tooling token contract of the reusable workflows (#1451)."""

from collections.abc import Callable
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

    def run(self) -> list[str]:
        """Validate the tree.

        Returns:
            list[str]: The rendered violations.
        """
        findings, _, _ = self.validator.validate(
            workflows_dir=self.workflows,
            actions_dir=self.actions,
            allowlist=self.allowlist if self.allowlist.is_file() else None,
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
    tree.workflow("ci.yml", UNCONVERTED)
    tree.allow("reusable-unconverted.yml")

    assert_that(tree.run()).is_empty()


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
            "[leak] toJSON(secrets) would expose the tooling token",
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
            "reusable-wrapper.yml:12: [forward] `secrets: inherit` is not accepted; "
            "forward LGTM_CI_TOOLING_TOKEN to reusable-converted.yml",
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
        ["--workflows-dir", str(tree.workflows), "--actions-dir", str(tree.actions)],
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
    assert_that(report.conversion + report.leaks).is_empty()
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
