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

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/cargo/version.sh
source "$LIB_DIR/cargo/version.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/release/version.sh
source "$LIB_DIR/release/version.sh"

VERSION_FILE="${VERSION_FILE:-Cargo.toml}"

if [[ ! -f "$VERSION_FILE" ]]; then
	echo "Cargo manifest not found: $VERSION_FILE" >&2
	exit 1
fi

version="$(parse_cargo_version "$VERSION_FILE" || true)"

if [[ -z "$version" ]]; then
	log_error "version not found in $VERSION_FILE ([package] or [workspace.package])"
	set_github_output "version" ""
	set_github_output "found" "false"
	exit 1
fi

if ! validate_semver "$version"; then
	log_error "Cargo version is not valid semver: $version"
	set_github_output "version" ""
	set_github_output "found" "false"
	exit 1
fi

log_success "Cargo version: $version"
set_github_output "version" "$version"
set_github_output "found" "true"
echo "version=$version"
echo "found=true"
