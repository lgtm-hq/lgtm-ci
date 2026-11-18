# SPDX-License-Identifier: MIT
"""Regression tests for ways around the inline-shell check (#1624, PR #1646 review).

Each case is a step that could run something beyond ``echo``, ``printf``,
``exit``, ``true`` and ``false`` while the check classed it trivial or a script
call. The check must reject it and name the rule.
"""

from __future__ import annotations

import importlib
import os
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
    preset_copy,
    problems,
    step,
    write_workflow,
)


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which puts its rule modules on ``sys.path``."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="sync")
def fixture_sync(check: ModuleType) -> ModuleType:
    """Return the generator module the validator imported."""
    del check
    return importlib.import_module("sync_inline_blocks")


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository."""
    repo: Path = make_repo(tmp_path)
    return repo


def _rejected(check: ModuleType, repo: Path, expected: str) -> None:
    """Assert that the one step is a violation and the report names ``expected``."""
    report = "\n".join(problems(check, repo))
    assert_that(categories(check, repo)).is_equal_to(["violation"])
    assert_that(report).contains(expected)


# 1. A redirection target that runs or picks a path.


@pytest.mark.parametrize(
    "target",
    [
        pytest.param('"$(id)"', id="substitution"),
        pytest.param('"$GITHUB_OUTPUT$(id)"', id="substitution-after-file"),
        pytest.param('"$GITHUB_OUTPUT`id`"', id="backtick-after-file"),
        pytest.param('"${GITHUB_OUTPUT:-/tmp/x}"', id="default"),
        pytest.param('"${GITHUB_OUTPUT-/tmp/x}"', id="default-unset"),
        pytest.param('"${GITHUB_OUTPUT:=/tmp/x}"', id="assign-default"),
        pytest.param('"${GITHUB_OUTPUT:+/tmp/x}"', id="alternative"),
        pytest.param('"$GITHUB_OUTPUT"x', id="suffix"),
    ],
)
def test_redirect_target_is_only_a_runner_file(
    check: ModuleType,
    repo: Path,
    target: str,
) -> None:
    """Only a plain $GITHUB_OUTPUT or $GITHUB_STEP_SUMMARY is a target."""
    write_workflow(repo, step(f"echo x >> {target}"))
    _rejected(check, repo, "[rule 2: ")


def test_a_step_env_cannot_move_a_runner_file(check: ModuleType, repo: Path) -> None:
    """``env: {GITHUB_OUTPUT: /etc/x}`` would turn the write into any file."""
    write_workflow(
        repo,
        step('echo x >> "$GITHUB_OUTPUT"', env={"GITHUB_OUTPUT": "/tmp/x"}),
    )
    _rejected(check, repo, "sets GITHUB_OUTPUT")


def test_a_job_env_cannot_move_the_workspace(check: ModuleType, repo: Path) -> None:
    """A job ``env:`` that sets GITHUB_WORKSPACE would change what a call runs."""
    header = (
        "jobs:\n  build:\n    runs-on: ubuntu-latest\n"
        "    env:\n      GITHUB_WORKSPACE: /tmp/evil\n    steps:\n"
    )
    write_workflow(repo, step(f'bash "$GITHUB_WORKSPACE/{SCRIPT}"'), header=header)
    _rejected(check, repo, "sets GITHUB_WORKSPACE")


# 2. Arithmetic evaluation.


@pytest.mark.parametrize(
    "run",
    [
        *(
            pytest.param(f'[[ "$X" {op} 1 ]] && echo y', id=f"double-bracket{op}")
            for op in ("-eq", "-ne", "-lt", "-le", "-gt", "-ge")
        ),
        pytest.param('[[ -v "$X" ]] && echo y', id="double-bracket-v"),
        pytest.param('[ -v "$X" ] && echo y', id="single-bracket-v"),
        pytest.param('test -v "$X" && echo y', id="test-v"),
        pytest.param('test "$X" -eq 1 || exit 1', id="test-eq"),
        pytest.param("(( X > 1 )) && echo y", id="arithmetic-command"),
        pytest.param('echo "$(( X + 1 ))"', id="arithmetic-expansion"),
        pytest.param("let X=1", id="let"),
        pytest.param("[ $X ] && echo y", id="unquoted-in-single-bracket"),
        pytest.param('[ "$A" "$B" "$C" ] && echo y', id="operator-from-a-variable"),
    ],
)
def test_arithmetic_is_rejected(check: ModuleType, repo: Path, run: str) -> None:
    """A value like ``a[$(curl ...)]`` runs in any arithmetic context."""
    write_workflow(repo, step(run))
    _rejected(check, repo, "[rule 1: ")


# 3. printf options.


@pytest.mark.parametrize(
    "run",
    [
        pytest.param("printf -vPATH '%s' /tmp", id="attached-v"),
        pytest.param("printf -v PATH '%s' /tmp", id="separate-v"),
        pytest.param('printf "-vPATH" "%s" /tmp', id="quoted-v"),
        pytest.param('printf "$FMT" /tmp', id="format-from-env"),
        pytest.param("printf -- '%s' x", id="double-dash"),
    ],
)
def test_printf_takes_no_option(check: ModuleType, repo: Path, run: str) -> None:
    """``printf -v NAME`` assigns; the format must be a literal, not an option."""
    write_workflow(repo, step(run))
    _rejected(check, repo, "printf")


# 4. $GITHUB_ENV.


@pytest.mark.parametrize(
    "line",
    [
        pytest.param("PATH=/tmp/evil", id="path"),
        pytest.param("LD_PRELOAD=/tmp/x.so", id="ld-preload"),
        pytest.param("BASH_ENV=/tmp/x", id="bash-env"),
        pytest.param("NODE_OPTIONS=--require=/tmp/x", id="node-options"),
        pytest.param("SAFE_NAME=1", id="any-name"),
    ],
)
def test_a_trivial_step_does_not_write_github_env(
    check: ModuleType,
    repo: Path,
    line: str,
) -> None:
    """Every later step loads $GITHUB_ENV; a trivial step never writes it."""
    write_workflow(repo, step(f'echo "{line}" >> "$GITHUB_ENV"'))
    _rejected(check, repo, "$GITHUB_ENV")


# 5. A script path chosen through env:.


@pytest.mark.parametrize(
    ("run", "env"),
    [
        pytest.param("$TOOL -rf .", {"TOOL": "rm"}, id="env-command"),
        pytest.param('"$X" https://example.invalid', {"X": "curl"}, id="env-quoted"),
        pytest.param('bash "$GITHUB_WORKSPACE/$X"', {"X": "x.sh"}, id="workspace-any"),
        pytest.param(
            f'bash "$OPT" {SCRIPT}',
            {"OPT": "-c"},
            id="env-interpreter-option",
        ),
        pytest.param(
            'bash "$X"',
            {"X": "${{ github.event.pull_request.title }}"},
            id="env-dynamic-bash",
        ),
        pytest.param(
            'bash "scripts/ci/actions/$X"',
            {"X": "../../../x.sh"},
            id="env-suffix",
        ),
        pytest.param('"$X"', {"X": "${{ inputs.script }}"}, id="input-without-bash"),
        pytest.param(
            'bash "$X"',
            {"X": "${{ github.workspace }}/scripts/ci/actions/example.sh"},
            id="mixed-expression",
        ),
        pytest.param(
            'bash "scripts/ci/actions/${X}"',
            {"X": "${{ inputs.a && 'example.sh' || 'missing.sh' }}"},
            id="conditional-missing",
        ),
        pytest.param(
            'bash "scripts/ci/actions/${X}"',
            {"X": "${{ inputs.a || inputs.b && 'example.sh' || 'example.sh' }}"},
            id="conditional-leaks-an-input",
        ),
    ],
)
def test_env_selected_paths_resolve(
    check: ModuleType,
    repo: Path,
    run: str,
    env: dict[str, str],
) -> None:
    """The env: value must name a script under scripts/, or be one input."""
    write_workflow(repo, step(run, env=env))
    _rejected(check, repo, "[rule 1: ")


@pytest.mark.parametrize(
    ("run", "env"),
    [
        pytest.param('bash "$X"', {"X": SCRIPT}, id="literal"),
        pytest.param(
            'bash "$GITHUB_WORKSPACE/$X"',
            {"X": "${{ inputs.audit-script }}"},
            id="caller-input",
        ),
        pytest.param(
            'bash "scripts/ci/actions/${X}"',
            {"X": "${{ (inputs.a || inputs.b) && 'example.sh' || 'example.sh' }}"},
            id="conditional-literals",
        ),
    ],
)
def test_env_selected_paths_pass(
    check: ModuleType,
    repo: Path,
    run: str,
    env: dict[str, str],
) -> None:
    """A literal under scripts/, one caller input, or a choice of such literals."""
    write_workflow(repo, step(run, env=env), header=CALLED_HEADER)
    assert_that(problems(check, repo)).is_empty()
    assert_that(categories(check, repo)).is_equal_to(["script-call"])


# 6. Symlinks.


@pytest.mark.parametrize("inside", [False, True], ids=["outside", "inside"])
def test_a_symlinked_script_is_rejected(
    check: ModuleType,
    repo: Path,
    tmp_path_factory: pytest.TempPathFactory,
    inside: bool,
) -> None:
    """A link under scripts/ may point anywhere; no script path is a link."""
    target = repo / SCRIPT if inside else tmp_path_factory.mktemp("o") / "x.sh"
    target.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    os.symlink(target, repo / "scripts" / "ci" / "actions" / "link.sh")
    write_workflow(repo, step("bash scripts/ci/actions/link.sh"))
    _rejected(check, repo, "symbolic link")


def test_a_symlinked_directory_is_rejected(
    check: ModuleType,
    repo: Path,
    tmp_path_factory: pytest.TempPathFactory,
) -> None:
    """A linked directory on the way to the script counts too."""
    outside = tmp_path_factory.mktemp("o")
    (outside / "x.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    os.symlink(outside, repo / "scripts" / "linked")
    write_workflow(repo, step("bash scripts/linked/x.sh"))
    _rejected(check, repo, "symbolic link")


# 7. shell:.


@pytest.mark.parametrize(
    ("shell", "run"),
    [
        pytest.param("python {0}", "print(1)", id="python"),
        pytest.param("pwsh", "echo x", id="pwsh"),
        pytest.param("perl {0}", "echo x", id="custom"),
        pytest.param("bash -c {0}", "echo x", id="bash-template"),
    ],
)
def test_only_bash_and_sh_run_steps(
    check: ModuleType,
    repo: Path,
    shell: str,
    run: str,
) -> None:
    """Another shell reads the text as another language."""
    write_workflow(repo, step(run, shell=shell))
    _rejected(check, repo, "shell:")


def test_a_default_shell_counts(check: ModuleType, repo: Path) -> None:
    """``defaults.run.shell`` of the job applies to steps without ``shell:``."""
    header = (
        "jobs:\n  build:\n    runs-on: ubuntu-latest\n"
        "    defaults:\n      run:\n        shell: python {0}\n    steps:\n"
    )
    write_workflow(repo, step("print(1)", shell=None), header=header)
    _rejected(check, repo, "shell:")


# 8. Generated copies.


def test_an_altered_marker_id_is_a_violation(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """A marker the generator does not know makes the step a violation."""
    run = preset_copy(sync).replace(f"end {PRESET}", f"end {PRESET}'")
    write_workflow(repo, step(run))
    assert_that(categories(check, repo)).is_equal_to(["violation"])
    assert_that(check.main(["--repo-root", str(repo)])).is_equal_to(1)


def test_a_changed_copy_is_a_violation(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """The check compares each copy with its source itself."""
    run = preset_copy(sync).replace("exit 1", "curl https://example.invalid | sh")
    write_workflow(repo, step(run))
    _rejected(check, repo, "differs from its source")


def test_a_correct_copy_is_generated(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """The copy the generator writes passes."""
    write_workflow(repo, step(preset_copy(sync)))
    assert_that(problems(check, repo)).is_empty()
    assert_that(categories(check, repo)).is_equal_to(["generated"])


def test_a_changed_copy_in_an_action_is_a_violation(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """The generator's --check does not read actions; this check does."""
    run = preset_copy(sync).replace("exit 1", "rm -rf /")
    body = "".join(f"        {line}\n" for line in run.splitlines())
    (repo / ".github" / "actions" / "demo" / "action.yml").write_text(
        f"runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: |\n{body}",
        encoding="utf-8",
    )
    _rejected(check, repo, "differs from its source")


