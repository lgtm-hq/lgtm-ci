#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Read workspace or package version from Cargo.toml
#
# Usage:
#   VERSION_FILE=Cargo.toml scripts/ci/release/read-cargo-version.sh
#
# Writes version to GITHUB_OUTPUT when set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/github/output.sh
source "$LIB_DIR/github/output.sh"

VERSION_FILE="${VERSION_FILE:-Cargo.toml}"

if [[ ! -f "$VERSION_FILE" ]]; then
	echo "Cargo manifest not found: $VERSION_FILE" >&2
	exit 1
fi

version="$(
	awk -F'"' '
/^\[package\]/ || /^\[workspace\.package\]/ { in_pkg = 1 }
/^\[/ && !/^\[package\]/ && !/^\[workspace\.package\]/ { in_pkg = 0 }
in_pkg && /^version[[:space:]]*=/ { print $2; exit }
' "$VERSION_FILE"
)"

if [[ -z "$version" ]]; then
	echo "version not found in $VERSION_FILE ([package] or [workspace.package])" >&2
	exit 1
fi

set_github_output "version" "$version"
echo "Cargo version: $version"
