#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify git tag matches Cargo.toml workspace version
#
# Usage:
#   TAG=v1.0.0 VERSION_FILE=Cargo.toml scripts/ci/release/verify-rust-release-tag.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/cargo/version.sh
source "$SCRIPT_DIR/../lib/cargo/version.sh"

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

cargo_version="$(parse_cargo_version "$VERSION_FILE")"

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
