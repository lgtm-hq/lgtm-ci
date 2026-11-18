# SPDX-License-Identifier: MIT
# pylint: disable=too-many-lines  # One case per rule and form; split files would hide gaps.
"""Tests for the inline-shell check (#1624).

``scripts/ci/quality/validate_inline_shell.py`` classifies every ``run:`` step
of the workflows and composite actions; ``inline_shell_rules.py`` holds the
definitions and ``inline_shell_lexer.py`` reads the shell. The CI job
``🐚 Inline Shell`` runs the check on the repository; so does
:func:`test_repository_passes`. It replaces the ``ALLOWED`` ratchet of
``test_inline_run_blocks.py`` (#1450): a hand-written step is now judged by
rule, not listed.
"""

from __future__ import annotations

import importlib
import shutil
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from inline_shell_support import (
    CALLED_HEADER,
    HEADER,
    PRESET,
    ROOT,
    SCRIPT,
    SCRIPT_PATH,
    categories,
    make_repo,
    preset_copy,
    problems,
    step,
    write_workflow,
)

MINT = "tooling-app-mint"


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which puts its rule modules on ``sys.path``."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="rules")
def fixture_rules(check: ModuleType) -> ModuleType:
    """Return the rules module the validator imported."""
    del check
    return importlib.import_module("inline_shell_rules")


@pytest.fixture(name="denylist")
def fixture_denylist(check: ModuleType) -> ModuleType:
    """Return the deny-list module the validator imported."""
    del check
    return importlib.import_module("inline_shell_denylist")


