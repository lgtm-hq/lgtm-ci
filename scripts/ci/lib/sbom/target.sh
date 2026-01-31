#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Target type resolution for SBOM tools (Syft, Grype)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/target.sh"
#   target=$(resolve_scan_target "/path/to/dir" "dir")

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_SBOM_TARGET_LOADED:-}" ]] && return 0
readonly _LGTM_CI_SBOM_TARGET_LOADED=1

# =============================================================================
# Target Resolution Functions
# =============================================================================

# Resolve target path to scanner-compatible format
# Usage: resolve_scan_target "/path" "dir"
# Args:
#   $1 - target path or reference
#   $2 - target type (dir, image, file, sbom)
# Returns: formatted target string via stdout
# Exit: 1 if unsupported target type
resolve_scan_target() {
	local target="$1"
	local target_type="$2"

	case "$target_type" in
	dir | directory)
		echo "dir:${target}"
		;;
	image | container)
		# Images don't need a prefix
		echo "${target}"
		;;
	file)
		echo "file:${target}"
		;;
	sbom)
		echo "sbom:${target}"
		;;
	*)
		echo "Unsupported target type: $target_type" >&2
		return 1
		;;
	esac
}

# Validate target exists based on type
# Usage: validate_scan_target "/path" "dir"
# Returns: 0 if valid, 1 if invalid
validate_scan_target() {
	local target="$1"
	local target_type="$2"

	case "$target_type" in
	dir | directory)
		[[ -d "$target" ]]
		;;
	file | sbom)
		[[ -f "$target" ]]
		;;
	image | container)
		# Images are validated by the scanner itself
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Get human-readable description of target type
# Usage: describe_target_type "dir"
describe_target_type() {
	local target_type="$1"

	case "$target_type" in
	dir | directory)
		echo "directory"
		;;
	image | container)
		echo "container image"
		;;
	file)
		echo "file"
		;;
	sbom)
		echo "SBOM file"
		;;
	*)
		echo "unknown"
		;;
	esac
}

# =============================================================================
# Export functions
# =============================================================================
export -f resolve_scan_target validate_scan_target describe_target_type
