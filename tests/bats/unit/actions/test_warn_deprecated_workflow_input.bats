#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/warn-deprecated-workflow-input.sh (#770)
#
# The deprecation window only works if the warning actually reaches the caller.
# It also has to stay quiet for callers that never set the input, or every run
# of every consumer would carry an annotation nobody needs to act on.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/warn-deprecated-workflow-input.sh"

setup() {
	SUMMARY_FILE="${BATS_TEST_TMPDIR}/step_summary"
	: >"$SUMMARY_FILE"
}

_run_warn() {
	run env INPUT_NAME=publish-pages REPLACEMENT="Call the publisher workflow." \
		GITHUB_STEP_SUMMARY="$SUMMARY_FILE" "$@" bash "$SCRIPT"
}

@test "warn-deprecated-workflow-input: warns when the value differs from the default" {
	_run_warn INPUT_VALUE=true DEFAULT_VALUE=false

	assert_success
	assert_output --partial "::warning title=Deprecated input::"
	assert_output --partial "'publish-pages' is deprecated"
	assert_output --partial "Call the publisher workflow."
}

# A reusable workflow cannot tell "unset" from "explicitly set to the default",
# so the default is the only safe silence condition. Warning on it would fire on
# every run of every caller, including ones with nothing to migrate.
@test "warn-deprecated-workflow-input: stays quiet at the default" {
	_run_warn INPUT_VALUE=false DEFAULT_VALUE=false

	assert_success
	refute_output --partial "::warning"
	[ ! -s "$SUMMARY_FILE" ]
}

@test "warn-deprecated-workflow-input: stays quiet at an empty default" {
	_run_warn INPUT_NAME=publish-allowed-endpoints INPUT_VALUE="" DEFAULT_VALUE=""

	assert_success
	refute_output --partial "::warning"
}

# A log annotation scrolls away; the job summary is what a caller sees on the
# run page after the fact.
@test "warn-deprecated-workflow-input: records the migration in the job summary" {
	_run_warn INPUT_VALUE=true DEFAULT_VALUE=false

	assert_success
	run cat "$SUMMARY_FILE"
	assert_output --partial "Deprecated input"
	assert_output --partial "publish-pages"
	assert_output --partial "no longer has any effect"
	assert_output --partial "Call the publisher workflow."
}

# release-assets mode still works; only part of what it did moved. Calling that
# "deprecated" would be a claim the caller has no way to check against a
# workflow whose input list still accepts and acts on the value.
@test "warn-deprecated-workflow-input: behaviour changes are not called deprecated" {
	_run_warn NOTICE_KIND=behavior-change INPUT_NAME=mode \
		INPUT_VALUE=release-assets DEFAULT_VALUE=report

	assert_success
	assert_output --partial "::warning title=Behavior change::"
	assert_output --partial "does less than it used to"
	refute_output --partial "deprecated"
}

@test "warn-deprecated-workflow-input: behaviour-change notice also honours the default" {
	_run_warn NOTICE_KIND=behavior-change INPUT_NAME=mode \
		INPUT_VALUE=report DEFAULT_VALUE=report

	assert_success
	refute_output --partial "::warning"
}

@test "warn-deprecated-workflow-input: rejects an unknown notice kind" {
	_run_warn NOTICE_KIND=informational INPUT_VALUE=true DEFAULT_VALUE=false

	assert_failure
	assert_output --partial "NOTICE_KIND must be"
}

@test "warn-deprecated-workflow-input: requires a name and a replacement" {
	run env -u INPUT_NAME REPLACEMENT=x INPUT_VALUE=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "INPUT_NAME is required"

	run env -u REPLACEMENT INPUT_NAME=x INPUT_VALUE=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "REPLACEMENT is required"
}

# Without a summary file the script still has to warn: composite steps outside
# a GitHub runner have no GITHUB_STEP_SUMMARY, and swallowing the annotation
# there would make local reproduction disagree with CI.
@test "warn-deprecated-workflow-input: warns without a job summary file" {
	run env -u GITHUB_STEP_SUMMARY INPUT_NAME=publish-pages \
		REPLACEMENT="Call the publisher workflow." \
		INPUT_VALUE=true DEFAULT_VALUE=false bash "$SCRIPT"

	assert_success
	assert_output --partial "::warning title=Deprecated input::"
}
