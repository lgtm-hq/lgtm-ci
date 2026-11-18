# SPDX-License-Identifier: MIT
"""The ``env:`` names the inline-shell check refuses (#1624).

An ``env:`` at any level (workflow, job, step, composite step, and the step
that calls an action) must not set a name the programs under ``scripts/ci``
read as a startup hook, a config or index redirect, or a TLS or traffic
setting: such a name changes what a checked step runs without changing its
text. The owner decision of 2026-11-18
(https://github.com/lgtm-hq/lgtm-ci/issues/1624#issuecomment-6971075242):
the names are a deny list of exact names and prefix families covering every
tool ``scripts/ci`` runs, and ``tests/python/test_inline_shell_tools.py``
fails when a script starts running a tool the list does not account for.
Every name must also be a plain ``[A-Za-z_][A-Za-z0-9_]*`` (:data:`ENV_NAME`).

Matching is exact and case-sensitive, as these programs read the names,
except for two families whose readers ignore case: :data:`CASEFOLD_PREFIXES`
(npm and pnpm normalise ``nPm_cOnFiG_registry`` to ``registry``) and
:data:`PROXY_SUFFIXES` (Python's ``urllib`` lowercases every name before it
looks for ``_proxy``). pip, uv, cargo, docker, git, gh, bundler, Homebrew and
the Go tool read their own families case-sensitively.
"""

from __future__ import annotations