@pytest.fixture(name="sync")
def fixture_sync(check: ModuleType) -> ModuleType:
    """Return the generator module the validator imported."""
    del check
    return importlib.import_module("sync_inline_blocks")


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository with one script and one action script."""
    repo: Path = make_repo(tmp_path)
    return repo


# The repository itself.


def test_repository_passes(check: ModuleType) -> None:
    """Every run: step in the repository is a script call, generated or trivial."""
    steps, errors = check.check(ROOT)
    assert_that(check.report(steps, errors)).is_empty()
    pairs = [line.split(": ") for line in check.summary(steps)]
    counts = {name: int(count) for name, count in pairs}
    assert_that(counts["violation"]).is_equal_to(0)
    assert_that(counts["generated"]).is_greater_than(0)
    assert_that(counts["trivial"]).is_greater_than(0)


def test_no_hand_written_step_holds_an_expression(check: ModuleType) -> None:
    """Acceptance (#1624): no inline step reads ${{ }} in its script text."""
    steps, _ = check.check(ROOT)
    assert_that([s for s in steps if "${{" in s.run]).is_empty()


def test_cli_passes_on_the_repository(
    check: ModuleType,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``main`` exits 0 and prints the counts with --summary."""
    assert_that(check.main(["--summary"])).is_equal_to(0)
    out = capsys.readouterr().out
    assert_that(out).contains("script-call: ").contains("total: ").contains("OK:")


# Acceptance cases: a one-line step outside the allow-list is rejected.


@pytest.mark.parametrize(
    ("run", "expected"),
    [
        pytest.param("rm -rf .", "[rule 1: ", id="rm-rf"),
        pytest.param(
            "curl -sSfL -o x https://example.invalid/x",
            "runs `curl`",
            id="download",
        ),
        pytest.param("wget https://example.invalid/x", "runs `wget`", id="wget"),
        pytest.param("echo hi | tee x", "a pipe", id="pipe"),
        pytest.param('echo "$(id)"', "command substitution $(...)", id="dollar-paren"),
        pytest.param("echo `id`", "command substitution backtick", id="backtick"),
        pytest.param(
            "echo $((1 + 2))",
            "command substitution $((...))",
            id="arithmetic",
        ),
        pytest.param('eval "$X"', "runs `eval`", id="eval"),
        pytest.param("source ./x.sh", "runs `source`", id="source"),
        pytest.param("export TOKEN=x", "runs `export`", id="export"),
        pytest.param("TOKEN=x", "assigns TOKEN", id="assignment"),
        pytest.param("echo x > /tmp/token", "[rule 2: ", id="redirect-file"),
        pytest.param('echo x >> "$GITHUB_PATH"', "[rule 2: ", id="github-path"),
        pytest.param("cat < /etc/passwd", "runs `cat`", id="input"),
        pytest.param("for x in a b; do echo $x; done", "a loop", id="loop"),
        pytest.param("f() { echo; }", "a function", id="function"),
        pytest.param("echo x &", "a background job", id="background"),
        pytest.param("(echo x)", "a subshell", id="subshell"),
        pytest.param(
            '"$CMD"',
            "not a script call: path starts with $CMD",
            id="variable-command",
        ),
        pytest.param("echo ${X//a/b}", "expansion ${X//a/b}", id="pattern-expansion"),
        pytest.param("echo ${X:=y}", "expansion ${X:=y}", id="assign-expansion"),
        pytest.param("printf -v x y", "printf takes no option", id="printf-v"),
        pytest.param("if [[ -f x ]]; then echo; fi", "test `-f`", id="file-test"),
        pytest.param(
            'echo "A=1" >>"${GITHUB_ENV}"',
            "writes $GITHUB_ENV",
            id="env-file",
        ),
        pytest.param("echo 'unclosed", "cannot be read as shell", id="unclosed"),
        pytest.param(
            "diff <(echo a) <(echo b)",
            "cannot be read as shell",
            id="process-sub",
        ),
    ],
)
def test_one_line_outside_the_allow_list_fails(
    check: ModuleType,
    repo: Path,
    run: str,
    expected: str,
) -> None:
    """Each harmful or non-trivial one-liner names the rule it breaks."""
    write_workflow(repo, step(run))

    report = problems(check, repo)
    assert_that(report).is_not_empty()
    assert_that("\n".join(report)).contains(expected)
    assert_that(report[0]).starts_with(".github/workflows/w.yml:")
    assert_that(report[0]).contains(" build / Step: [")


def test_an_expression_fails_rule_3(check: ModuleType, repo: Path) -> None:
    """A ${{ }} in the script text is rule 3, even in a script call."""
    write_workflow(
        repo,
        step('echo "${{ github.event.pull_request.title }}"', name="Title"),
        step(f'bash "${{{{ github.workspace }}}}/{SCRIPT}"', name="Call"),
    )

    report = problems(check, repo)
    assert_that(report).is_length(2)
    for line in report:
        assert_that(line).contains(
            "[rule 3: no ${{ }} in the script; values come through env:]",
        )
    assert_that(report[0]).contains("build / Title")
    assert_that(report[1]).contains("build / Call")


def test_an_expression_in_a_generated_block_fails(
    check: ModuleType,
    repo: Path,
) -> None:
    """Rule 3 holds for every inline step, generated copies included."""
    run = (
        f"# lgtm-ci-inline:begin {PRESET}\n"
        "echo ${{ inputs.x }}\n"
        f"# lgtm-ci-inline:end {PRESET}"
    )
    write_workflow(repo, step(run))

    assert_that("\n".join(problems(check, repo))).contains("[rule 3: ")


def test_six_lines_fail_rule_4(check: ModuleType, repo: Path) -> None:
    """Six lines of allowed commands break the line limit."""
    write_workflow(repo, step("\n".join(f'echo "{n}"' for n in range(6))))

    report = problems(check, repo)
    assert_that(report).is_length(1)
    assert_that(report[0]).contains("[rule 4: at most 5 lines of code] 6 lines of code")


def test_five_lines_with_comments_pass(check: ModuleType, repo: Path) -> None:
    """Comments and blank lines are not code."""
    lines = ["# why", *(f'echo "{n}"' for n in range(5)), "", "# done"]
    write_workflow(repo, step("\n".join(lines)))

    assert_that(problems(check, repo)).is_empty()


def test_a_continued_line_counts_per_line(check: ModuleType, repo: Path) -> None:
    """A backslash continuation is still a line a reader has to read."""
    run = "echo a \\\n  b \\\n  c \\\n  d \\\n  e \\\n  f"
    write_workflow(repo, step(run))

    assert_that("\n".join(problems(check, repo))).contains("[rule 4: ")


def test_ten_copies_fail_rule_5(check: ModuleType, repo: Path) -> None:
    """The same trivial text in ten places must become one script."""
    text = 'echo "::error::the same"\nexit 1'
    write_workflow(repo, *(step(text, name=f"S{n}") for n in range(6)), name="a.yml")
    # Indentation and comments do not make a copy differ.
    copies = (step(f"# copy\n{text}\n", name=f"T{n}") for n in range(4))
    write_workflow(repo, *copies, name="b.yml")

    report = problems(check, repo)
    title = "the same text in fewer than 10 places"
    assert_that(report).is_length(10)
    for line in report:
        assert_that(line).contains(f"[rule 5: {title}] the same code is in 10 steps")


def test_nine_copies_pass(check: ModuleType, repo: Path) -> None:
    """Fewer than ten copies is within the limit."""
    write_workflow(repo, *(step("echo same", name=f"S{n}") for n in range(9)))

    assert_that(problems(check, repo)).is_empty()


def test_two_conditionals_fail(check: ModuleType, repo: Path) -> None:
    """At most one if, case or && / || list."""
    run = '[[ "$A" != true ]] || echo "$B"\n[[ "$C" == 0 ]] || echo c\nexit 1'
    write_workflow(repo, step(run))

    assert_that("\n".join(problems(check, repo))).contains("2 conditionals")


def test_nested_if_fails(check: ModuleType, repo: Path) -> None:
    """An if inside an if is two conditionals."""
    run = 'if [[ "$A" ]]; then\n  if [[ "$B" ]]; then echo; fi\nfi'
    write_workflow(repo, step(run))

    assert_that("\n".join(problems(check, repo))).contains("2 conditionals")


def test_case_on_a_compound_subject_fails(check: ModuleType, repo: Path) -> None:
    """A case subject is one plain variable or literal."""
    run = 'case "$A/$B" in\n  x/y) echo ;;\nesac'
    write_workflow(repo, step(run))

    assert_that("\n".join(problems(check, repo))).contains("case on more than one")


# Accepted trivial steps.


@pytest.mark.parametrize(
    "run",
    [
        pytest.param(
            'echo "::warning::Upload failed; the result is unaffected."',
            id="echo",
        ),
        pytest.param('echo "::error::x"; exit 1', id="echo-exit"),
        pytest.param("exit 1", id="exit"),
        pytest.param("true", id="true"),
        pytest.param("printf '%s\\n' \"${MESSAGE}\"\nexit 1", id="printf"),
        pytest.param('echo "a=${A:-none}" >> "$GITHUB_OUTPUT"', id="output"),
        pytest.param('echo "a=${A-none}" >>"${GITHUB_OUTPUT}"', id="output-braced"),
        pytest.param('echo "# Summary" >> "$GITHUB_STEP_SUMMARY"', id="summary"),
        pytest.param('echo "warn" >&2', id="stderr"),
        pytest.param('echo "warn" 1>&2', id="stderr-fd"),
        pytest.param('echo "warn" 2>&1', id="stdout-fd"),
        pytest.param(
            'case "$KIND" in\n  a|b) echo ab ;;\n  *) exit 1 ;;\nesac',
            id="case",
        ),
        pytest.param(
            '[[ "${A}" == "${B}" ]] || { printf "%s\\n" "${C}"; exit 1; }',
            id="and-or-group",
        ),
        pytest.param(
            '[[ -n "$REPO" && "$SHA" =~ ^[0-9a-f]{40}$ ]] && exit 0\n'
            'echo "::error::Immutable workflow identity is required"\nexit 1',
            id="readiness-identity",
        ),
        pytest.param(
            'echo "::error::cannot be enforced on ${RUNNER_OS};" \\\n'
            '  "use another runner"\nexit 1',
            id="continuation",
        ),
        pytest.param('[ "$X" = y ] && echo yes', id="single-bracket"),
        pytest.param('[ -z "$X" ] || echo set', id="single-bracket-unary"),
        pytest.param('test -n "$X" || exit 1', id="test-builtin"),
        pytest.param('[[ "$X" < "$Y" ]] && echo before', id="string-order"),
    ],
)
def test_trivial_steps_pass(check: ModuleType, repo: Path, run: str) -> None:
    """Reporting and stopping on plain variables is trivial."""
    write_workflow(repo, step(run))

    assert_that(problems(check, repo)).is_empty()
    assert_that(categories(check, repo)).is_equal_to(["trivial"])


def test_a_long_allowed_conditional_fails_only_the_line_limit(
    check: ModuleType,
    repo: Path,
) -> None:
    """Eight lines of if/elif/else break rule 4 and nothing else."""
    run = (
        'if [[ "$MODE" == strict ]]; then\n  echo "::error::strict"\n  exit 1\n'
        'elif [[ -n "$WARN" ]]; then\n  echo "::warning::$WARN"\nelse\n  true\nfi'
    )
    write_workflow(repo, step(run))

    report = problems(check, repo)
    assert_that(report).is_length(1)
    assert_that(report[0]).contains("[rule 4: at most 5 lines of code] 8 lines of code")


# Script calls.


@pytest.mark.parametrize(
    ("run", "env"),
    [
        pytest.param(SCRIPT, None, id="repository-relative"),
        pytest.param(f"./{SCRIPT}", None, id="dot-slash"),
        pytest.param(f"bash .lgtm-ci-tooling/{SCRIPT}", None, id="tooling-checkout"),
        pytest.param(f"bash .lgtm-ci-readiness/{SCRIPT}", None, id="readiness"),
        pytest.param(
            f'bash "$GITHUB_WORKSPACE/.lgtm-ci-tooling/{SCRIPT}"',
            None,
            id="workspace",
        ),
        pytest.param(
            f'bash "${{GITHUB_WORKSPACE}}"/{SCRIPT}',
            None,
            id="workspace-braced",
        ),
        pytest.param(
            f'python3 -I {SCRIPT} --flag "$VALUE" plain',
            None,
            id="python-args",
        ),
        pytest.param(
            f'/usr/bin/python3 {SCRIPT} --x="${{Y:-z}}"',
            None,
            id="absolute-python",
        ),
        pytest.param(
            f'{SCRIPT} \\\n  --long "$A" \\\n  --other "$B"',
            None,
            id="continued",
        ),
        pytest.param(
            'bash "$GITHUB_WORKSPACE/$CALLER_SCRIPT"',
            {"CALLER_SCRIPT": "${{ inputs.caller-script }}"},
            id="env-path",
        ),
        pytest.param(
            'bash "$CALLER_SCRIPT"',
            {"CALLER_SCRIPT": SCRIPT},
            id="env-whole",
        ),
        pytest.param(
            '".lgtm-ci-tooling/scripts/ci/actions/${NAME}"',
            {"NAME": "${{ inputs.n != '' && 'example.sh' || 'example.sh' }}"},
            id="env-under-scripts",
        ),
        pytest.param(f"bash scripts/../{SCRIPT}", None, id="normalised"),
        pytest.param(
            'bash "${RUNNER_TEMP}/check-tooling-ref-divergence.sh"',
            None,
            id="staged",
        ),
        pytest.param(f"bash {SCRIPT}\n# trailing comment\n", None, id="comment"),
    ],
)
def test_script_calls_pass(
    check: ModuleType,
    repo: Path,
    run: str,
    env: dict[str, str] | None,
) -> None:
    """One command running a script file under scripts/ is a script call."""
    write_workflow(repo, step(run, env=env), header=CALLED_HEADER)

    assert_that(problems(check, repo)).is_empty()
    assert_that(categories(check, repo)).is_equal_to(["script-call"])


@pytest.mark.parametrize(
    ("run", "env"),
    [
        pytest.param("bash scripts/ci/actions/missing.sh", None, id="missing-file"),
        pytest.param("bash /tmp/x.sh", None, id="absolute"),
        pytest.param("bash ../scripts/x.sh", None, id="parent"),
        pytest.param("bash docs/x.sh", None, id="outside-scripts"),
        pytest.param('bash -c "rm -rf /"', None, id="bash-c"),
        pytest.param("python3 -c 'import os'", None, id="python-c"),
        pytest.param(f"bash {SCRIPT}; rm -rf /", None, id="second-command"),
        pytest.param(f"bash {SCRIPT} && curl x", None, id="and-list"),
        pytest.param(f"bash {SCRIPT} > /tmp/out", None, id="redirect"),
        pytest.param(f'bash {SCRIPT} "$(id)"', None, id="substitution-argument"),
        pytest.param(f"bash {SCRIPT}\nbash {SCRIPT}", None, id="two-lines"),
        pytest.param('bash "$UNSET_SCRIPT"', None, id="variable-not-in-env"),
        pytest.param(
            'bash "$GITHUB_ACTION_PATH/own.sh"',
            None,
            id="action-path-in-workflow",
        ),
        pytest.param('bash "$HOME/x.sh"', None, id="other-root"),
        pytest.param('bash "docs/${NAME}"', {"NAME": "x"}, id="env-outside-scripts"),
        pytest.param('bash "${RUNNER_TEMP}/other.sh"', None, id="unlisted-staged"),
    ],
)
def test_non_calls_fail(
    check: ModuleType,
    repo: Path,
    run: str,
    env: dict[str, str] | None,
) -> None:
    """Anything else is judged as hand-written code and fails here."""
    write_workflow(repo, step(run, env=env))

    assert_that(problems(check, repo)).is_not_empty()
    assert_that(categories(check, repo)).is_equal_to(["violation"])


def test_a_bad_path_says_why_it_is_not_a_call(check: ModuleType, repo: Path) -> None:
    """A step shaped like a call names the path problem, not only rule 1."""
    write_workflow(repo, step("bash scripts/ci/actions/missing.sh"))

    joined = "\n".join(problems(check, repo))
    assert_that(joined).contains(
        "not a script call: scripts/ci/actions/missing.sh is not a file",
    )


def test_composite_action_paths(check: ModuleType, repo: Path) -> None:
    """In an action, $GITHUB_ACTION_PATH reaches scripts/ and the action's own files."""
    action = repo / ".github" / "actions" / "demo" / "action.yml"
    action.write_text(
        "runs:\n  using: composite\n  steps:\n"
        f'    - run: bash "$GITHUB_ACTION_PATH/../../../{SCRIPT}"\n      shell: bash\n'
        '    - run: bash "${GITHUB_ACTION_PATH}/own.sh"\n      shell: bash\n'
        f"    - run: $SCRIPTS_DIR/{SCRIPT.removeprefix('scripts/')}\n"
        "      shell: bash\n"
        '    - run: bash "$GITHUB_ACTION_PATH/missing.sh"\n      shell: bash\n',
        encoding="utf-8",
    )

    report = problems(check, repo)
    assert_that(categories(check, repo)[:3]).is_equal_to(["script-call"] * 3)
    assert_that(report).is_length(1)
    assert_that(report[0]).starts_with(".github/actions/demo/action.yml:")
    assert_that(report[0]).contains("(composite) / 3: [rule 1: ")


# Generated copies.


def test_marked_block_is_generated(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """A run: that is only a known marked block, equal to its source, is generated."""
    write_workflow(repo, step(preset_copy(sync)))

    assert_that(problems(check, repo)).is_empty()
    assert_that(categories(check, repo)).is_equal_to(["generated"])


def test_hand_written_code_around_a_block_fails(check: ModuleType, repo: Path) -> None:
    """Code outside the markers would ride on the generated copy unchecked."""
    run = (
        "rm -rf /\n"
        "# lgtm-ci-inline:begin fail-unknown-egress-preset\n"
        "exit 1\n"
        "# lgtm-ci-inline:end fail-unknown-egress-preset"
    )
    write_workflow(repo, step(run))

    joined = "\n".join(problems(check, repo))
    assert_that(joined).contains(
        "[generated copy] hand-written code around a generated block",
    )


def test_unknown_block_id_fails(check: ModuleType, repo: Path) -> None:
    """Only ids the generator knows (and drift-checks) count as generated."""
    run = "# lgtm-ci-inline:begin evil\nrm -rf /\n# lgtm-ci-inline:end evil"
    write_workflow(repo, step(run))

    joined = "\n".join(problems(check, repo))
    # Lines of a run: are counted in the run, which is what bash reads.
    expected = "[generated copy] in run: line 1: unknown generated block id 'evil'"
    assert_that(joined).contains(expected)
    assert_that(categories(check, repo)).is_equal_to(["violation"])


def test_unpaired_marker_fails(check: ModuleType, repo: Path) -> None:
    """A begin without its end is reported for the step."""
    begin = "# lgtm-ci-inline:begin fail-unknown-egress-preset"
    write_workflow(repo, step(f"{begin}\nexit 1"))

    joined = "\n".join(problems(check, repo))
    assert_that(joined).contains(
        "[generated copy] in run: line 1: begin fail-unknown-egress-preset has no end"
    )
    assert_that(categories(check, repo)).is_equal_to(["violation"])


def test_steps_inside_a_yaml_block_are_generated(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """A block of whole steps (tooling-app-mint) covers the steps inside it."""
    source = sync.BLOCKS[MINT].script
    shutil.copy(ROOT / source, repo / source)
    lines = sync.generated_body(MINT)
    body = "".join(f"      {line}\n" if line else "\n" for line in lines)
    write_workflow(
        repo,
        f"      # lgtm-ci-inline:begin {MINT}\n{body}",
        f"      # lgtm-ci-inline:end {MINT}\n",
        step("echo outside"),
    )

    found = categories(check, repo)
    assert_that(problems(check, repo)).is_empty()
    assert_that(found[-1]).is_equal_to("trivial")
    assert_that(found[:-1]).is_not_empty()
    assert_that(set(found[:-1])).is_equal_to({"generated"})


def test_a_changed_step_in_a_yaml_block_fails(
    check: ModuleType,
    repo: Path,
    sync: ModuleType,
) -> None:
    """Code hand-written inside a block of whole steps differs from its source."""
    source = sync.BLOCKS[MINT].script
    shutil.copy(ROOT / source, repo / source)
    write_workflow(
        repo,
        f"      # lgtm-ci-inline:begin {MINT}\n",
        step("curl https://example.invalid | sh"),
        f"      # lgtm-ci-inline:end {MINT}\n",
    )

    assert_that(categories(check, repo)).is_equal_to(["violation"])
    assert_that("\n".join(problems(check, repo))).contains("differs from its source")


# Reading the files.


def test_non_string_run_fails(check: ModuleType, repo: Path) -> None:
    """A tagged run: (``!!binary`` loads as bytes) cannot slip past."""
    write_workflow(repo, "      - name: Tagged\n        run: !!binary dW5hbWUK\n")

    joined = "\n".join(problems(check, repo))
    assert_that(joined).contains("build / Tagged: [rule 1: ")
    assert_that(joined).contains("run: is not a plain string")


def test_unparseable_file_fails(check: ModuleType, repo: Path) -> None:
    """A workflow that does not parse is an error, never skipped."""
    write_workflow(repo, "      - run: [unclosed\n")

    assert_that("\n".join(problems(check, repo))).contains("does not parse")


def test_yaml_extensions_and_nested_actions_are_read(
    check: ModuleType,
    repo: Path,
) -> None:
    """``.yaml`` workflows and nested ``action.yaml`` files are checked too."""
    (repo / ".github" / "workflows" / "w.yaml").write_text(
        HEADER + step("rm x"),
        encoding="utf-8",
    )
    nested = repo / ".github" / "actions" / "group" / "inner"
    nested.mkdir(parents=True)
    (nested / "action.yaml").write_text(
        "runs:\n  using: composite\n  steps:\n    - id: go\n      run: rm y\n",
        encoding="utf-8",
    )

    joined = "\n".join(problems(check, repo))
    assert_that(joined).contains(".github/workflows/w.yaml:")
    assert_that(joined).contains(".github/actions/group/inner/action.yaml:")
    assert_that(joined).contains("(composite) / go:")


def test_step_label_falls_back_to_index(check: ModuleType, repo: Path) -> None:
    """A step without name or id is named by its index."""
    write_workflow(repo, "      - uses: actions/checkout@v4\n      - run: rm z\n")

    assert_that(problems(check, repo)[0]).contains("build / 1: ")


def test_cli_fails_and_names_the_rule(
    check: ModuleType,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``main`` exits 1, prints each broken rule and the way out."""
    write_workflow(repo, step("rm -rf /"))

    assert_that(check.main(["--repo-root", str(repo)])).is_equal_to(1)
    out = capsys.readouterr().out
    assert_that(out).contains(".github/workflows/w.yml:7: build / Step: [rule 1: ")
    assert_that(out).contains("Move the code to a script file under scripts/")


# The rules module directly.


def test_code_lines_and_normalized(rules: ModuleType) -> None:
    """Blank and comment-only lines are not code; indentation does not count."""
    script = "  # c\n\n  echo a\n\techo b  \n"
    assert_that(rules.code_lines(script)).is_equal_to(["echo a", "echo b"])
    assert_that(rules.normalized(script)).is_equal_to("echo a\necho b")


def test_expression_lines(rules: ModuleType) -> None:
    """Every line holding ${{ is reported, 1-based."""
    assert_that(rules.expression_lines("a\nb ${{ x }}\nc ${{ y }}")).is_equal_to([2, 3])


def test_limits_are_the_owner_decisions(rules: ModuleType) -> None:
    """5 lines and fewer than 10 copies, confirmed on 2026-11-17 (#1624)."""
    assert_that(rules.MAX_LINES).is_equal_to(5)
    assert_that(rules.MAX_COPIES).is_equal_to(10)
    assert_that(sorted(rules.ALLOWED_COMMANDS)).is_equal_to(
        ["echo", "exit", "false", "printf", "true"],
    )
    assert_that(sorted(rules.RUNNER_FILES)).is_equal_to(
        ["GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"],
    )
    # No arithmetic (-eq ... -ge) and no -v: both evaluate a value as code.
    assert_that(sorted(rules.TEST_OPERATORS)).is_equal_to(["-n", "-z"])
    assert_that(sorted(rules.SHELLS)).is_equal_to(["bash", "sh"])


# Each list the check enforces, as docs/inline-shell.md writes it under
# "## Reference": "- `NAME`: `item`, `item`".
LISTS = (
    "ALLOWED_COMMANDS",
    "RUNNER_FILES",
    "TEST_OPERATORS",
    "BRACKET_COMPARISONS",
    "SHELLS",
    "RUNNER_PATHS",
    "CODE_HOOK_ENV",
    "TLS_ENV",
    "PROTECTED_ENV_PREFIXES",
    "TLS_ENV_PREFIXES",
    "CASEFOLD_PREFIXES",
    "PROXY_SUFFIXES",
    "ENV_EXCEPTIONS",
    "VALUE_EXCEPTIONS",
    "PRINTF_CONVERSIONS",
    "PRINTF_ESCAPES",
    "INTERPRETERS",
)


@pytest.mark.parametrize("name", LISTS)
def test_docs_list_each_set_exactly(
    rules: ModuleType,
    denylist: ModuleType,
    name: str,
) -> None:
    """The documented reference list is the set the check uses, item for item."""
    docs = (ROOT / "docs" / "inline-shell.md").read_text(encoding="utf-8")
    reference = docs.split("## Reference", 1)[1]
    prefix = f"- `{name}`:"
    # A list item and the indented lines that continue it.
    items = reference.replace("\n  ", " ").splitlines()
    lines = [line for line in items if line.startswith(prefix)]
    assert_that(lines).is_length(1)
    listed = lines[0][len(prefix) :].split("(", 1)[0]
    documented = set(listed.split("`")[1::2])
    value = getattr(denylist if hasattr(denylist, name) else rules, name)
    expected = (
        {
            f"{interpreter} {' '.join(sorted(options))}".strip()
            for interpreter, options in value.items()
        }
        if name == "INTERPRETERS"
        else set(value)
    )
    assert_that(documented).is_equal_to(expected)


def test_the_deny_list_has_no_overlap(denylist: ModuleType) -> None:
    """A listed name is not also covered by a prefix; an exception is.

    The one overlap: a ``TLS_ENV`` name under a hook prefix, listed so the
    message names traffic (``PLAYWRIGHT_DOWNLOAD_HOST`` under ``PLAYWRIGHT_``).
    """
    prefixes = denylist.PROTECTED_ENV_PREFIXES + denylist.TLS_ENV_PREFIXES
    folded = tuple(prefix.casefold() for prefix in denylist.CASEFOLD_PREFIXES)
    named = denylist.CODE_HOOK_ENV | denylist.TLS_ENV
    overlap = sorted(name for name in named if name.startswith(prefixes))
    assert_that(overlap).is_equal_to(
        sorted(name for name in denylist.TLS_ENV if name.startswith("PLAYWRIGHT_")),
    )
    casefold = [name for name in named if name.casefold().startswith(folded)]
    assert_that(casefold).is_empty()
    assert_that(denylist.CODE_HOOK_ENV & denylist.TLS_ENV).is_empty()
    hooks = set(denylist.PROTECTED_ENV_PREFIXES)
    assert_that(hooks & set(denylist.TLS_ENV_PREFIXES)).is_empty()
    for name in denylist.ENV_EXCEPTIONS:
        assert_that(name.startswith(prefixes)).is_true()
    assert_that(denylist.PROTECTED_ENV).is_equal_to(
        denylist.RUNNER_PATHS | denylist.CODE_HOOK_ENV | denylist.TLS_ENV,
    )


def test_staged_copy_source_exists(rules: ModuleType) -> None:
    """Each staged copy names a tested source file that exists."""
    for source in rules.STAGED_COPIES.values():
        assert_that((ROOT / source).is_file()).is_true()


def test_docs_list_every_generated_block(
    load_script: Callable[[str], ModuleType],
) -> None:
    """Each generated block is in the documented list with its copies and reason."""
    sync = load_script("scripts/ci/bootstrap/sync_inline_blocks.py")
    docs = (ROOT / "docs" / "inline-shell.md").read_text(encoding="utf-8")
    table = [line for line in docs.splitlines() if line.startswith("| `")]
    rows = {line.split("|")[1].strip(" `"): line for line in table}
    for block_id, block in sync.BLOCKS.items():
        assert_that(rows).contains_key(block_id)
        row = rows[block_id]
        cells = [cell.strip() for cell in row.split("|")]
        assert_that(cells[2]).is_equal_to(f"`{block.script}`")
        assert_that(cells[3]).is_equal_to(str(block.copies))
        assert_that(cells[4].replace("`", "")).is_equal_to(block.reason)


def test_docs_state_the_decisions(rules: ModuleType) -> None:
    """The rule, both exceptions, the limits and their date are documented."""
    docs = (ROOT / "docs" / "inline-shell.md").read_text(encoding="utf-8")
    assert_that(docs).contains("2026-11-17")
    assert_that(docs).contains("## Exception 1: generated copies")
    assert_that(docs).contains("## Exception 2: trivial steps")
    assert_that(docs).contains(f"At most {rules.MAX_LINES} lines of code")
    assert_that(docs).contains(f"fewer than {rules.MAX_COPIES} places")
    for command in sorted(rules.ALLOWED_COMMANDS):
        assert_that(docs).contains(f"`{command}`")