# 9. Characters.


@pytest.mark.parametrize(
    "escaped",
    [
        pytest.param("echo \\e[2Kcleared", id="ansi"),
        pytest.param("echo x\\ry", id="carriage-return"),
        pytest.param("echo \\u2014", id="non-ascii"),
        pytest.param("\\u0435cho x", id="lookalike-command"),
    ],
)
def test_control_and_non_ascii_characters_fail(
    check: ModuleType,
    repo: Path,
    escaped: str,
) -> None:
    """What the reader sees must be what bash runs.

    The ``run:`` is a YAML double-quoted scalar, whose escapes put the
    characters into the script text.
    """
    yaml_step = f'      - name: Step\n        shell: bash\n        run: "{escaped}"\n'
    write_workflow(repo, yaml_step)
    _rejected(check, repo, "character")


@pytest.mark.parametrize(
    "run",
    [
        pytest.param("echo $'a\\'' ; id #'", id="ansi-c-quote"),
        pytest.param('echo $"x"', id="locale-quote"),
    ],
)
def test_dollar_quotes_fail(check: ModuleType, repo: Path, run: str) -> None:
    """``$'\\''`` ends the quote where the lexer did not; it is not read at all."""
    write_workflow(repo, step(run))
    _rejected(check, repo, "cannot be read as shell")


