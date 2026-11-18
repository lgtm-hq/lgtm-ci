# SPDX-License-Identifier: MIT
"""Regression tests for review round 5 of the inline-shell check (#1624).

PR #1646, 2026-11-18.

Each rejected case below was accepted at b8e6d362: an ``env:`` name that is
not plain, a hook of a tool ``scripts/ci`` runs that the deny list missed,
``npm_config_`` in mixed case, an ``env:`` on a ``uses:`` step or on a scope
no ``run:`` step reads, and an ``echo`` whose first argument opens with a
variable. The accepted cases pin what must keep passing.
"""

from __future__ import annotations

import importlib
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from inline_shell_support import (
    ACTION_HEAD,
    HEADER,
    JOB_STEPS,
    LEVELS,
    SCRIPT,
    SCRIPT_PATH,
    indented,
    make_repo,
    passes,
    problems,
    rejected,
    step,
    write_env_at,
    write_workflow,
)

PINNED = "actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955"


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which puts its rule modules on ``sys.path``."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository with the sources the checks read."""
    return Path(make_repo(tmp_path))


def _refused(check: ModuleType, repo: Path, expected: str) -> None:
    """Assert the check fails and names ``expected``, with or without a run: step."""
    assert_that(check.main(["--repo-root", str(repo)])).is_equal_to(1)
    assert_that("\n".join(problems(check, repo))).contains(expected)


# 1. An env: name is a plain [A-Za-z_][A-Za-z0-9_]*.


@pytest.mark.parametrize("level", LEVELS)
@pytest.mark.parametrize(
    "name",
    [
        pytest.param("'${{ matrix.n }}'", id="expression"),
        pytest.param("'A B'", id="space"),
        pytest.param("'A%'", id="percent"),
        pytest.param("A-B", id="dash"),
        pytest.param("A.B", id="dot"),
        pytest.param("1A", id="digit-first"),
        pytest.param("' BASH_ENV'", id="padded"),
        pytest.param("'BASH_ENV\u2060'", id="invisible"),
    ],
)
def test_env_name_must_be_plain(
    check: ModuleType,
    repo: Path,
    level: str,
    name: str,
) -> None:
    """A name that is not plain hides which name the runner sets."""
    write_env_at(repo, level, f"\n  {name}: x")
    rejected(check, repo, "is not a plain name")


@pytest.mark.parametrize("name", ["A", "_A", "a_1", "PLAYWRIGHT_BROWSER"])
def test_plain_env_names_pass(check: ModuleType, repo: Path, name: str) -> None:
    """Plain names keep passing."""
    write_env_at(repo, "step", f"\n  {name}: x")
    passes(check, repo, "script-call")


# 2. The deny list covers the hooks of every tool scripts/ci runs.

NEW_NAMES = [
    "AWKPATH",
    "APT_CONFIG",
    "BATS_LIB_PATH",
    "BUILDKIT_HOST",
    "BUILDX_CONFIG",
    "BUN_OPTIONS",
    "BUNDLE_GEMFILE",
    "CARGO_BUILD_RUSTC_WRAPPER",
    "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER",
    "CC",
    "CGO_LDFLAGS",
    "CMAKE_TOOLCHAIN_FILE",
    "COSIGN_PKCS11_MODULE_PATH",
    "COVERAGE_RCFILE",
    "CROSS_CONFIG",
    "DOCKER_CONFIG",
    "DOCKER_HOST",
    "GEM_PATH",
    "GH_CONFIG_DIR",
    "GH_HOST",
    "GH_PAGER",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_SEQUENCE_EDITOR",
    "GIT_WORK_TREE",
    "GOFLAGS",
    "GOPROXY",
    "GRYPE_DB_UPDATE_URL",
    "HOMEBREW_BREW_GIT_REMOTE",
    "LESSOPEN",
    "LHCI_COLLECT__START_SERVER_COMMAND",
    "LLVM_COV",
    "MAKEFLAGS",
    "OPENSSL_CONF",
    "PIP_SRC",
    "RUBYLIB",
    "RUSTC_WRAPPER",
    "RUSTDOCFLAGS",
    "RUSTFLAGS",
    "RUSTUP_TOOLCHAIN",
    "SIGSTORE_REKOR_URL",
    "SUDO_ASKPASS",
    "SYFT_CHECK_FOR_APP_UPDATE",
    "SYSTEMD_PAGER",
    "TAR_OPTIONS",
    "TRIVY_DB_REPOSITORY",
    "TUF_ROOT",
    "TWINE_REPOSITORY_URL",
    "UV_PYTHON",
    "WGETRC",
    "ZIPOPT",
]


