#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/validate-artifact-prefix.sh (#739, #1091)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-artifact-prefix.sh"

@test "validate-artifact-prefix: accepts the E2E workflow default" {
	run env ARTIFACT_PREFIX="playwright" bash "$SCRIPT"

	assert_success
	assert_output --partial "Artifact prefix: playwright"
	assert_output --partial "Artifacts upload as: playwright-<name>"
	assert_output --partial "Download globs: playwright-<name>-*"
}

# The language test reusables share the validator (#1091); their defaults are
# the language words and must pass unchanged so single-call consumers keep
# today's artifact names.
@test "validate-artifact-prefix: accepts every language test default" {
	local prefix
	# node_custom, not node-custom: the hyphen is the reserved separator, so
	# reusable-test-node-custom.yml's default uses an underscore.
	for prefix in python node node_custom rust shell; do
		run env ARTIFACT_PREFIX="$prefix" bash "$SCRIPT"
		assert_success
		assert_output --partial "Artifact prefix: ${prefix}"
	done
}

# The error text is what a caller sees in the job log; it must not describe
# E2E shards to a Python caller.
@test "validate-artifact-prefix: the rejection message is language-neutral" {
	run env ARTIFACT_PREFIX="py-312" bash "$SCRIPT"

	assert_failure
	assert_output --partial "matches only this call's artifacts"
	refute_output --partial "shard"
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
