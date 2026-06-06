#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for format-semantic-pr-title-failure-comment.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/format-semantic-pr-title-failure-comment.sh"

@test "format-semantic-pr-title-failure-comment: writes expected markdown body" {
	local comment_file="${BATS_TEST_TMPDIR}/comment.md"

	run env \
		SEMANTIC_ERROR="No release type found" \
		ALLOWED_TYPES=$'feat\nfix' \
		COMMENT_FILE="$comment_file" \
		bash "$SCRIPT"

	assert_success
	[[ -f "$comment_file" ]]
	run grep -F '### Semantic PR title check failed' "$comment_file"
	assert_success
	run grep -F 'No release type found' "$comment_file"
	assert_success
	run grep -F '  - feat' "$comment_file"
	assert_success
	run grep -F '  - fix' "$comment_file"
	assert_success
	run grep -F '**Expected format:** `type(scope): description`' "$comment_file"
	assert_success
}