import re
from collections.abc import Callable

ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# Runner paths the check trusts as roots or as write targets. An env: entry
# that sets one would point a script call or a write somewhere else.
RUNNER_PATHS = frozenset(
    {
        "GITHUB_OUTPUT",
        "GITHUB_STEP_SUMMARY",
        "GITHUB_ENV",
        "GITHUB_PATH",
        "GITHUB_WORKSPACE",
        "GITHUB_ACTION_PATH",
        "SCRIPTS_DIR",
        "RUNNER_TEMP",
    },
)
# Names that make a program run code: a startup file, a command it runs (an
# editor, pager, browser, askpass, compiler or wrapper), the options it
# starts with, or the directory, repository or config it loads them from.
#
# bash and sh: BASH_ENV and ENV are expanded, so '$(curl ...)' runs; PS4 runs
# under xtrace, which SHELLOPTS or BASHOPTS turn on; BASH_LOADABLES_PATH
# picks the builtins `enable -f` loads; PATH, IFS, CDPATH and GLOBIGNORE
# change what a word or a command means. HOME and XDG_CONFIG_HOME choose the
# config files git, gh, ssh, curl, jq and npm read. ACTIONS_ALLOW_UNSECURE_
# COMMANDS brings back ::set-env and ::add-path, so a value a trivial step
# echoes could set BASH_ENV for the later steps. GIT_DIR and the other git
# repository names point git at another repository's config (core.fsmonitor,
# core.hooksPath). GH_CONFIG_DIR picks gh's aliases, which may run a shell.
# CC, CXX, AR and the *FLAGS pick the compiler and its plugins for make,
# cmake and cargo build scripts; RUSTFLAGS can add linker arguments.
# TAR_OPTIONS (--to-command), ZIP and ZIPOPT (-TT), UNZIP and UNZIPOPT add
# options to every call. APT_CONFIG may set APT::Update::Pre-Invoke.
# COVERAGE_RCFILE and COVERAGE_PROCESS_START load coverage.py plugins;
# BATS_LIB_PATH picks the libraries bats loads; GOFLAGS can set -toolexec.
# CHROME_PATH and LIGHTHOUSE_CHROMIUM_PATH pick the browser lhci starts
# (through chrome-launcher). GREP_OPTIONS adds options to every BSD grep.
CODE_HOOK_ENV = frozenset(
    {
        "CHROME_PATH",
        "LIGHTHOUSE_CHROMIUM_PATH",
        "GREP_OPTIONS",
        "ACTIONS_ALLOW_UNSECURE_COMMANDS",
        "BASH_ENV",
        "ENV",
        "SHELLOPTS",
        "BASHOPTS",
        "PS4",
        "PROMPT_COMMAND",
        "BASH_LOADABLES_PATH",
        "PATH",
        "IFS",
        "CDPATH",
        "GLOBIGNORE",
        "HOME",
        "XDG_CONFIG_HOME",
        "GCONV_PATH",
        "GLIBC_TUNABLES",
        "NODE_OPTIONS",
        "NODE_PATH",
        "GIT_SSH_COMMAND",
        "GIT_SSH",
        "GIT_EXTERNAL_DIFF",
        "GIT_PAGER",
        "PAGER",
        "GIT_EDITOR",
        "GIT_SEQUENCE_EDITOR",
        "EDITOR",
        "VISUAL",
        "GIT_ASKPASS",
        "SSH_ASKPASS",
        "GIT_PROXY_COMMAND",
        "GIT_EXEC_PATH",
        "GIT_TEMPLATE_DIR",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_NAMESPACE",
        "GH_BROWSER",
        "GH_EDITOR",
        "GH_PAGER",
        "GH_CONFIG_DIR",
        "BROWSER",
        "LESSOPEN",
        "LESSCLOSE",
        "PERLLIB",
        "JAVA_TOOL_OPTIONS",
        "_JAVA_OPTIONS",
        "RUBYOPT",
        "RUBYLIB",
        "GEM_HOME",
        "GEM_PATH",
        "GEMRC",
        "CURL_HOME",
        "RUSTFLAGS",
        "LLVM_COV",
        "LLVM_PROFDATA",
        "CC",
        "CXX",
        "AR",
        "CFLAGS",
        "CXXFLAGS",
        "CPPFLAGS",
        "LDFLAGS",
        "MAKEFLAGS",
        "MFLAGS",
        "GNUMAKEFLAGS",
        "MAKEFILES",
        "TAR_OPTIONS",
        "ZIP",
        "ZIPOPT",
        "UNZIP",
        "UNZIPOPT",
        "AWKPATH",
        "AWKLIBPATH",
        "APT_CONFIG",
        "SUDO_ASKPASS",
        "COVERAGE_RCFILE",
        "COVERAGE_PROCESS_START",
        "BATS_LIB_PATH",
        "GOFLAGS",
        "GOENV",
        "GOROOT",
        "GOTOOLCHAIN",
    },
)
# Names that make a client trust another certificate authority, skip
# verification, or fetch packages, names or API answers from another host.
# GH_HOST sends gh's API calls, and the token with them, to another host.
# SSLKEYLOGFILE makes OpenSSL, curl, Node and Python write the session keys
# of every TLS connection to a file. The PLAYWRIGHT_*DOWNLOAD_HOST names
# fetch the browsers from another host (checked before the PLAYWRIGHT_
# prefix, so the message names traffic).
TLS_ENV = frozenset(
    {
        "SSLKEYLOGFILE",
        "PLAYWRIGHT_DOWNLOAD_HOST",
        "PLAYWRIGHT_CHROMIUM_DOWNLOAD_HOST",
        "PLAYWRIGHT_FIREFOX_DOWNLOAD_HOST",
        "PLAYWRIGHT_WEBKIT_DOWNLOAD_HOST",
        "NODE_TLS_REJECT_UNAUTHORIZED",
        "NODE_EXTRA_CA_CERTS",
        "GIT_SSL_NO_VERIFY",
        "GIT_SSL_CAINFO",
        "GIT_SSL_CAPATH",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "CURL_CA_BUNDLE",
        "REQUESTS_CA_BUNDLE",
        "WGETRC",
        "SYSTEM_WGETRC",
        "GH_HOST",
        "GH_REPO",
        "RUBYGEMS_HOST",
        "BUILDKIT_HOST",
        "TUF_ROOT",
        "GOPROXY",
        "GONOPROXY",
        "GOPRIVATE",
        "GOSUMDB",
        "GONOSUMDB",
        "GONOSUMCHECK",
        "GOINSECURE",
        "HOSTALIASES",
        "LOCALDOMAIN",
        "RES_OPTIONS",
    },
)
PROTECTED_ENV = RUNNER_PATHS | CODE_HOOK_ENV | TLS_ENV
# Families a program reads as hooks, matched by prefix, case-sensitively.
# BASH_FUNC_<name>%% is an exported bash function: it replaces the command
# <name> in every bash the step starts. LD_ and DYLD_ are the loaders'
# (LD_PRELOAD, DYLD_INSERT_LIBRARIES); PYTHON is CPython's (PYTHONPATH,
# PYTHONSTARTUP, PYTHON_PRESITE): python3 -I ignores them, but python3
# without -I, a shebang and a script's subprocesses do not. GIT_CONFIG covers
# GIT_CONFIG_GLOBAL and GIT_CONFIG_COUNT/KEY_n/VALUE_n, which set any git
# option. PERL5 covers PERL5OPT, PERL5LIB and PERL5DB (lcov and shasum are
# perl). PIP_ and UV_ set any pip or uv option: an index, a config file, the
# interpreter. BUN_ sets bun's options and registry. CARGO_ sets any cargo
# option (CARGO_TARGET_<triple>_RUNNER, CARGO_BUILD_RUSTC_WRAPPER); RUSTC
# covers RUSTC and RUSTC_WRAPPER, RUSTUP_ the toolchain and its download
# server, RUSTDOC rustdoc and RUSTDOCFLAGS, CROSS_ cross's pre-build commands
# and image, CGO_ the flags cgo passes to the C compiler, CMAKE_ cmake's
# CMAKE_TOOLCHAIN_FILE and CMAKE_<LANG>_COMPILER_LAUNCHER. DOCKER_ covers
# DOCKER_CONFIG (credential helpers, which crane reads too) and DOCKER_HOST,
# BUILDX_ buildx's config. BUNDLE_ sets any bundler option (BUNDLE_GEMFILE
# is Ruby code). COSIGN_ covers COSIGN_PKCS11_MODULE_PATH, a library cosign
# loads. HOMEBREW_ sets brew's git remotes and bottle hosts; LHCI_ any
# Lighthouse CI option (collect.startServerCommand); OPENSSL_ the config and
# modules OpenSSL loads in curl, git, python and openssl; SYSTEMD_ the pager
# systemctl runs. PYTEST_ covers PYTEST_ADDOPTS and PYTEST_PLUGINS (plugins
# pytest imports). PLAYWRIGHT_ covers PLAYWRIGHT_BROWSERS_PATH (where the
# browser it starts comes from); PWDEBUG, PWTEST_ and PW_ are playwright's
# own (PWTEST_CLI_EXECUTABLE_PATH, PW_INSTRUMENT_MODULES). PUPPETEER_ covers
# PUPPETEER_EXECUTABLE_PATH and the download hosts of puppeteer, which lhci
# loads when a project installs it. VITEST_ covers VITEST_MODULE_DIRECTORIES,
# which changes how vitest resolves and inlines modules.
PROTECTED_ENV_PREFIXES = (
    "BASH_FUNC_",
    "LD_",
    "DYLD_",
    "PYTHON",
    "GIT_CONFIG",
    "PERL5",
    "PIP_",
    "UV_",
    "BUN_",
    "CARGO_",
    "RUSTC",
    "RUSTUP_",
    "RUSTDOC",
    "CROSS_",
    "CGO_",
    "CMAKE_",
    "DOCKER_",
    "BUILDX_",
    "BUNDLE_",
    "COSIGN_",
    "HOMEBREW_",
    "LHCI_",
    "OPENSSL_",
    "SYSTEMD_",
    "PYTEST_",
    "PLAYWRIGHT_",
    "PWDEBUG",
    "PWTEST_",
    "PW_",
    "PUPPETEER_",
    "VITEST_",
)
# Families that redirect traffic or trust, matched by prefix, case-sensitively:
# SIGSTORE_ (the trust root and the Rekor and Fulcio hosts), SYFT_, GRYPE_
# and TRIVY_ (their database hosts and TLS checks), TWINE_ (the upload
# repository and its certificate).
TLS_ENV_PREFIXES = ("SIGSTORE_", "SYFT_", "GRYPE_", "TRIVY_", "TWINE_")
# Families matched in any case: npm and pnpm (through @pnpm/npm-conf) read
# any name that is npm_config_ (or pnpm_config_) in any case as an option
# (script-shell, registry, userconfig), so nPm_cOnFiG_registry is one.
# playwright reads its names as npm_package_config_<name> too
# (npm_package_config_playwright_download_host).
CASEFOLD_PREFIXES = ("npm_config_", "pnpm_config_", "npm_package_config_")
# Matched in any case: http_proxy, HTTPS_PROXY, ALL_PROXY, NO_PROXY.
PROXY_SUFFIXES = ("_proxy",)
# Names a prefix covers that no program reads, each in use in the tree:
# PYTHON_VERSION is the version setup-python.sh and run-ai-review.sh install;
# DOCKER_IMAGE the image detect-channels.sh asks crane about (docker reads no
# such name); COSIGN_SIGNED a flag docker/summary.sh prints (cosign reads no
# such name); HOMEBREW_RESULT a job result record-recovery.sh prints (brew
# reads no such name). TRIVY_DISABLE_TELEMETRY and TRIVY_SKIP_VERSION_CHECK
# only stop trivy's own calls home, on the trivy-action steps.
# PLAYWRIGHT_BROWSER is the browser run-playwright.sh passes on argv to
# `playwright install` and as --project (playwright reads no such name).
ENV_EXCEPTIONS = frozenset(
    {
        "PLAYWRIGHT_BROWSER",
        "PYTHON_VERSION",
        "DOCKER_IMAGE",
        "COSIGN_SIGNED",
        "HOMEBREW_RESULT",
        "TRIVY_DISABLE_TELEMETRY",
        "TRIVY_SKIP_VERSION_CHECK",
    },
)
# A protected name an env: may still set to a value the check reads as safe.
# gh reads GH_REPO as [HOST/]OWNER/REPO, so a host part sends gh's API calls
# and its token to that host. The calling repository and a literal
# OWNER/REPO with exactly two segments name no host; any other value
# (another expression, a host-qualified literal, a non-scalar) is refused.
CALLING_REPOSITORY = re.compile(r"\$\{\{\s*github\.repository\s*\}\}")
OWNER_REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+")


