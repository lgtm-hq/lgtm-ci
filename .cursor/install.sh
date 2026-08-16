#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Idempotent Cloud Agent bootstrap for the lgtm-ci development
# environment. Installs the toolchain needed to run the repository's canonical
# developer commands:
#
#   uv sync --extra dev          # Python quality tooling (lintro, ruff, black)
#   make lint                    # uv run lintro chk  (native tool parity)
#   make test                    # bats --recursive tests/bats (shell tests)
#   shell coverage               # kcov (STEP=run-coverage run-bats-tests.sh)
#
# The script is safe to run repeatedly: every step is guarded so a second run
# is a fast no-op. It mirrors the tool versions enforced by lintro (which CI
# runs inside the pinned ghcr.io/lgtm-hq/py-lintro image) so `make lint` runs
# the real tools locally instead of skipping them.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned tool versions
# ---------------------------------------------------------------------------
KCOV_VERSION="v43"
BATS_SUPPORT_VERSION="v0.3.0"
BATS_ASSERT_VERSION="v2.2.4"
BATS_FILE_VERSION="v0.4.0"
SHELLCHECK_VERSION="v0.11.0" # lintro requires >= 0.11.0
SHFMT_VERSION="v3.13.1"      # lintro requires >= 3.13.1
ACTIONLINT_VERSION="v1.7.12" # lintro requires >= 1.7.12
HADOLINT_VERSION="v2.12.0"
PRETTIER_VERSION="3.9.6" # lintro requires >= 3.9.4
MARKDOWNLINT_CLI2_VERSION="0.23.2"
COMMITLINT_VERSION="21.2.2" # lintro requires @commitlint/cli >= 21.2.1
COMMITLINT_CONFIG_VERSION="21.2.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

retry() {
	# retry <max> <cmd...>
	local max="$1"
	shift
	local attempt=1 delay=4
	until "$@"; do
		if ((attempt >= max)); then
			echo "command failed after ${max} attempts: $*" >&2
			return 1
		fi
		echo "attempt ${attempt} failed; retrying in ${delay}s: $*" >&2
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
	done
}

# ---------------------------------------------------------------------------
# System packages (apt): bats, build toolchain, and kcov build dependencies.
# ---------------------------------------------------------------------------
log "Installing system packages (apt)"
export DEBIAN_FRONTEND=noninteractive
retry 4 sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
	git \
	curl \
	ca-certificates \
	jq \
	bats \
	netcat-openbsd \
	build-essential \
	pkg-config \
	cmake \
	binutils-dev \
	libcurl4-openssl-dev \
	libdw-dev \
	libiberty-dev \
	libssl-dev \
	zlib1g-dev

# ---------------------------------------------------------------------------
# uv (Python package/deps manager) -> install to a PATH-visible location.
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
	log "Installing uv"
	retry 4 bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
	# Make uv available system-wide for every future shell.
	if [[ -x "$HOME/.local/bin/uv" ]]; then
		sudo install -m0755 "$HOME/.local/bin/uv" /usr/local/bin/uv
		[[ -x "$HOME/.local/bin/uvx" ]] && sudo install -m0755 "$HOME/.local/bin/uvx" /usr/local/bin/uvx
	fi
else
	log "uv already installed ($(uv --version))"
fi
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# bats helper libraries (bats-support / bats-assert / bats-file) -> /usr/lib.
# common.bash searches /usr/lib/bats-<name>/load.bash.
# ---------------------------------------------------------------------------
install_bats_lib() {
	local name="$1" version="$2" dest="/usr/lib/$1"
	if [[ -f "$dest/load.bash" ]]; then
		return 0
	fi
	log "Installing $name $version"
	local tmp
	tmp="$(mktemp -d)"
	retry 4 git clone --depth 1 --branch "$version" \
		"https://github.com/bats-core/${name}.git" "$tmp" -q
	sudo rm -rf "$dest"
	sudo mkdir -p "$dest/src"
	sudo cp -r "$tmp/src/." "$dest/src/"
	sudo cp "$tmp/load.bash" "$dest/"
	rm -rf "$tmp"
}
install_bats_lib bats-support "$BATS_SUPPORT_VERSION"
install_bats_lib bats-assert "$BATS_ASSERT_VERSION"
install_bats_lib bats-file "$BATS_FILE_VERSION"

