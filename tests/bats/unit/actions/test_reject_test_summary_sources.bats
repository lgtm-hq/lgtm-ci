#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/reject-test-summary-sources.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/reject-test-summary-sources.sh"

@test "reject-test-summary-sources.sh: fails when both sources are set" {
	run env JUNIT_ARTIFACT="test-reports-*" RESULTS_ARTIFACT_PATTERN="py-results-*" bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "::error title=conflicting test summary sources::"
	assert_output --partial "junit-artifact and results-artifact-pattern cannot both be set"
}

@test "reject-test-summary-sources.sh: passes when only junit-artifact is set" {
	run env JUNIT_ARTIFACT="test-reports" RESULTS_ARTIFACT_PATTERN="" bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "reject-test-summary-sources.sh: passes when only results-artifact-pattern is set" {
	run env -u JUNIT_ARTIFACT RESULTS_ARTIFACT_PATTERN="py-results-*" bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "reject-test-summary-sources.sh: passes when neither source is set" {
	run env -u JUNIT_ARTIFACT -u RESULTS_ARTIFACT_PATTERN bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "reject-test-summary-sources.sh: never prints the input values or the environment" {
	local secret="ghs_notarealtoken0123456789"
	run env JUNIT_ARTIFACT="reports-${secret}" RESULTS_ARTIFACT_PATTERN="results-${secret}" \
		GITHUB_TOKEN="$secret" bash "$SCRIPT"
	assert_failure 1
	refute_output --partial "$secret"
	refute_output --partial "reports-"
	refute_output --partial "results-ghs"
}
