#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/prepare-coverage-test-summary.sh"
	export COMMENT_OUTPUT="${BATS_TEST_TMPDIR}/comment.md"
}

@test "prepare-coverage-test-summary rewrites the default heading" {
	COMMENT_BODY=$'## Coverage Report\n\n| Lines | 90% |' \
		COMMENT_TITLE="Rust Coverage Report" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q "## Rust Coverage Report" "$COMMENT_OUTPUT"
}

@test "prepare-coverage-test-summary handles special characters in title" {
	COMMENT_BODY=$'## Coverage Report\n\nbody' \
		COMMENT_TITLE="A/B & C" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q "## A/B & C" "$COMMENT_OUTPUT"
}
