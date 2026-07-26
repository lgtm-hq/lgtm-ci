#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/validate-artifact-prefix.sh (#739)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-artifact-prefix.sh"

@test "validate-artifact-prefix: accepts the workflow default" {
	run env ARTIFACT_PREFIX="playwright" bash "$SCRIPT"

	assert_success
	assert_output --partial "Artifact prefix: playwright"
	assert_output --partial "Merged report artifact: playwright-merged-report"
}

@test "validate-artifact-prefix: accepts alphanumeric, underscore and dot" {
	local prefix
	for prefix in e2e E2E_Nightly pw.smoke suite2; do
		run env ARTIFACT_PREFIX="$prefix" bash "$SCRIPT"
		assert_success
	done
}

# The merge job globs "<prefix>-*", so a hyphen inside the prefix would make
# "e2e-*" also match the "e2e-nightly" call's shards. Rejecting the hyphen is
# what makes two distinct prefixes provably disjoint.
@test "validate-artifact-prefix: rejects a hyphenated prefix" {
	run env ARTIFACT_PREFIX="e2e-nightly" bash "$SCRIPT"

	assert_failure
	assert_output --partial "artifact-prefix must match [A-Za-z0-9_.]+"
}

@test "validate-artifact-prefix: rejects glob and path metacharacters" {
	local prefix
	for prefix in "pw*" "pw/report" "pw report" "pw?"; do
		run env ARTIFACT_PREFIX="$prefix" bash "$SCRIPT"
		assert_failure
		assert_output --partial "artifact-prefix must match"
	done
}

@test "validate-artifact-prefix: rejects an empty prefix" {
	run env ARTIFACT_PREFIX="" bash "$SCRIPT"

	assert_failure
	assert_output --partial "artifact-prefix must not be empty"
}
