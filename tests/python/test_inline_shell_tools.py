# SPDX-License-Identifier: MIT
"""The inline-shell deny list accounts for every tool scripts run (#1624).

The owner decision of 2026-11-18
(https://github.com/lgtm-hq/lgtm-ci/issues/1624#issuecomment-6971075242):
``env:`` names are checked with a deny list covering every tool the scripts
run, and this test keeps it complete. ``inline_shell_tools`` finds the
programs; each must be in ``COVERED`` (mapped to the deny-list entries for
its hooks, each of which must be protected) or in ``HOOK_FREE`` (with the
reason it reads no hook from the environment). docs/inline-shell.md says how
to extend the tables.

An entry ending in ``*`` is a prefix family: ``CARGO_*`` is checked as
``CARGO_PROBE``. ``LOADER`` holds for every program and is checked once.
"""

from __future__ import annotations

import importlib
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import inline_shell_tools
import pytest
from assertpy import assert_that
from inline_shell_support import SCRIPT_PATH

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts" / "ci"

# Read by every dynamically linked program: the loader, glibc and OpenSSL.
LOADER = ("LD_*", "DYLD_*", "GCONV_PATH", "GLIBC_TUNABLES", "OPENSSL_*")
# Grouped by what each does: startup files, options, functions, word meaning.
SHELL = (
    "BASH_ENV",
    "ENV",
    "BASH_LOADABLES_PATH",
    "PS4",
    "SHELLOPTS",
    "PROMPT_COMMAND",
    "BASHOPTS",
    "BASH_FUNC_*",
    "IFS",
    "GLOBIGNORE",
    "CDPATH",
    "PATH",
)
TLS = (
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "SSLKEYLOGFILE",
    "https_proxy",
    "HTTP_PROXY",
    "no_proxy",
)
PYTHON = ("PYTHON*", "REQUESTS_CA_BUNDLE", *TLS)
NODE = (
    "NODE_OPTIONS",
    "NODE_PATH",
    "NODE_TLS_REJECT_UNAUTHORIZED",
    "NODE_EXTRA_CA_CERTS",
)
NPM = (*NODE, "npm_config_*", "nPm_cOnFiG_*", "NPM_CONFIG_*", "HOME", *TLS)
RUBY = (
    "BUNDLE_*",
    "GEMRC",
    "GEM_HOME",
    "GEM_PATH",
    "RUBYGEMS_HOST",
    "RUBYLIB",
    "RUBYOPT",
)
PERL = ("PERL5*", "PERLLIB")
COMPILER = ("CC", "CXX", "AR", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS")
RUST = ("CARGO_*", "RUSTC*", "RUSTUP_*", "RUSTDOC*", "RUSTFLAGS", *COMPILER, *TLS)
GIT = (
    "EDITOR",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_ASKPASS",
    "GIT_COMMON_DIR",
    "GIT_CONFIG*",
    "GIT_DIR",
    "GIT_EDITOR",
    "GIT_EXEC_PATH",
    "GIT_EXTERNAL_DIFF",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_PAGER",
    "GIT_PROXY_COMMAND",
    "GIT_SEQUENCE_EDITOR",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_SSL_CAINFO",
    "GIT_SSL_CAPATH",
    "GIT_SSL_NO_VERIFY",
    "GIT_TEMPLATE_DIR",
    "GIT_WORK_TREE",
    "HOME",
    "LESSOPEN",
    "PAGER",
    "SSH_ASKPASS",
    "VISUAL",
    "XDG_CONFIG_HOME",
    *TLS,
)
GH = ("GH_HOST", "GH_BROWSER", "GH_EDITOR", "GH_PAGER", "GH_CONFIG_DIR", "BROWSER")
REGISTRY = ("DOCKER_*", *TLS)
SIGSTORE = ("COSIGN_*", "SIGSTORE_*", "TUF_ROOT", *REGISTRY)

# Each tool with the deny-list entries for the environment hooks it reads.
COVERED: dict[str, tuple[str, ...]] = {
    "bash": SHELL,
    "bats": (*SHELL, "BATS_LIB_PATH"),
    "kcov": SHELL,
    # glibc ldd is a bash script that runs the dynamic loader (LD_PRELOAD,
    # LD_LIBRARY_PATH, LD_TRACE_*); playwright_ldd.py probes browsers with it.
    "ldd": (*SHELL, "LD_*"),
    "python": PYTHON,
    "python3": PYTHON,
    "coverage": (*PYTHON, "COVERAGE_RCFILE", "COVERAGE_PROCESS_START"),
    "pycobertura": PYTHON,
    "lcov_cobertura": PYTHON,
    "twine": (*PYTHON, "TWINE_*"),
    "pip": (*PYTHON, "PIP_*"),
    "pytest": (*PYTHON, "PYTEST_*"),
    "build": (*PYTHON, "PIP_*"),
    "uv": (*PYTHON, "UV_*"),
    "lintro": (*PYTHON, "UV_*", *REGISTRY),
    "node": NODE,
    "npm": NPM,
    "npx": NPM,
    "nyc": NPM,
    "playwright": (
        *NPM,
        "PLAYWRIGHT_*",
        "PLAYWRIGHT_DOWNLOAD_HOST",
        "PWDEBUG*",
        "PWTEST_*",
        "PW_*",
        "npm_package_config_*",
    ),
    "vitest": (*NPM, "VITEST_*"),
    "pnpm": (*NPM, "pnpm_config_*", "Pnpm_Config_*"),
    "bun": (*NPM, "BUN_*"),
    "bunx": (*NPM, "BUN_*"),
    "lhci": (
        *NPM,
        "LHCI_*",
        "CHROME_PATH",
        "LIGHTHOUSE_CHROMIUM_PATH",
        "PUPPETEER_*",
    ),
    "git": GIT,
    "gh": (*GIT, *GH),
    "curl": ("CURL_HOME", "CURL_CA_BUNDLE", "HOME", *TLS),
    "wget": ("WGETRC", "SYSTEM_WGETRC", *TLS),
    "openssl": ("OPENSSL_*",),
    "perl": PERL,
    "lcov": (*PERL, "HOME"),
    "shasum": PERL,
    "ruby": RUBY,
    "gem": RUBY,
    "bundle": RUBY,
    "cargo": RUST,
    "rustc": RUST,
    "rustup": RUST,
    "cargo-binstall": RUST,
    "cargo-nextest": RUST,
    "cargo-llvm-cov": (*RUST, "LLVM_COV", "LLVM_PROFDATA"),
    "cross": (*RUST, "CROSS_*", *REGISTRY),
    "make": ("MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKEFILES", *COMPILER),
    "cmake": ("CMAKE_*", *COMPILER),
    "go": (
        "GOFLAGS",
        "GOENV",
        "GOROOT",
        "GOTOOLCHAIN",
        "GOPROXY",
        "GOINSECURE",
        "CGO_*",
    ),
    "docker": (*REGISTRY, "BUILDX_*", "BUILDKIT_HOST"),
    "crane": REGISTRY,
    "cosign": SIGSTORE,
    "syft": ("SYFT_*", *REGISTRY),
    "grype": ("GRYPE_*", *REGISTRY),
    "trivy": ("TRIVY_*", *REGISTRY),
    "tar": ("TAR_OPTIONS",),
    "zip": ("ZIP", "ZIPOPT"),
    "unzip": ("UNZIP", "UNZIPOPT"),
    "awk": ("AWKPATH", "AWKLIBPATH"),
    "apt-get": ("APT_CONFIG", *TLS),
    "sudo": ("SUDO_ASKPASS",),
    "brew": ("HOMEBREW_*", *GIT),
    "systemctl": ("SYSTEMD_*", "PAGER", "LESSOPEN"),
    "jq": ("HOME",),
    "grep": ("GREP_OPTIONS",),
}
# Tools that read no command, library, config, index, host or trust root
# from the environment beyond LOADER (and TMPDIR, POSIXLY_CORRECT, LC_*, TZ,
# which only change where temporary files go or how text is formatted).
COREUTILS = "coreutils: options come from argv only"
HOOK_FREE: dict[str, str] = {
    **dict.fromkeys(
        (
            "base64",
            "basename",
            "cat",
            "chmod",
            "cp",
            "cut",
            "date",
            "df",
            "dirname",
            "du",
            "env",
            "head",
            "id",
            "install",
            "ln",
            "ls",
            "mkdir",
            "mkfifo",
            "mktemp",
            "mv",
            "nproc",
            "od",
            "paste",
            "realpath",
            "rm",
            "rmdir",
            "seq",
            "sha256sum",
            "sha512sum",
            "sleep",
            "sort",
            "stat",
            "tail",
            "tee",
            "timeout",
            "touch",
            "tr",
            "uname",
            "uniq",
            "wc",
        ),
        COREUTILS,
    ),
    "cmp": "diffutils: options come from argv only",
    "column": "util-linux: options come from argv only",
    "find": "findutils: runs only what -exec names in argv",
    "xargs": "findutils: runs only the command named in argv",
    "sed": "GNU sed reads no options from the environment",
    "bc": "BC_ENV_ARGS adds bc files and options; bc code cannot run a command",
    "lsof": "reads no options from the environment",
    "nc": "reads no options from the environment",
    "ss": "iproute2: reads no options from the environment",
    "pkill": "procps: reads no options from the environment",
    "slsa-verifier": "verifies with the flags and trust root given in argv",
    "osv-scanner": "reads flags and osv-scanner.toml; no environment hook",
    "blacksmith": "runner_governor.py starts it with an environment it builds",
    "claude": "ai_review_auth.py starts it with child_environment's allowlist; "
    "install-ai-review-cli.sh only runs --version",
    "codex": "ai_review_auth.py starts it with child_environment's allowlist; "
    "install-ai-review-cli.sh only runs --version",
    "agent": "ai_review_auth.py starts it with child_environment's allowlist; "
    "install-ai-review-cli.sh only runs --version",
}
# Programs a script runs only through a variable or a wrapper, which the
# extraction cannot see, with a file that runs each.
INDIRECT: dict[str, str] = {
    "apt-get": "lib/apt_helper.py",
    "cargo-nextest": "testing/rust/setup-rust-nextest.sh",
    "crane": "release/recover/detect-channels.sh",
    "cross": "release/build-rust-binary.sh",
    "env": "actions/run-ai-review.sh",
    "sudo": "actions/run-bats-tests.sh",
    "timeout": "actions/run-bats-tests.sh",
    "trivy": "actions/docker/trivy-sarif.sh",
    "xargs": "release/ecosystems/_runner.sh",
}
# Words the extraction takes for a program that are not one.
NOT_PROGRAMS: dict[str, str] = {
    "gate": "catalog/deprecations.py: argv for its own subcommand parser",
}


def _probe(entry: str) -> str:
    """Return a name an entry covers: ``CARGO_*`` -> ``CARGO_PROBE``."""
    return f"{entry[:-1]}PROBE" if entry.endswith("*") else entry


@pytest.fixture(name="denylist")
def fixture_denylist(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Return the deny-list module, imported as the validator imports it."""
    load_script(SCRIPT_PATH)
    return importlib.import_module("inline_shell_denylist")


@pytest.fixture(name="found", scope="module")
def fixture_found() -> dict[str, list[str]]:
    """Return every program the scripts run, with the files that run it."""
    found: dict[str, list[str]] = inline_shell_tools.programs(SCRIPTS)
    return found


def _unaccounted(found: dict[str, list[str]]) -> dict[str, list[str]]:
    """Return the programs no table accounts for."""
    known = set(COVERED) | set(HOOK_FREE) | set(NOT_PROGRAMS)
    programs = {**dict.fromkeys(INDIRECT, ["(INDIRECT)"]), **found}
    return {name: files for name, files in programs.items() if name not in known}


def test_every_tool_the_scripts_run_is_accounted_for(
    found: dict[str, list[str]],
) -> None:
    """A tool that is neither covered nor hook-free fails, naming what to do."""
    missing = _unaccounted(found)
    message = "; ".join(
        f"{name} (run in {', '.join(files[:3])}): add the environment variables "
        "it reads as hooks to inline_shell_denylist.py and the tool to COVERED, "
        "or record it in HOOK_FREE with the reason it reads none"
        for name, files in sorted(missing.items())
    )
    assert not missing, message


def test_a_new_tool_fails(tmp_path: Path) -> None:
    """A script that starts running an unknown tool is reported."""
    script = "#!/usr/bin/env bash\nnewtool --flag\n"
    (tmp_path / "x.sh").write_text(script, encoding="utf-8")
    found = inline_shell_tools.programs(tmp_path)
    assert_that(_unaccounted(found)).contains_key("newtool")


@pytest.mark.parametrize("tool", sorted(COVERED))
def test_each_covered_hook_is_on_the_deny_list(denylist: ModuleType, tool: str) -> None:
    """Every entry a covered tool maps to is refused in an ``env:``."""
    open_entries = [
        entry for entry in COVERED[tool] if not denylist.protected_reason(_probe(entry))
    ]
    assert_that(open_entries).described_as(tool).is_empty()


def test_the_loader_hooks_are_on_the_deny_list(denylist: ModuleType) -> None:
    """What every dynamically linked program reads is refused."""
    probes = [_probe(entry) for entry in LOADER]
    assert_that([n for n in probes if not denylist.protected_reason(n)]).is_empty()


def test_the_tables_are_disjoint_and_explained() -> None:
    """A tool is in one table, and each hook-free tool has a reason."""
    assert_that(set(COVERED) & set(HOOK_FREE)).is_empty()
    assert_that(set(NOT_PROGRAMS) & (set(COVERED) | set(HOOK_FREE))).is_empty()
    assert_that([tool for tool, reason in HOOK_FREE.items() if not reason]).is_empty()


def test_the_tables_name_only_tools_a_script_runs(found: dict[str, list[str]]) -> None:
    """An entry for a tool no script runs any more is removed."""
    programs = set(found) | set(INDIRECT)
    stale = (set(COVERED) | set(HOOK_FREE) | set(NOT_PROGRAMS)) - programs
    assert_that(sorted(stale)).is_empty()


@pytest.mark.parametrize(("tool", "relative"), sorted(INDIRECT.items()))
def test_each_indirect_tool_is_named_where_it_runs(tool: str, relative: str) -> None:
    """The curated file still names the tool it is listed for."""
    text = (SCRIPTS / relative).read_text(encoding="utf-8")
    assert_that(text).contains(tool)
