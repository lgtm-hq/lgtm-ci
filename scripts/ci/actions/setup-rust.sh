#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Setup Rust environment
#
# Required environment variables:
#   STEP - Which step to run: version, cargo-env, or binstall

set -euo pipefail

: "${STEP:?STEP is required}"

case "$STEP" in
version)
	rustc_version=$(rustc --version | awk '{print $2}')
	cargo_version=$(cargo --version | awk '{print $2}')
	echo "rustc=$rustc_version" >>"$GITHUB_OUTPUT"
	echo "cargo=$cargo_version" >>"$GITHUB_OUTPUT"
	echo "rustc version: $rustc_version"
	echo "cargo version: $cargo_version"
	;;

cargo-env)
	# Use sparse registry protocol for faster downloads
	echo "CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse" >>"$GITHUB_ENV"
	# Incremental compilation is not useful in CI
	echo "CARGO_INCREMENTAL=0" >>"$GITHUB_ENV"
	# More readable backtraces
	echo "RUST_BACKTRACE=short" >>"$GITHUB_ENV"
	;;

binstall)
	if ! command -v cargo-binstall &>/dev/null; then
		echo "Installing cargo-binstall..."
		curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
	else
		echo "cargo-binstall already installed"
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