# ---------------------------------------------------------------------------
# kcov (shell-test coverage) -> build from source. On this base image the
# default `cc`/`c++` alternatives point to clang, which cannot resolve
# -lstdc++, so the build is pinned to gcc/g++.
# ---------------------------------------------------------------------------
if ! command -v kcov >/dev/null 2>&1; then
	log "Building kcov ${KCOV_VERSION} from source"
	rm -rf /tmp/kcov-src
	retry 4 git clone --depth 1 --branch "$KCOV_VERSION" \
		https://github.com/SimonKagstrom/kcov.git /tmp/kcov-src
	mkdir -p /tmp/kcov-src/build
	(
		cd /tmp/kcov-src/build
		CC=gcc CXX=g++ cmake ..
		make -j"$(nproc)"
		sudo make install
	)
	rm -rf /tmp/kcov-src
else
	log "kcov already installed ($(kcov --version 2>&1 | head -1))"
fi

# ---------------------------------------------------------------------------
# Standalone lint binaries -> /usr/local/bin (versions enforced by lintro).
# ---------------------------------------------------------------------------
if [[ "$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')" != "${SHELLCHECK_VERSION#v}" ]]; then
	log "Installing shellcheck ${SHELLCHECK_VERSION}"
	tmp="$(mktemp -d)"
	retry 4 curl -fsSL \
		"https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
		-o "$tmp/sc.tar.xz"
	tar -xJf "$tmp/sc.tar.xz" -C "$tmp"
	sudo install -m0755 "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck
	rm -rf "$tmp"
fi

if [[ "$(shfmt --version 2>/dev/null)" != "${SHFMT_VERSION}" ]]; then
	log "Installing shfmt ${SHFMT_VERSION}"
	retry 4 sudo curl -fsSL \
		"https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_amd64" \
		-o /usr/local/bin/shfmt
	sudo chmod +x /usr/local/bin/shfmt
fi

if [[ "$(actionlint --version 2>/dev/null | head -1)" != "${ACTIONLINT_VERSION#v}" ]]; then
	log "Installing actionlint ${ACTIONLINT_VERSION}"
	tmp="$(mktemp -d)"
	retry 4 curl -fsSL \
		"https://github.com/rhysd/actionlint/releases/download/${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION#v}_linux_amd64.tar.gz" \
		-o "$tmp/actionlint.tgz"
	tar -xzf "$tmp/actionlint.tgz" -C "$tmp" actionlint
	sudo install -m0755 "$tmp/actionlint" /usr/local/bin/actionlint
	rm -rf "$tmp"
fi

if ! command -v hadolint >/dev/null 2>&1; then
	log "Installing hadolint ${HADOLINT_VERSION}"
	retry 4 sudo curl -fsSL \
		"https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
		-o /usr/local/bin/hadolint
	sudo chmod +x /usr/local/bin/hadolint
fi

# ---------------------------------------------------------------------------
# Node-based lint tools -> /usr/local (prettier, markdownlint-cli2, commitlint).
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
[[ -s "$HOME/.nvm/nvm.sh" ]] && source "$HOME/.nvm/nvm.sh"
if command -v npm >/dev/null 2>&1; then
	log "Installing node lint tools (prettier, markdownlint-cli2, commitlint)"
	retry 4 sudo env "PATH=$PATH" npm install -g --prefix /usr/local --no-fund --no-audit \
		"prettier@${PRETTIER_VERSION}" \
		"markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}" \
		"@commitlint/cli@${COMMITLINT_VERSION}" \
		"@commitlint/config-conventional@${COMMITLINT_CONFIG_VERSION}"
else
	echo "WARNING: npm not found; skipping node-based lint tools" >&2
fi

# ---------------------------------------------------------------------------
# Python project dependencies + venv-local lint tools.
# lintro invokes bandit/mypy via the project venv's python and finds yamllint
# on the venv PATH, so these must live in .venv (not just on the system).
# ---------------------------------------------------------------------------
log "Syncing Python dependencies (uv sync --extra dev)"
cd "$REPO_ROOT"
retry 4 uv sync --extra dev
log "Installing venv-local lint tools (yamllint, bandit, mypy)"
retry 4 uv pip install "yamllint>=1.37.1" "bandit>=1.9.4" "mypy>=1.19.1"

log "Environment bootstrap complete"
if [[ "$ARCH" != "x86_64" ]]; then
	echo "NOTE: binaries are pinned for x86_64; detected $ARCH" >&2
fi
