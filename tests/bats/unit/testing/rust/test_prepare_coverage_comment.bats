#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/testing/rust/prepare-coverage-comment.sh"
	export COMMENT_OUTPUT="${BATS_TEST_TMPDIR}/comment.md"
}

@test "prepare-coverage-comment rewrites the default heading" {
	COMMENT_BODY=$'## Coverage Report\n\n| Lines | 90% |' \
		COMMENT_TITLE="Rust Coverage Report" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q "## Rust Coverage Report" "$COMMENT_OUTPUT"
}