@pytest.mark.parametrize("name", NEW_NAMES)
def test_env_cannot_set_a_tool_hook(check: ModuleType, repo: Path, name: str) -> None:
    """Each name makes a tool the scripts run run code or talk to another host."""
    write_env_at(repo, "step", f"\n  {name}: x")
    rejected(check, repo, f"sets {name}")


@pytest.mark.parametrize("level", LEVELS)
@pytest.mark.parametrize(
    "name",
    [
        "nPm_cOnFiG_registry",
        "Npm_Config_script_shell",
        "PNPM_CONFIG_x",
        "pNpm_config_x",
    ],
)
def test_npm_config_matches_in_any_case(
    check: ModuleType,
    repo: Path,
    level: str,
    name: str,
) -> None:
    """npm and pnpm read ``npm_config_`` in any case (round 5, finding 1)."""
    write_env_at(repo, level, f"\n  {name}: https://example.invalid")
    rejected(check, repo, f"sets {name}")


@pytest.mark.parametrize(
    "name",
    [
        "DOCKER_IMAGE",
        "COSIGN_SIGNED",
        "HOMEBREW_RESULT",
        "TRIVY_DISABLE_TELEMETRY",
        "TRIVY_SKIP_VERSION_CHECK",
        "pip_index_url",
        "cargo_home",
        "GH_TOKEN",
        "NODE_VERSION",
        "GIT_DEPS_HOST",
        "COVERAGE_FILE",
    ],
)
def test_names_outside_the_deny_list_pass(
    check: ModuleType,
    repo: Path,
    name: str,
) -> None:
    """Exceptions, tree names and other cases of case-sensitive families pass."""
    write_env_at(repo, "step", f"\n  {name}: x")
    passes(check, repo, "script-call")


# 3. The env: of a step without run:, and of a scope no run: step reads.


def _action(repo: Path) -> None:
    """Write a local composite action whose one run: step is trivial."""
    (repo / ".github" / "actions" / "demo" / "action.yml").write_text(
        f"{ACTION_HEAD}      run: echo sentinel\n",
        encoding="utf-8",
    )


def _uses(target: str, env: str, name: str = "Call") -> str:
    """Return a ``uses:`` step with ``env:`` (the text after ``env:``)."""
    head = f"      - name: {name}\n        uses: {target}\n"
    block: str = indented(f"env:{env}", "        ")
    return head + block


@pytest.mark.parametrize("target", ["./.github/actions/demo", PINNED])
def test_a_uses_step_cannot_set_a_hook(
    check: ModuleType,
    repo: Path,
    target: str,
) -> None:
    """The runner passes a uses: step's env: to the action's own run: steps."""
    _action(repo)
    write_workflow(repo, step(f"bash {SCRIPT}"), _uses(target, "\n  BASH_ENV: x"))
    _refused(check, repo, "w.yml:9: build / Call: [env] step env: sets BASH_ENV")


@pytest.mark.parametrize(
    ("env", "expected"),
    [
        pytest.param(
            ' ${{ fromJSON(\'{"BASH_ENV":"x"}\') }}',
            "not a mapping",
            id="expression",
        ),
        pytest.param("\n  - BASH_ENV=x", "not a mapping", id="sequence"),
        pytest.param("\n  <<: {BASH_ENV: x}", "merge key", id="merge-key"),
        pytest.param("\n  'A B': x", "is not a plain name", id="name"),
        pytest.param(
            "\n  nPm_cOnFiG_registry: x",
            "sets nPm_cOnFiG_registry",
            id="npm",
        ),
    ],
)
def test_a_uses_step_env_must_be_readable(
    check: ModuleType,
    repo: Path,
    env: str,
    expected: str,
) -> None:
    """The mapping and name rules hold on a call site too."""
    _action(repo)
    write_workflow(repo, step(f"bash {SCRIPT}"), _uses("./.github/actions/demo", env))
    _refused(check, repo, expected)


def test_a_composite_uses_step_cannot_set_a_hook(check: ModuleType, repo: Path) -> None:
    """A composite step that calls another action passes its env: on too."""
    (repo / ".github" / "actions" / "demo" / "action.yml").write_text(
        "runs:\n"
        "  using: composite\n"
        "  steps:\n"
        "    - name: Call\n"
        f"      uses: {PINNED}\n"
        "      env:\n"
        "        LD_PRELOAD: x\n",
        encoding="utf-8",
    )
    expected = "action.yml:4: (composite) / Call: [env] step env: sets LD_PRELOAD"
    _refused(check, repo, expected)


