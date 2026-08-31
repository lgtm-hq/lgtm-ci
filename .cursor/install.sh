#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Idempotent Cloud Agent bootstrap for the lgtm-ci development
# environment. Installs the toolchain needed to run the repository's canonical
# developer commands:
#
#   uv sync --frozen --extra dev # Python quality tooling (lintro, ruff, black)
#   make lint                    # uv run lintro chk  (native tool parity)
#   make test                    # bats --recursive tests/bats (shell tests)
#   shell coverage               # kcov (STEP=run-coverage run-bats-tests.sh)
#
# The script is safe to run repeatedly: every step is guarded so a second run
# is a fast no-op. It mirrors the tool versions enforced by lintro (which CI
# runs inside the pinned ghcr.io/lgtm-hq/py-lintro image) so `make lint` runs
# the real tools locally instead of skipping them.
#
# Supply-chain posture, stated precisely so the guarantees are not overread:
#   * Downloaded artifacts (uv installer, shellcheck, shfmt, actionlint,
#     hadolint) are fetched from version-pinned URLs into a temp dir and
#     SHA-256 verified before they are executed or installed. Nothing is piped
#     into a shell, so a compromised endpoint fails the bootstrap closed.
#   * Git-cloned sources (bats helper libs, kcov) are pinned to immutable
#     commit SHAs: tags are mutable, so each clone's HEAD is asserted against
#     the pinned commit before any file is copied or built.
#   * apt and npm packages are trusted to their respective registries; npm
#     versions are pinned, apt packages are not.
#   * Version pins are enforced even when a tool is already on PATH (uv,
#     hadolint, shellcheck, shfmt, actionlint, kcov): an off-pin binary is
#     reinstalled rather than silently used. The bats helper libraries expose
#     no version marker, so an already-present copy is trusted as-is and only
#     a fresh install is commit-verified.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned tool versions
# ---------------------------------------------------------------------------
UV_VERSION="0.11.26"
KCOV_VERSION="v43"
BATS_SUPPORT_VERSION="v0.3.0"
BATS_ASSERT_VERSION="v2.2.4"
BATS_FILE_VERSION="v0.4.0"

# Immutable commit each tag above resolved to (the peeled commit for annotated
# tags). Tags can be moved upstream; these cannot. Refresh with:
#   git ls-remote <url> refs/tags/<tag> 'refs/tags/<tag>^{}'
KCOV_COMMIT="a39874f938ce13f7a65f253120d1ec946b349ffe"
BATS_SUPPORT_COMMIT="24a72e14349690bcbf7c151b9d2d1cdd32d36eb1"
BATS_ASSERT_COMMIT="f1e9280eaae8f86cbe278a687e6ba755bc802c1a"
BATS_FILE_COMMIT="13ad5e2ffcc360281432db3d43a306f7b3667d60"

SHELLCHECK_VERSION="v0.11.0" # lintro requires >= 0.11.0
SHFMT_VERSION="v3.13.1"      # lintro requires >= 3.13.1
ACTIONLINT_VERSION="v1.7.12" # lintro requires >= 1.7.12
HADOLINT_VERSION="v2.12.0"
PRETTIER_VERSION="3.9.6" # lintro requires >= 3.9.4
MARKDOWNLINT_CLI2_VERSION="0.23.2"
COMMITLINT_VERSION="21.2.2" # lintro requires @commitlint/cli >= 21.2.1
COMMITLINT_CONFIG_VERSION="21.2.0"

# ---------------------------------------------------------------------------
# SHA-256 digests of the pinned artifacts downloaded below. Recompute with
# `curl -fsSL <url> | shasum -a 256` when bumping any of the versions above.
# ---------------------------------------------------------------------------
UV_INSTALLER_URL="https://astral.sh/uv/${UV_VERSION}/install.sh"
UV_INSTALLER_SHA256="92fa9085d24c214bb4445cc1da8c15ca9cca8cffb34726240fa08c5302e94ccc"
SHELLCHECK_URL="https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
SHELLCHECK_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
SHFMT_URL="https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_amd64"
SHFMT_SHA256="fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1"
ACTIONLINT_URL="https://github.com/rhysd/actionlint/releases/download/${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION#v}_linux_amd64.tar.gz"
ACTIONLINT_SHA256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
HADOLINT_URL="https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-x86_64"
HADOLINT_SHA256="56de6d5e5ec427e17b74fa48d51271c7fc0d61244bf5c90e828aab8362d55010"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"