def _same_host_repository(value: str | None) -> bool:
    """Tell whether a ``GH_REPO`` value names a repository but no host."""
    if value is None:
        return False
    return bool(CALLING_REPOSITORY.fullmatch(value) or OWNER_REPO.fullmatch(value))


VALUE_EXCEPTIONS: dict[str, Callable[[str | None], bool]] = {
    "GH_REPO": _same_host_repository,
}
CODE_REASON = "which can make this or a later step run code"
TLS_REASON = "which can weaken TLS or redirect traffic"


def protected_reason(name: str, value: str | None = None) -> str:
    """Return why an ``env:`` must not set a name to a value, else "".

    Args:
        name: An ``env:`` name.
        value: Its value; None when it is not a plain scalar or not known,
            which no :data:`VALUE_EXCEPTIONS` entry allows.

    Returns:
        The reason, to follow ``env: sets NAME, `` in a message.
    """
    if name in RUNNER_PATHS:
        return "a runner path the check trusts"
    allowed = VALUE_EXCEPTIONS.get(name)
    if name in ENV_EXCEPTIONS or (allowed is not None and allowed(value)):
        return ""
    if name in TLS_ENV:
        return TLS_REASON
    folded = name.casefold()
    hook = name in CODE_HOOK_ENV or name.startswith(PROTECTED_ENV_PREFIXES)
    if hook or folded.startswith(CASEFOLD_PREFIXES):
        return CODE_REASON
    tls = name in TLS_ENV or name.startswith(TLS_ENV_PREFIXES)
    if tls or folded.endswith(PROXY_SUFFIXES):
        return TLS_REASON
    return ""


def name_problem(name: str, where: str) -> str:
    """Return why an ``env:`` name is not a plain name, else "".

    Args:
        name: An ``env:`` name, as YAML parsed it.
        where: ``step``, ``job``, ``workflow`` or ``call``, for the message.

    Returns:
        The message.
    """
    if ENV_NAME.fullmatch(name):
        return ""
    return (
        f"{where} env: name {name!r} is not a plain name "
        "([A-Za-z_][A-Za-z0-9_]*); write it out without spaces, expressions "
        "or punctuation"
    )
