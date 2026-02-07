#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/sbom/format.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# get_sbom_extension tests
# =============================================================================

@test "get_sbom_extension: returns .cdx.json for cyclonedx-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "cyclonedx-json"'
	assert_success
	assert_output ".cdx.json"
}

@test "get_sbom_extension: returns .cdx.json for cdx-json alias" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "cdx-json"'
	assert_success
	assert_output ".cdx.json"
}

@test "get_sbom_extension: returns .cdx.xml for cyclonedx-xml" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "cyclonedx-xml"'
	assert_success
	assert_output ".cdx.xml"
}

@test "get_sbom_extension: returns .cdx.xml for cdx-xml alias" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "cdx-xml"'
	assert_success
	assert_output ".cdx.xml"
}

@test "get_sbom_extension: returns .spdx.json for spdx-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "spdx-json"'
	assert_success
	assert_output ".spdx.json"
}

@test "get_sbom_extension: returns .spdx for spdx-tag-value" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "spdx-tag-value"'
	assert_success
	assert_output ".spdx"
}

@test "get_sbom_extension: returns .spdx for spdx-tv alias" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "spdx-tv"'
	assert_success
	assert_output ".spdx"
}

@test "get_sbom_extension: returns .syft.json for syft-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "syft-json"'
	assert_success
	assert_output ".syft.json"
}

@test "get_sbom_extension: returns .sbom.json for unknown format" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_extension "unknown-format"'
	assert_success
	assert_output ".sbom.json"
}

# =============================================================================
# validate_sbom_format tests
# =============================================================================

@test "validate_sbom_format: validates cyclonedx-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && validate_sbom_format "cyclonedx-json" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_sbom_format: validates cdx-json alias" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && validate_sbom_format "cdx-json" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_sbom_format: validates spdx-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && validate_sbom_format "spdx-json" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_sbom_format: validates syft-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && validate_sbom_format "syft-json" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_sbom_format: rejects invalid format" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && validate_sbom_format "invalid" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_sbom_format: rejects empty format" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && validate_sbom_format "" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

# =============================================================================
# normalize_sbom_format tests
# =============================================================================

@test "normalize_sbom_format: normalizes cdx-json to cyclonedx-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && normalize_sbom_format "cdx-json"'
	assert_success
	assert_output "cyclonedx-json"
}

@test "normalize_sbom_format: normalizes cdx-xml to cyclonedx-xml" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && normalize_sbom_format "cdx-xml"'
	assert_success
	assert_output "cyclonedx-xml"
}

@test "normalize_sbom_format: normalizes spdx-tv to spdx-tag-value" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && normalize_sbom_format "spdx-tv"'
	assert_success
	assert_output "spdx-tag-value"
}

@test "normalize_sbom_format: passes through canonical formats unchanged" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && normalize_sbom_format "cyclonedx-json"'
	assert_success
	assert_output "cyclonedx-json"
}

@test "normalize_sbom_format: passes through unknown formats unchanged" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && normalize_sbom_format "custom-format"'
	assert_success
	assert_output "custom-format"
}

# =============================================================================
# get_sbom_mime_type tests
# =============================================================================

@test "get_sbom_mime_type: returns correct type for cyclonedx-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_mime_type "cyclonedx-json"'
	assert_success
	assert_output "application/vnd.cyclonedx+json"
}

@test "get_sbom_mime_type: returns correct type for cyclonedx-xml" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_mime_type "cyclonedx-xml"'
	assert_success
	assert_output "application/vnd.cyclonedx+xml"
}

@test "get_sbom_mime_type: returns correct type for spdx-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_mime_type "spdx-json"'
	assert_success
	assert_output "application/spdx+json"
}

@test "get_sbom_mime_type: returns correct type for spdx-tag-value" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_mime_type "spdx-tag-value"'
	assert_success
	assert_output "text/spdx"
}

@test "get_sbom_mime_type: returns correct type for syft-json" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_mime_type "syft-json"'
	assert_success
	assert_output "application/json"
}

@test "get_sbom_mime_type: returns octet-stream for unknown format" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && get_sbom_mime_type "unknown"'
	assert_success
	assert_output "application/octet-stream"
}

# =============================================================================
# Constants tests
# =============================================================================

@test "format.sh: defines SBOM_FORMAT_CYCLONEDX_JSON constant" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && echo "$SBOM_FORMAT_CYCLONEDX_JSON"'
	assert_success
	assert_output "cyclonedx-json"
}

@test "format.sh: defines SBOM_FORMAT_SPDX_JSON constant" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && echo "$SBOM_FORMAT_SPDX_JSON"'
	assert_success
	assert_output "spdx-json"
}

@test "format.sh: defines SBOM_FORMAT_CYCLONEDX_XML constant" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && echo "$SBOM_FORMAT_CYCLONEDX_XML"'
	assert_success
	assert_output "cyclonedx-xml"
}

@test "format.sh: defines SBOM_FORMAT_SPDX_TV constant" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && echo "$SBOM_FORMAT_SPDX_TV"'
	assert_success
	assert_output "spdx-tv"
}

@test "format.sh: defines SBOM_FORMAT_SYFT_JSON constant" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && echo "$SBOM_FORMAT_SYFT_JSON"'
	assert_success
	assert_output "syft-json"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "format.sh: exports get_sbom_extension function" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && bash -c "get_sbom_extension cyclonedx-json"'
	assert_success
	assert_output ".cdx.json"
}

@test "format.sh: exports validate_sbom_format function" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && bash -c "validate_sbom_format cyclonedx-json && echo ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "format.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/sbom/format.sh"
		source "$LIB_DIR/sbom/format.sh"
		source "$LIB_DIR/sbom/format.sh"
		get_sbom_extension "cyclonedx-json"
	'
	assert_success
	assert_output ".cdx.json"
}

@test "format.sh: sets _LGTM_CI_SBOM_FORMAT_LOADED guard" {
	run bash -c 'source "$LIB_DIR/sbom/format.sh" && echo "${_LGTM_CI_SBOM_FORMAT_LOADED}"'
	assert_success
	assert_output "1"
}
