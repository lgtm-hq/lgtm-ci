#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build release binaries for a Rust target (cargo or cross)
#
# Usage:
#   TARGET=x86_64-unknown-linux-gnu PACKAGES=cli,server \
#     scripts/ci/release/build-rust-binary.sh

set -euo pipefail

TARGET="${TARGET:-}"
PACKAGES="${PACKAGES:-}"

if [[ -z "$TARGET" || -z "$PACKAGES" ]]; then
	echo "TARGET and PACKAGES are required" >&2
	exit 1
fi

BUILD_CMD="cargo"
if [[ "${USE_CROSS:-}" == "true" ]]; then
	BUILD_CMD="cross"
fi

IFS=',' read -r -a package_list <<<"$PACKAGES"
for package in "${package_list[@]}"; do
	package="${package// /}"
	[[ -z "$package" ]] && continue
	echo "Building $package with $BUILD_CMD for target $TARGET"
	$BUILD_CMD build --release --target "$TARGET" -p "$package"
done
