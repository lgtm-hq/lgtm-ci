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
		# Pinned release binary download (no pipe-to-bash of main-branch
		# script). cargo-binstall publishes minisign signatures (.sig)
		# but no sha256 checksum files, so pinning the version + TLS is
		# the integrity control here.
		# renovate: datasource=github-releases depName=cargo-bins/cargo-binstall
		CARGO_BINSTALL_VERSION="1.20.1"
		echo "Installing cargo-binstall v${CARGO_BINSTALL_VERSION}..."

		os=$(uname -s)
		arch=$(uname -m)
		case "$os" in
		Linux)
			case "$arch" in
			x86_64) target="x86_64-unknown-linux-musl" ;;
			aarch64 | arm64) target="aarch64-unknown-linux-musl" ;;
			*)
				echo "Unsupported architecture: $arch"
				exit 1
				;;
			esac
			ext="tgz"
			;;
		Darwin)
			target="universal-apple-darwin"
			ext="zip"
			;;
		*)
			echo "Unsupported OS: $os"
			exit 1
			;;
		esac

		url="https://github.com/cargo-bins/cargo-binstall/releases/download/v${CARGO_BINSTALL_VERSION}/cargo-binstall-${target}.${ext}"
		tmpdir=$(mktemp -d)
		trap 'rm -rf "$tmpdir"' EXIT

		echo "Downloading pinned release: $url"
		curl -L --proto '=https' --tlsv1.2 -sSf -o "$tmpdir/cargo-binstall.$ext" "$url"

		if [[ "$ext" == "tgz" ]]; then
			tar -xzf "$tmpdir/cargo-binstall.$ext" -C "$tmpdir"
		else
			unzip -q "$tmpdir/cargo-binstall.$ext" -d "$tmpdir"
		fi

		install_dir="${CARGO_HOME:-$HOME/.cargo}/bin"
		mkdir -p "$install_dir"
		install -m 0755 "$tmpdir/cargo-binstall" "$install_dir/cargo-binstall"
		echo "cargo-binstall v${CARGO_BINSTALL_VERSION} installed to $install_dir"
	else
		echo "cargo-binstall already installed"
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
