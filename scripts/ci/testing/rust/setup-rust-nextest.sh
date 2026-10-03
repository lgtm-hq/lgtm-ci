#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install cargo-nextest and optional cargo-llvm-cov for Rust CI.

set -euo pipefail

: "${INSTALL_COVERAGE_TOOLS:=false}"
# renovate: datasource=github-releases depName=nextest-rs/nextest extractVersion=^cargo-nextest-(?<version>.+)$
DEFAULT_CARGO_NEXTEST_VERSION="0.9.92"
CARGO_NEXTEST_VERSION="${CARGO_NEXTEST_VERSION:-$DEFAULT_CARGO_NEXTEST_VERSION}"
# renovate: datasource=github-releases depName=taiki-e/cargo-llvm-cov
DEFAULT_CARGO_LLVM_COV_VERSION="0.8.6"
CARGO_LLVM_COV_VERSION="${CARGO_LLVM_COV_VERSION:-$DEFAULT_CARGO_LLVM_COV_VERSION}"

_install_cargo_crate() {
	local crate="$1"
	local version="$2"

	if command -v "$crate" >/dev/null 2>&1; then
		if "$crate" --version 2>/dev/null | grep -qE "^${crate} ${version}(\$| )"; then
			echo "${crate} ${version} already installed, skipping"
			return 0
		fi
		echo "Found ${crate} but not pinned ${version}; reinstalling..."
	fi

	echo "Installing ${crate} ${version}..."
	if command -v cargo-binstall >/dev/null 2>&1; then
		cargo binstall "$crate" \
			--version "$version" \
			--force \
			--no-confirm ||
			cargo install "$crate" \
				--locked \
				--force \
				--version "$version"
	else
		cargo install "$crate" \
			--locked \
			--force \
			--version "$version"
	fi
}

_install_cargo_crate "cargo-nextest" "$CARGO_NEXTEST_VERSION"

if [[ "$INSTALL_COVERAGE_TOOLS" == "true" ]]; then
	rustup component add llvm-tools-preview
	_install_cargo_crate "cargo-llvm-cov" "$CARGO_LLVM_COV_VERSION"
fi
