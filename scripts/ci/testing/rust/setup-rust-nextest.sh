#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install cargo-nextest and optional cargo-llvm-cov for Rust CI.
#
# Versions come from scripts/ci/versions.env (CARGO_NEXTEST_VERSION /
# CARGO_LLVM_COV_VERSION env vars override). Each tool is downloaded as the
# upstream release archive for the host target and verified against the
# sha256 committed in versions.env before anything is placed on PATH (#1096).
#
# Targets with a committed digest: x86_64-unknown-linux-gnu,
# aarch64-unknown-linux-gnu, universal-apple-darwin, x86_64-pc-windows-msvc.
# Any other host falls back to `cargo install --locked`, where crates.io is
# the trust root (registry-side checksums, lockfile-pinned dependency graph)
# and no committed archive digest applies. That fallback carries an
# `# unverified-fallback:` marker so the installer contract test
# (tests/bats/unit/renovate/test_installer_verification.bats) sees it, and is
# documented in docs/workflow-contract.md.
#
# A binary already on PATH at the pinned version is reused without a digest
# check: the setup-rust action restores ~/.cargo/bin from the Actions cache,
# which is scoped to this repository and ref, so that shortcut trusts the
# consumer's own prior job rather than a fresh download (accepted, #1096).
#
# Overriding a version requires the matching CARGO_<TOOL>_SHA256_<TARGET> env
# var, or LGTM_CI_ALLOW_UNVERIFIED=1 (see scripts/ci/lib/supply_chain.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/network/download.sh
source "$LIB_DIR/network/download.sh"
# shellcheck source=../../lib/supply_chain.sh
source "$LIB_DIR/supply_chain.sh"
# shellcheck source=../../versions.env
source "$SCRIPT_DIR/../../versions.env"

: "${INSTALL_COVERAGE_TOOLS:=false}"
# Scratch dir of the in-flight download; cleaned on every exit path, including
# the exit inside supply_chain_verify_sha256 on a digest mismatch.
_NEXTEST_TMP=""
trap 'rm -rf "${_NEXTEST_TMP:-}"' EXIT
CARGO_NEXTEST_VERSION="${CARGO_NEXTEST_VERSION:-$DEFAULT_CARGO_NEXTEST_VERSION}"
CARGO_LLVM_COV_VERSION="${CARGO_LLVM_COV_VERSION:-$DEFAULT_CARGO_LLVM_COV_VERSION}"

# Host target triple as the upstream release archives name it, or empty when
# no digest is committed for this host.
_host_target() {
	local os arch
	os="$(uname -s)"
	arch="$(uname -m)"
	case "$os" in
	Linux)
		case "$arch" in
		x86_64) echo "x86_64-unknown-linux-gnu" ;;
		aarch64 | arm64) echo "aarch64-unknown-linux-gnu" ;;
		*) echo "" ;;
		esac
		;;
	Darwin) echo "universal-apple-darwin" ;;
	MINGW* | MSYS* | CYGWIN*)
		case "$arch" in
		x86_64) echo "x86_64-pc-windows-msvc" ;;
		*) echo "" ;;
		esac
		;;
	*) echo "" ;;
	esac
}

# Download the release archive for one tool, verify it against the committed
# digest, and extract the binary into $CARGO_HOME/bin.
# Usage: _install_from_release crate version default_version url archive
_install_from_release() {
	local crate="$1" version="$2" default_version="$3" url="$4" archive="$5"
	local target var_tool bin_dir tmp binary
	target="$(_host_target)"
	var_tool="$(supply_chain_var_suffix "$crate")"
	bin_dir="${CARGO_HOME:-$HOME/.cargo}/bin"
	binary="$crate"
	case "$target" in
	*windows*) binary="${crate}.exe" ;;
	esac

	tmp="$(mktemp -d "${TMPDIR:-/tmp}/lgtm-ci-${crate}.XXXXXXXXXX")"
	_NEXTEST_TMP="$tmp"
	echo "Downloading ${archive} from the ${crate} ${version} release..."
	if ! download_with_retries "$url" "${tmp}/${archive}"; then
		echo "::error::failed to download ${url}" >&2
		exit 1
	fi
	supply_chain_verify_sha256 "${tmp}/${archive}" \
		"${var_tool}_SHA256_$(supply_chain_var_suffix "$target")" \
		"$version" "$default_version"
	tar -xzf "${tmp}/${archive}" -C "$tmp"
	# nextest archives place the binary at the top level; llvm-cov archives
	# may nest it one directory down. Accept either, reject anything else.
	local found
	found="$(find "$tmp" -maxdepth 2 -type f -name "$binary" | head -n 1)"
	if [[ -z "$found" ]]; then
		echo "::error::${archive} does not contain ${binary}" >&2
		exit 1
	fi
	mkdir -p "$bin_dir"
	install -m 0755 "$found" "${bin_dir}/${binary}"
	rm -rf "$tmp"
	_NEXTEST_TMP=""
	echo "${crate} ${version} installed to ${bin_dir}"
}

_install_cargo_crate() {
	local crate="$1"
	local version="$2"
	local default_version="$3"
	local target

	if command -v "$crate" >/dev/null 2>&1; then
		if "$crate" --version 2>/dev/null | grep -qE "^${crate} ${version}(\$| )"; then
			echo "${crate} ${version} already installed, skipping"
			return 0
		fi
		echo "Found ${crate} but not pinned ${version}; reinstalling..."
	fi

	echo "Installing ${crate} ${version}..."
	target="$(_host_target)"
	if [[ -z "$target" ]]; then
		echo "::notice::no committed digest for ${crate} on $(uname -s)/$(uname -m); installing from crates.io with --locked"
		# unverified-fallback: no committed archive digest for this host; crates.io is the trust root (registry checksums, --locked graph)
		cargo install "$crate" \
			--locked \
			--force \
			--version "$version"
		return 0
	fi

	case "$crate" in
	cargo-nextest)
		_install_from_release "$crate" "$version" "$default_version" \
			"https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-${version}/cargo-nextest-${version}-${target}.tar.gz" \
			"cargo-nextest-${version}-${target}.tar.gz"
		;;
	cargo-llvm-cov)
		_install_from_release "$crate" "$version" "$default_version" \
			"https://github.com/taiki-e/cargo-llvm-cov/releases/download/v${version}/cargo-llvm-cov-${target}.tar.gz" \
			"cargo-llvm-cov-${target}.tar.gz"
		;;
	*)
		echo "::error::unknown crate ${crate}" >&2
		exit 1
		;;
	esac
}

_install_cargo_crate "cargo-nextest" "$CARGO_NEXTEST_VERSION" "$DEFAULT_CARGO_NEXTEST_VERSION"

if [[ "$INSTALL_COVERAGE_TOOLS" == "true" ]]; then
	rustup component add llvm-tools-preview
	_install_cargo_crate "cargo-llvm-cov" "$CARGO_LLVM_COV_VERSION" "$DEFAULT_CARGO_LLVM_COV_VERSION"
fi
