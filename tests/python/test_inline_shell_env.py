# SPDX-License-Identifier: MIT
"""Regression tests for the third review of the inline-shell check (#1624, PR #1646).

Each rejected case below was accepted before: an ``env:`` the check could
not read, a ``container:`` whose ``env:`` it did not read, a startup hook or
a TLS or proxy setting missing from the deny list, an ``echo`` option, and a
tilde after ``=`` or ``:``. The accepted cases pin what must keep passing.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from inline_shell_support import (
    HEADER,
    JOB_STEPS,
    LEVELS,
    SCRIPT,
    SCRIPT_PATH,
    make_repo,
    passes,
    rejected,
    step,
    write_env_at,
    write_workflow,
)


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator, which puts its rule modules on ``sys.path``."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return a scratch repository with the sources the checks read."""
    return Path(make_repo(tmp_path))


# 1. An env: the check cannot read is refused.


@pytest.mark.parametrize("level", LEVELS)
@pytest.mark.parametrize(
    ("env", "expected"),
    [
        pytest.param(
            ' ${{ fromJSON(\'{"BASH_ENV":"x"}\') }}',
            "not a mapping",
            id="expression",
        ),
        pytest.param(" ${{ fromJSON(vars.E) }}", "not a mapping", id="vars"),
        pytest.param("\n  - BASH_ENV=x", "not a mapping", id="sequence"),
        pytest.param("\n  <<: {BASH_ENV: x}", "merge key", id="merge-key"),
        pytest.param("\n  1: x", "not a string", id="int-key"),
        pytest.param("\n  ? [BASH_ENV]\n  : x", "not a string", id="sequence-key"),
    ],
)
def test_an_env_must_be_a_mapping_of_names(
    check: ModuleType,
    repo: Path,
    level: str,
    env: str,
    expected: str,
) -> None:
    """``env: ${{ fromJSON(...) }}`` can set BASH_ENV, and no name shows."""
    write_env_at(repo, level, env)
    rejected(check, repo, expected)


@pytest.mark.parametrize(
    "container",
    [
        pytest.param(
            "\n      image: node:20\n      env:\n        BASH_ENV: x",
            id="env",
        ),
        pytest.param("\n      image: node:20", id="image-only"),
        pytest.param(" node:20", id="short"),
        pytest.param(" ${{ fromJSON(vars.C) }}", id="expression"),
    ],
)
def test_a_job_container_is_refused(
    check: ModuleType,
    repo: Path,
    container: str,
) -> None:
    """``container.env`` reaches every step, and the image picks bash itself."""
    header = HEADER.replace(JOB_STEPS, f"    container:{container}\n{JOB_STEPS}")
    write_workflow(repo, step(f"bash {SCRIPT}"), header=header)
    rejected(check, repo, "container:")


def test_a_plain_env_passes_at_every_level(check: ModuleType, repo: Path) -> None:
    """A mapping of plain names keeps passing."""
    header = HEADER.replace(JOB_STEPS, f"    env:\n      B: y\n{JOB_STEPS}")
    write_workflow(
        repo,
        step(f"bash {SCRIPT}", env={"C": "${{ inputs.c }}"}),
        header=f"env:\n  A: x\n{header}",
    )
    passes(check, repo, "script-call")


# 2. The deny list: startup hooks, TLS and egress.

PREFIX_NAMES = [
    "BASH_FUNC_ls%%",
    "DYLD_INSERT_LIBRARIES",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL",
    "LD_BIND_NOW",
    "npm_config_script_shell",
    "NPM_CONFIG_USERCONFIG",
    "PERL5LIB",
    "PERL5OPT",
    "PYTHON_PRESITE",
    "PYTHONWARNINGS",
]
HOOK_NAMES = [
    "_JAVA_OPTIONS",
    "BASH_LOADABLES_PATH",
    "BROWSER",
    "CURL_HOME",
    "EDITOR",
    "GCONV_PATH",
    "GIT_ASKPASS",
    "GIT_EDITOR",
    "GIT_EXEC_PATH",
    "GIT_EXTERNAL_DIFF",
    "GIT_PAGER",
    "GIT_PROXY_COMMAND",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_TEMPLATE_DIR",
    "GLIBC_TUNABLES",
    "HOME",
    "JAVA_TOOL_OPTIONS",
    "NODE_PATH",
    "PAGER",
    "PERLLIB",
    "RUBYOPT",
    "SSH_ASKPASS",
    "VISUAL",
    "XDG_CONFIG_HOME",
]
TLS_NAMES = [
    "CURL_CA_BUNDLE",
    "GIT_SSL_CAINFO",
    "GIT_SSL_CAPATH",
    "GIT_SSL_NO_VERIFY",
    "HOSTALIASES",
    "LOCALDOMAIN",
    "NODE_EXTRA_CA_CERTS",
    "NODE_TLS_REJECT_UNAUTHORIZED",
    "PIP_CERT",
    "PIP_CONFIG_FILE",
    "PIP_EXTRA_INDEX_URL",
    "PIP_INDEX_URL",
    "PIP_TRUSTED_HOST",
    "REQUESTS_CA_BUNDLE",
    "RES_OPTIONS",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "UV_DEFAULT_INDEX",
    "UV_EXTRA_INDEX_URL",
    "UV_INDEX",
    "UV_INDEX_URL",
    "UV_INSECURE_HOST",
]
PROXY_NAMES = [
    "ALL_PROXY",
    "all_proxy",
    "Ftp_Proxy",
    "http_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "NO_PROXY",
    "no_proxy",
]


