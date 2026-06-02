#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install cargo-nextest and optional cargo-llvm-cov for Rust CI.

set -euo pipefail

: "${INSTALL_COVERAGE_TOOLS:=false}"
: "${CARGO_NEXTEST_VERSION:=0.9.92}"
: "${CARGO_LLVM_COV_VERSION:=0.8.6}"

_install_cargo_crate() {
	local crate="$1"
	local version="$2"

	if command -v "$crate" >/dev/null 2>&1; then
		if "$crate" --version 2>/dev/null | grep -qE "^${crate} ${version}(\$| )"; then
			return 0
		fi
		echo "Found ${crate} but not pinned ${version}; reinstalling..."
	fi

	echo "Installing ${crate} ${version}..."
	if command -v cargo-binstall >/dev/null 2>&1; then
		cargo binstall "$crate" \
			--version "$version" \
			--no-confirm ||
			cargo install "$crate" \
				--locked \
				--version "$version"
	else
		cargo install "$crate" \
			--locked \
			--version "$version"
	fi
}

_install_cargo_crate "cargo-nextest" "$CARGO_NEXTEST_VERSION"

if [[ "$INSTALL_COVERAGE_TOOLS" == "true" ]]; then
	rustup component add llvm-tools-preview
	_install_cargo_crate "cargo-llvm-cov" "$CARGO_LLVM_COV_VERSION"
fi