# Every downloaded binary above is an x86_64 Linux artifact, and the digests
# pin those exact files. Bail before anything is fetched rather than installing
# binaries that cannot run on this host.
if [[ "$ARCH" != "x86_64" ]]; then
	echo "Unsupported architecture: ${ARCH}. This bootstrap installs x86_64 Linux binaries only." >&2
	exit 1
fi

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

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# fetch_verified <url> <sha256> <dest>: download to a file and fail closed on a
# digest mismatch instead of installing or executing unverified remote content.
fetch_verified() {
	local url="$1" expected="$2" dest="$3" actual
	retry 4 curl -fsSL "$url" -o "$dest"
	actual="$(sha256_of "$dest")"
	if [[ "$actual" != "$expected" ]]; then
		echo "Checksum mismatch for ${url}: expected ${expected}, got ${actual}" >&2
		exit 1
	fi
}

# clone_pinned <url> <tag> <commit> <dest>: shallow-clone a tag, then assert the
# resolved HEAD matches the pinned commit. Tags are mutable upstream, so the tag
# only selects what to fetch; the commit SHA is what is actually trusted. Fails
# closed before the caller copies or builds anything from the tree.
clone_pinned() {
	local url="$1" tag="$2" commit="$3" dest="$4" actual
	retry 4 git clone --depth 1 --branch "$tag" -q "$url" "$dest"
	actual="$(git -C "$dest" rev-parse HEAD)"
	if [[ "$actual" != "$commit" ]]; then
		echo "Commit mismatch for ${url}@${tag}: expected ${commit}, got ${actual}" >&2
		exit 1
	fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"

uv_installed="$(command -v uv >/dev/null 2>&1 && uv --version 2>/dev/null | awk '{print $2}' || true)"
if [[ "$uv_installed" != "$UV_VERSION" ]]; then
	log "Installing uv ${UV_VERSION} (found: ${uv_installed:-none})"
	fetch_verified "$UV_INSTALLER_URL" "$UV_INSTALLER_SHA256" "$tmp_dir/uv-install.sh"
	sh "$tmp_dir/uv-install.sh"
	# Make uv available system-wide for every future shell.
	if [[ -x "$HOME/.local/bin/uv" ]]; then
		sudo install -m0755 "$HOME/.local/bin/uv" /usr/local/bin/uv
		[[ -x "$HOME/.local/bin/uvx" ]] && sudo install -m0755 "$HOME/.local/bin/uvx" /usr/local/bin/uvx
	fi
else
	log "uv already on pin (${UV_VERSION})"
fi

# Drop bash's cached command paths so the probe above cannot pin an off-pin
# executable found before the installer ran, then assert the pin resolved.
hash -r
uv_final="$(uv --version | awk '{print $2}')"
if [[ "$uv_final" != "$UV_VERSION" ]]; then
	echo "uv pin not resolved: got ${uv_final}, want ${UV_VERSION}" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# bats helper libraries (bats-support / bats-assert / bats-file) -> /usr/lib.
# common.bash searches /usr/lib/bats-<name>/load.bash.
# ---------------------------------------------------------------------------
# These libraries ship no version marker, so an already-installed copy is
# trusted as-is; only a fresh install is fetched, and that install is pinned to
# an immutable commit.
install_bats_lib() {
	local name="$1" version="$2" commit="$3" dest="/usr/lib/$1"
	if [[ -f "$dest/load.bash" ]]; then
		return 0
	fi
	log "Installing $name $version ($commit)"
	local src="$tmp_dir/$name"
	rm -rf "$src"
	clone_pinned "https://github.com/bats-core/${name}.git" "$version" "$commit" "$src"
	sudo rm -rf "$dest"
	sudo mkdir -p "$dest/src"
	sudo cp -r "$src/src/." "$dest/src/"
	sudo cp "$src/load.bash" "$dest/"
	rm -rf "$src"
}
install_bats_lib bats-support "$BATS_SUPPORT_VERSION" "$BATS_SUPPORT_COMMIT"
install_bats_lib bats-assert "$BATS_ASSERT_VERSION" "$BATS_ASSERT_COMMIT"
install_bats_lib bats-file "$BATS_FILE_VERSION" "$BATS_FILE_COMMIT"

# ---------------------------------------------------------------------------
# kcov (shell-test coverage) -> build from source. On this base image the
# default `cc`/`c++` alternatives point to clang, which cannot resolve
# -lstdc++, so the build is pinned to gcc/g++.
# ---------------------------------------------------------------------------
# kcov prints "kcov <version>", where the version is `git describe` output for
# a git build ("v43") and the bare ChangeLog number for a tarball build ("43").
# Normalise the leading "v" away before comparing so either form converges.
# The `|| true` keeps a missing kcov (pipefail-propagated 127) from aborting.
kcov_installed="$(kcov --version 2>/dev/null | head -1 | awk '{print $2}' || true)"
if [[ "${kcov_installed#v}" != "${KCOV_VERSION#v}" ]]; then
	log "Building kcov ${KCOV_VERSION} from source (found: ${kcov_installed:-none})"
	rm -rf /tmp/kcov-src
	clone_pinned https://github.com/SimonKagstrom/kcov.git \
		"$KCOV_VERSION" "$KCOV_COMMIT" /tmp/kcov-src
	mkdir -p /tmp/kcov-src/build
	(
		cd /tmp/kcov-src/build
		CC=gcc CXX=g++ cmake ..
		make -j"$(nproc)"
		sudo make install
	)
	rm -rf /tmp/kcov-src
	hash -r
	kcov_final="$(kcov --version 2>/dev/null | head -1 | awk '{print $2}' || true)"
	if [[ "${kcov_final#v}" != "${KCOV_VERSION#v}" ]]; then
		echo "kcov pin not resolved: got ${kcov_final:-none}, want ${KCOV_VERSION}" >&2
		exit 1
	fi
else
	log "kcov already on pin (${KCOV_VERSION})"
fi

# ---------------------------------------------------------------------------
# Standalone lint binaries -> /usr/local/bin (versions enforced by lintro).
# ---------------------------------------------------------------------------
if [[ "$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')" != "${SHELLCHECK_VERSION#v}" ]]; then
	log "Installing shellcheck ${SHELLCHECK_VERSION}"
	fetch_verified "$SHELLCHECK_URL" "$SHELLCHECK_SHA256" "$tmp_dir/shellcheck.tar.xz"
	tar -xJf "$tmp_dir/shellcheck.tar.xz" -C "$tmp_dir"
	sudo install -m0755 \
		"$tmp_dir/shellcheck-${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck
fi

if [[ "$(shfmt --version 2>/dev/null)" != "${SHFMT_VERSION}" ]]; then
	log "Installing shfmt ${SHFMT_VERSION}"
	fetch_verified "$SHFMT_URL" "$SHFMT_SHA256" "$tmp_dir/shfmt"
	sudo install -m0755 "$tmp_dir/shfmt" /usr/local/bin/shfmt
fi

if [[ "$(actionlint --version 2>/dev/null | head -1)" != "${ACTIONLINT_VERSION#v}" ]]; then
	log "Installing actionlint ${ACTIONLINT_VERSION}"
	fetch_verified "$ACTIONLINT_URL" "$ACTIONLINT_SHA256" "$tmp_dir/actionlint.tgz"
	tar -xzf "$tmp_dir/actionlint.tgz" -C "$tmp_dir" actionlint
	sudo install -m0755 "$tmp_dir/actionlint" /usr/local/bin/actionlint
fi

# hadolint prints "Haskell Dockerfile Linter <version>"; enforce the pin rather
# than accepting whatever version happens to be preinstalled.
if [[ "$(hadolint --version 2>/dev/null | awk '{print $NF}')" != "${HADOLINT_VERSION#v}" ]]; then
	log "Installing hadolint ${HADOLINT_VERSION}"
	fetch_verified "$HADOLINT_URL" "$HADOLINT_SHA256" "$tmp_dir/hadolint"
	sudo install -m0755 "$tmp_dir/hadolint" /usr/local/bin/hadolint
fi

hash -r

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
	echo "ERROR: npm not found. prettier, markdownlint-cli2 and commitlint are required for native lint-tool parity with CI; \`make lint\` would silently skip them." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Python project dependencies. lintro invokes bandit/mypy via the project
# venv's python and finds yamllint on the venv PATH, so those live in the dev
# extra and arrive with the frozen sync (no floating pip installs on top).
# ---------------------------------------------------------------------------
log "Syncing Python dependencies (uv sync --frozen --extra dev)"
cd "$REPO_ROOT"
retry 4 uv sync --frozen --extra dev

log "Environment bootstrap complete"
