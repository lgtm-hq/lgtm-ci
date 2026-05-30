#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/testing/rust/parse-cargo-test-results.sh"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

@test "parse-cargo-test-results excludes ignored tests from total" {
	cat >"$BATS_TEST_TMPDIR/rust-test.log" <<'EOF'
test result: ok. 80 passed; 0 failed; 20 ignored; 0 measured; 0 filtered out
EOF

	cd "$BATS_TEST_TMPDIR"
	TEST_LOG_FILE=rust-test.log run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=80"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=0"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=80"
	assert_file_contains "$GITHUB_OUTPUT" "tests-ran=true"
}

@test "parse-cargo-test-results aggregates workspace test result lines" {
	cat >"$BATS_TEST_TMPDIR/rust-test.log" <<'EOF'
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
test result: FAILED. 1 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out
EOF

	cd "$BATS_TEST_TMPDIR"
	TEST_LOG_FILE=rust-test.log run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=4"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=2"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=6"
	assert_file_contains "$GITHUB_OUTPUT" "tests-ran=true"
}

@test "parse-cargo-test-results reports zero totals when log is missing" {
	cd "$BATS_TEST_TMPDIR"
	TEST_LOG_FILE=missing.log run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=0"
	assert_file_contains "$GITHUB_OUTPUT" "tests-ran=false"
}