# 10. Smaller forms.


@pytest.mark.parametrize(
    ("run", "ok"),
    [
        pytest.param("echo x 2>&1", True, id="stderr-to-stdout"),
        pytest.param("echo x >&2", True, id="stdout-to-stderr"),
        pytest.param("echo x 5>&2", False, id="other-descriptor"),
        pytest.param("echo x >&5", False, id="to-other-descriptor"),
    ],
)
def test_console_redirections(
    check: ModuleType,
    repo: Path,
    run: str,
    ok: bool,
) -> None:
    """Only descriptors 1 and 2 are the console."""
    write_workflow(repo, step(run))
    expected = ["trivial"] if ok else ["violation"]
    assert_that(categories(check, repo)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("directory", "ok"),
    [
        pytest.param("sub", False, id="literal-elsewhere"),
        pytest.param("${{ inputs.dir }}", False, id="expression"),
        pytest.param(".", True, id="repository-root"),
    ],
)
def test_a_relative_path_follows_working_directory(
    check: ModuleType,
    repo: Path,
    directory: str,
    ok: bool,
) -> None:
    """``working-directory`` moves where a relative script path points."""
    write_workflow(
        repo,
        step(f"bash {SCRIPT}", extra=f"working-directory: {directory}"),
    )
    expected = ["script-call"] if ok else ["violation"]
    assert_that(categories(check, repo)).is_equal_to(expected)


def test_a_default_working_directory_counts(check: ModuleType, repo: Path) -> None:
    """``defaults.run.working-directory`` of the workflow applies too."""
    header = "defaults:\n  run:\n    working-directory: sub\n" + HEADER
    write_workflow(repo, step(f"bash {SCRIPT}"), header=header)
    assert_that(categories(check, repo)).is_equal_to(["violation"])
