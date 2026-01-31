#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: SBOM format utilities (extension, validation)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/format.sh"
#   get_sbom_extension "cyclonedx-json"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_SBOM_FORMAT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_SBOM_FORMAT_LOADED=1

# =============================================================================
# SBOM Format Constants
# =============================================================================

# Supported SBOM formats
readonly SBOM_FORMAT_CYCLONEDX_JSON="cyclonedx-json"
readonly SBOM_FORMAT_SPDX_JSON="spdx-json"
readonly SBOM_FORMAT_CYCLONEDX_XML="cyclonedx-xml"
readonly SBOM_FORMAT_SPDX_TV="spdx-tag-value"
readonly SBOM_FORMAT_SYFT_JSON="syft-json"

# =============================================================================
# SBOM Format Functions
# =============================================================================

# Get file extension for an SBOM format
# Usage: get_sbom_extension "cyclonedx-json"
# Returns: .cdx.json (or appropriate extension)
get_sbom_extension() {
	local format="$1"

	case "$format" in
	cyclonedx-json | cdx-json)
		echo ".cdx.json"
		;;
	cyclonedx-xml | cdx-xml)
		echo ".cdx.xml"
		;;
	spdx-json)
		echo ".spdx.json"
		;;
	spdx-tag-value | spdx-tv)
		echo ".spdx"
		;;
	syft-json)
		echo ".syft.json"
		;;
	*)
		echo ".sbom.json"
		;;
	esac
}

# Validate SBOM format is supported
# Usage: validate_sbom_format "cyclonedx-json"
# Returns: 0 if valid, 1 if invalid
validate_sbom_format() {
	local format="$1"

	case "$format" in
	cyclonedx-json | cdx-json | \
		cyclonedx-xml | cdx-xml | \
		spdx-json | \
		spdx-tag-value | spdx-tv | \
		syft-json)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Normalize SBOM format name to canonical form
# Usage: normalize_sbom_format "cdx-json"
# Returns: cyclonedx-json
normalize_sbom_format() {
	local format="$1"

	case "$format" in
	cdx-json)
		echo "cyclonedx-json"
		;;
	cdx-xml)
		echo "cyclonedx-xml"
		;;
	spdx-tv)
		echo "spdx-tag-value"
		;;
	*)
		echo "$format"
		;;
	esac
}

# Get the MIME type for an SBOM format
# Usage: get_sbom_mime_type "cyclonedx-json"
get_sbom_mime_type() {
	local format="$1"

	case "$format" in
	cyclonedx-json | cdx-json)
		echo "application/vnd.cyclonedx+json"
		;;
	cyclonedx-xml | cdx-xml)
		echo "application/vnd.cyclonedx+xml"
		;;
	spdx-json)
		echo "application/spdx+json"
		;;
	spdx-tag-value | spdx-tv)
		echo "text/spdx"
		;;
	syft-json)
		echo "application/json"
		;;
	*)
		echo "application/octet-stream"
		;;
	esac
}

# =============================================================================
# Export functions
# =============================================================================
export -f get_sbom_extension validate_sbom_format normalize_sbom_format get_sbom_mime_type
