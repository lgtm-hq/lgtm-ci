#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/validate-sbom-mode.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-sbom-mode.sh"

@test "validate-sbom-mode: defaults to report and succeeds" {
	run env -u MODE -u RELEASE_TAG bash "$SCRIPT"
	assert_success
	assert_output --partial "SBOM mode validated: report"
}

@test "validate-sbom-mode: report mode allows empty release-tag" {
	run env MODE=report RELEASE_TAG= bash "$SCRIPT"
	assert_success
}

@test "validate-sbom-mode: release-assets without release-tag fails with ::error::" {
	run env MODE=release-assets RELEASE_TAG= bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::release-tag is required when mode is release-assets"
}

@test "validate-sbom-mode: release-assets with release-tag succeeds" {
	run env MODE=release-assets RELEASE_TAG=v1.2.3 bash "$SCRIPT"
	assert_success
	assert_output --partial "SBOM mode validated: release-assets"
}

@test "validate-sbom-mode: invalid mode fails with ::error::" {
	run env MODE=scan bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::Invalid mode 'scan'"
}