def test_a_job_with_only_uses_steps_is_read(check: ModuleType, repo: Path) -> None:
    """A job env: reaches its uses: steps even when no run: step reports it."""
    _action(repo)
    header = HEADER.replace(JOB_STEPS, "    env:\n      BASH_ENV: x\n" + JOB_STEPS)
    write_workflow(repo, _uses("./.github/actions/demo", "\n  A: x"), header=header)
    _refused(check, repo, "w.yml:5: build / (job): [env] job env: sets BASH_ENV")


def test_a_job_container_with_only_uses_steps_is_read(
    check: ModuleType,
    repo: Path,
) -> None:
    """A container: is refused whether or not the job has a run: step."""
    header = HEADER.replace(JOB_STEPS, "    container: alpine\n" + JOB_STEPS)
    write_workflow(repo, _uses(PINNED, "\n  A: x"), header=header)
    _refused(check, repo, "[env] job container: is refused")


def test_a_workflow_with_no_run_steps_is_read(check: ModuleType, repo: Path) -> None:
    """A workflow env: is read even when no job has a run: step."""
    write_workflow(
        repo,
        _uses(PINNED, "\n  A: x"),
        header=f"env:\n  GIT_DIR: /tmp/x\n{HEADER}",
    )
    expected = "w.yml:2: (workflow) / (env): [env] workflow env: sets GIT_DIR"
    _refused(check, repo, expected)


def test_an_env_a_run_step_reports_is_reported_once(
    check: ModuleType,
    repo: Path,
) -> None:
    """A job or workflow env: under a run: step is reported on that step only."""
    write_workflow(
        repo,
        step(f"bash {SCRIPT}"),
        _uses(PINNED, "\n  A: x"),
        header=f"env:\n  BASH_ENV: x\n{HEADER}",
    )
    lines = problems(check, repo)
    assert_that(lines).is_length(1)
    assert_that(lines[0]).contains("[rule 1:").contains("sets BASH_ENV")


def test_plain_call_site_env_passes(check: ModuleType, repo: Path) -> None:
    """A uses: step with a plain env: of unprotected names passes."""
    _action(repo)
    env = "\n  GH_TOKEN: x\n  TRIVY_SKIP_VERSION_CHECK: y"
    write_workflow(
        repo,
        step(f"bash {SCRIPT}"),
        _uses("./.github/actions/demo", env),
        header=f"env:\n  A: x\n{HEADER}",
    )
    assert_that(check.main(["--repo-root", str(repo)])).is_equal_to(0)


# 4. run: text is split on \n only.


@pytest.mark.parametrize("separator", ["\x0b", "\x0c", "\x1c", "\x85", "\u2028"])
def test_code_and_expression_lines_split_on_newline_only(
    check: ModuleType,
    separator: str,
) -> None:
    """``str.splitlines`` broke at characters bash does not end a line at."""
    del check
    rules = importlib.import_module("inline_shell_rules")
    script = f"echo a{separator}exit 1\necho ${{{{ x }}}}{separator}y"
    assert_that(rules.code_lines(script)).is_length(2)
    assert_that(rules.expression_lines(f"a{separator}${{{{ x }}}}")).is_equal_to([1])


# 5. echo's first argument opens with literal text.


@pytest.mark.parametrize(
    "run",
    [
        'echo "$X"',
        'echo "${X:-y}"',
        'echo "$X" >> $GITHUB_OUTPUT',
        'echo >> $GITHUB_OUTPUT "$X"',
        'echo ""$X',
        'echo "$X" "-e"',
    ],
)
def test_echo_first_argument_cannot_open_with_a_variable(
    check: ModuleType,
    repo: Path,
    run: str,
) -> None:
    """``X=-e`` makes ``echo "$X"`` take an option."""
    write_workflow(repo, step(run))
    rejected(check, repo, "use printf '%s\\n'")


@pytest.mark.parametrize("run", ["printf '%s\\n' \"$X\"", 'echo "x=$X"', 'echo x "$X"'])
def test_printing_a_value_safely_passes(
    check: ModuleType,
    repo: Path,
    run: str,
) -> None:
    """printf '%s\\n' prints any value; a literal opening keeps echo option-free."""
    write_workflow(repo, step(run))
    passes(check, repo, "trivial")
