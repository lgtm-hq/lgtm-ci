#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/check-comment-format.sh (#1678)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/check-comment-format.sh"

@test "check-comment-format.sh: accepts classic, compact and table" {
	local value
	for value in classic compact table; do
		run env COMMENT_FORMAT="$value" bash "$SCRIPT"
		assert_success
		assert_output ""
	done
}

@test "check-comment-format.sh: empty or unset means classic" {
	run env COMMENT_FORMAT="" bash "$SCRIPT"
	assert_success
	run env -u COMMENT_FORMAT bash "$SCRIPT"
	assert_success
}

@test "check-comment-format.sh: fails on any other value without printing it" {
	local value
	for value in Compact "table " wide $'compact\n::warning::injected'; do
		run env COMMENT_FORMAT="$value" bash "$SCRIPT"
		assert_failure 1
		assert_output "::error title=unknown comment-format::comment-format must be classic, compact or table"
	done
}
