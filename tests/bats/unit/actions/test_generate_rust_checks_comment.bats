#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/generate-rust-checks-comment.sh"
}

@test "generate-rust-checks-comment marks overall status failed when clippy fails" {
	cd "$BATS_TEST_TMPDIR"
	TESTS_PASSED=5 TESTS_FAILED=0 TESTS_TOTAL=5 \
		TEST_RESULT=success CLIPPY_RESULT=failure FMT_RESULT=success \
		TEST_SUITE_NAME="Rust Tests" COMMENT_OUTPUT=comment.md \
		run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q "FAILED" comment.md
	grep -q "cargo clippy" comment.md
}

@test "generate-rust-checks-comment skips optional checks in summary" {
	cd "$BATS_TEST_TMPDIR"
	TESTS_PASSED=2 TESTS_FAILED=0 TESTS_TOTAL=2 \
		TEST_RESULT=success CLIPPY_RESULT=skipped FMT_RESULT=skipped \
		TEST_SUITE_NAME="Rust Tests" COMMENT_OUTPUT=comment.md \
		run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q "Skipped" comment.md
}
