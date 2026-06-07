#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Parse Cargo.toml workspace or package version fields
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/version.sh"
#   parse_cargo_version "Cargo.toml"

[[ -n "${_LGTM_CI_CARGO_VERSION_LOADED:-}" ]] && return 0
readonly _LGTM_CI_CARGO_VERSION_LOADED=1

# Parse version from [package] or [workspace.package] in a Cargo manifest.
# Prints version on stdout; returns 1 when not found or file missing.
parse_cargo_version() {
	local file="${1:?cargo manifest path required}"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	awk -F'"' '
/^\[package\]/ || /^\[workspace\.package\]/ { in_pkg = 1 }
/^\[/ && !/^\[package\]/ && !/^\[workspace\.package\]/ { in_pkg = 0 }
in_pkg && /^version[[:space:]]*=/ { print $2; exit }
' "$file"
}
