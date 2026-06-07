#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify git tag matches Cargo.toml workspace version
#
# Usage:
#   TAG=v1.0.0 VERSION_FILE=Cargo.toml scripts/ci/release/verify-rust-release-tag.sh

set -euo pipefail

TAG="${TAG:-${GITHUB_REF_NAME:-}}"
VERSION_FILE="${VERSION_FILE:-Cargo.toml}"

if [[ -z "$TAG" ]]; then
	echo "TAG is required" >&2
	exit 1
fi

if [[ ! -f "$VERSION_FILE" ]]; then
	echo "Cargo manifest not found: $VERSION_FILE" >&2
	exit 1
fi

cargo_version="$(
	awk -F'"' '
/^\[package\]/ || /^\[workspace\.package\]/ { in_pkg = 1 }
/^\[/ && !/^\[package\]/ && !/^\[workspace\.package\]/ { in_pkg = 0 }
in_pkg && /^version[[:space:]]*=/ { print $2; exit }
' "$VERSION_FILE"
)"

if [[ -z "$cargo_version" ]]; then
	echo "version not found in $VERSION_FILE" >&2
	exit 1
fi

expected="v${cargo_version}"
if [[ "$TAG" != "$expected" ]]; then
	echo "Tag mismatch: $TAG != Cargo.toml $expected" >&2
	exit 1
fi

echo "Tag $TAG matches Cargo.toml version $cargo_version"
