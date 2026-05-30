#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/testing/rust/parse-rust-test-results.sh"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

@test "parse-rust-test-results parses junit and excludes skipped from pass rate total" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tests" tests="10" failures="2" errors="0" skipped="3">
  <testcase name="test1"/>
</testsuite>
EOF

	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=junit.xml \
		COVERAGE_ENABLED=false \
		bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=5"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=2"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=7"
	assert_file_contains "$GITHUB_OUTPUT" "tests-ran=true"
}

@test "parse-rust-test-results extracts coverage percent from lcov when enabled" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tests" tests="2" failures="0" errors="0" skipped="0"/>
EOF
	cat >"${BATS_TEST_TMPDIR}/rust-coverage.lcov" <<'EOF'
TN:
SF:/workspace/src/lib.rs
FN:1,covered_fn
FNDA:3,covered_fn
FNF:1
FNH:1
DA:1,1
DA:2,1
LF:2
LH:2
end_of_record
EOF

	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=junit.xml \
		LCOV_FILE=rust-coverage.lcov \
		COVERAGE_ENABLED=true \
		bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=100"
}

@test "parse-rust-test-results fails when junit file is missing" {
	cd "$BATS_TEST_TMPDIR"
	run env \
		JUNIT_FILE=missing.xml \
		COVERAGE_ENABLED=false \
		bash "$SCRIPT"
	assert_failure
}