@pytest.mark.parametrize("level", LEVELS)
@pytest.mark.parametrize(
    "name",
    [*PREFIX_NAMES, *HOOK_NAMES, *TLS_NAMES, *PROXY_NAMES],
)
def test_env_cannot_set_a_hook_or_weaken_tls(
    check: ModuleType,
    repo: Path,
    level: str,
    name: str,
) -> None:
    """Each name makes a program the scripts reach run code or trust other hosts."""
    write_env_at(repo, level, f"\n  '{name}': x")
    rejected(check, repo, f"sets {name}")


@pytest.mark.parametrize(
    "name",
    ["PYTHON_VERSION", "ld_preload", "git_ssh_command", "PROXY", "BROWSERS"],
)
def test_names_outside_the_deny_list_pass(
    check: ModuleType,
    repo: Path,
    name: str,
) -> None:
    """Matching is exact and case-sensitive, except the ``_proxy`` family."""
    write_env_at(repo, "step", f"\n  {name}: x")
    passes(check, repo, "script-call")


# 3. echo takes no option.


@pytest.mark.parametrize(
    "run",
    [
        pytest.param("echo -e 'a\\tb'", id="e"),
        pytest.param("echo -n x", id="n"),
        pytest.param("echo -E x", id="upper-e"),
        pytest.param("echo -neE x", id="combined"),
        pytest.param('echo "-e" x', id="quoted"),
        pytest.param("echo -", id="dash"),
        pytest.param("echo >> $GITHUB_OUTPUT -e 'a=b'", id="after-redirection"),
    ],
)
def test_echo_takes_no_option(check: ModuleType, repo: Path, run: str) -> None:
    """``echo -e`` turns ``\\n`` in a value into a second output line."""
    write_workflow(repo, step(run))
    rejected(check, repo, "echo takes no option")


def test_printf_takes_no_option_after_a_redirection(
    check: ModuleType,
    repo: Path,
) -> None:
    """``printf >> $GITHUB_OUTPUT -v NAME`` assigns a variable."""
    write_workflow(repo, step("printf >> $GITHUB_OUTPUT -v FLAG 'x'"))
    rejected(check, repo, "printf takes no option")


@pytest.mark.parametrize(
    "run",
    ['echo "x -e"', "echo x -e", 'echo "a=$X" >> $GITHUB_OUTPUT', "echo", 'echo ""'],
)
def test_echo_without_an_option_passes(check: ModuleType, repo: Path, run: str) -> None:
    """A first argument that opens with literal text other than ``-`` is no option.

    ``echo "$X"`` passed here until round 5 of the review; it is refused now
    (``tests/python/test_inline_shell_callsites.py``).
    """
    write_workflow(repo, step(run))
    passes(check, repo, "trivial")


# 4. A tilde after = or :.


@pytest.mark.parametrize(
    "run",
    [
        "echo a=~",
        "echo a=~/x",
        "echo PATH=a:~",
        "echo x:~",
        "printf '%s\\n' a=~root",
    ],
)
def test_a_tilde_after_equals_or_colon_is_refused(
    check: ModuleType,
    repo: Path,
    run: str,
) -> None:
    """Bash expands ``a=~`` to ``a=$HOME``."""
    write_workflow(repo, step(run))
    rejected(check, repo, "tilde")


@pytest.mark.parametrize("run", ['echo "a=~"', "echo a=\\~", "echo a~b", "echo 'x:~'"])
def test_a_quoted_or_inner_tilde_passes(
    check: ModuleType,
    repo: Path,
    run: str,
) -> None:
    """A quoted tilde, or one not after ``=`` or ``:``, is not expanded."""
    write_workflow(repo, step(run))
    passes(check, repo, "trivial")
