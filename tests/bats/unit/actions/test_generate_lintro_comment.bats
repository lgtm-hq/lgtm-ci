#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-lintro-comment.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	export LINTRO_OUTPUT="${BATS_TEST_TMPDIR}/chk-output.txt"
	export COMMENT_OUTPUT="${BATS_TEST_TMPDIR}/quality-summary.md"
}

teardown() {
	teardown_temp_dir
}

@test "generate-lintro-comment: renders the execution summary" {
	printf '%s\n' "noise" "📋 EXECUTION SUMMARY" "| ruff | 0 |" >"$LINTRO_OUTPUT"

	run env LINTRO_EXIT_CODE=0 bash "${PROJECT_ROOT}/scripts/ci/actions/generate-lintro-comment.sh"

	assert_success
	run cat "$COMMENT_OUTPUT"
	assert_output --partial "### Status: ✅ PASSED"
	assert_output --partial "| ruff | 0 |"
	refute_output --partial "noise"
}

@test "generate-lintro-comment: history-summary carries the total issue count (#1346)" {
	printf '%s\n' "📋 EXECUTION SUMMARY" \
		$'| \033[1mTotal Issues\033[0m | \033[31m12\033[0m |' \
		"| Affected Files | 3 |" >"$LINTRO_OUTPUT"

	run env LINTRO_EXIT_CODE=1 bash "${PROJECT_ROOT}/scripts/ci/actions/generate-lintro-comment.sh"

	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output "history-summary=12 issues"
}

@test "generate-lintro-comment: history-summary falls back to the status" {
	run env LINTRO_EXIT_CODE=0 LINTRO_OUTPUT="${BATS_TEST_TMPDIR}/missing.txt" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-lintro-comment.sh"

	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output "history-summary=passed"
}
