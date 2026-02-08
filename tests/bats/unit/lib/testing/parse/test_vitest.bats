#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/vitest.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_vitest_json tests - file handling
# =============================================================================

@test "parse_vitest_json: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/vitest.sh"
		parse_vitest_json "/nonexistent/file.json"
		ret=$?
		echo "passed=$TESTS_PASSED failed=$TESTS_FAILED total=$TESTS_TOTAL ret=$ret"
	'
	assert_success
	assert_output "passed=0 failed=0 total=0 ret=1"
}

@test "parse_vitest_json: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/vitest.sh"
		parse_vitest_json ""
		ret=$?
		echo "passed=$TESTS_PASSED ret=$ret"
	'
	assert_success
	assert_output "passed=0 ret=1"
}

# =============================================================================
# parse_vitest_json tests - testResults format (vitest JSON reporter)
# =============================================================================

@test "parse_vitest_json: parses vitest JSON reporter testResults format" {
	cat >"${BATS_TEST_TMPDIR}/vitest.json" <<'EOF'
{
  "testResults": [
    {
      "assertionResults": [
        {"status": "passed", "title": "test1"},
        {"status": "passed", "title": "test2"},
        {"status": "failed", "title": "test3"}
      ]
    },
    {
      "assertionResults": [
        {"status": "passed", "title": "test4"},
        {"status": "skipped", "title": "test5"}
      ]
    }
  ],
  "startTime": 1700000000000,
  "endTime": 1700000005000
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_json \"${BATS_TEST_TMPDIR}/vitest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=3 failed=1 skipped=1 total=5"
}

@test "parse_vitest_json: handles pending status as skipped" {
	cat >"${BATS_TEST_TMPDIR}/vitest.json" <<'EOF'
{
  "testResults": [
    {
      "assertionResults": [
        {"status": "passed", "title": "test1"},
        {"status": "pending", "title": "test2"},
        {"status": "pending", "title": "test3"}
      ]
    }
  ]
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_json \"${BATS_TEST_TMPDIR}/vitest.json\"
		echo \"passed=\$TESTS_PASSED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=1 skipped=2 total=3"
}

@test "parse_vitest_json: calculates duration from timestamps" {
	cat >"${BATS_TEST_TMPDIR}/vitest.json" <<'EOF'
{
  "testResults": [
    {
      "assertionResults": [
        {"status": "passed", "title": "test1"}
      ]
    }
  ],
  "startTime": 1700000000000,
  "endTime": 1700000010000
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_json \"${BATS_TEST_TMPDIR}/vitest.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "duration=10"
}

# =============================================================================
# parse_vitest_json tests - alternative format (numTotalTests)
# =============================================================================

@test "parse_vitest_json: falls back to numTotalTests format" {
	cat >"${BATS_TEST_TMPDIR}/vitest.json" <<'EOF'
{
  "numPassedTests": 8,
  "numFailedTests": 2,
  "numPendingTests": 1,
  "numTotalTests": 11
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_json \"${BATS_TEST_TMPDIR}/vitest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=8 failed=2 skipped=1 total=11"
}

@test "parse_vitest_json: handles all passing in alternative format" {
	cat >"${BATS_TEST_TMPDIR}/vitest.json" <<'EOF'
{
  "numPassedTests": 15,
  "numFailedTests": 0,
  "numPendingTests": 0,
  "numTotalTests": 15
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_json \"${BATS_TEST_TMPDIR}/vitest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=15 failed=0 total=15"
}

# =============================================================================
# parse_vitest_json tests - edge cases
# =============================================================================

@test "parse_vitest_json: handles empty testResults" {
	cat >"${BATS_TEST_TMPDIR}/vitest.json" <<'EOF'
{
  "testResults": []
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_json \"${BATS_TEST_TMPDIR}/vitest.json\"
		echo \"total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "total=0"
}

@test "parse_vitest_json: handles missing endTime" {
	cat >"${BATS_TEST_TMPDIR}/vitest.json" <<'EOF'
{
  "testResults": [],
  "startTime": 1700000000000
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_json \"${BATS_TEST_TMPDIR}/vitest.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "duration=0"
}

# =============================================================================
# parse_vitest_coverage tests - file handling
# =============================================================================

@test "parse_vitest_coverage: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/vitest.sh"
		parse_vitest_coverage "/nonexistent/coverage.json"
		ret=$?
		echo "percent=$COVERAGE_PERCENT lines=$COVERAGE_LINES ret=$ret"
	'
	assert_success
	assert_output "percent=0 lines=0 ret=1"
}

# =============================================================================
# parse_vitest_coverage tests - istanbul coverage-summary format
# =============================================================================

@test "parse_vitest_coverage: parses istanbul coverage-summary.json" {
	cat >"${BATS_TEST_TMPDIR}/coverage-summary.json" <<'EOF'
{
  "total": {
    "lines": {"pct": 85.5},
    "branches": {"pct": 72.3},
    "functions": {"pct": 90.0}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_coverage \"${BATS_TEST_TMPDIR}/coverage-summary.json\"
		echo \"percent=\$COVERAGE_PERCENT lines=\$COVERAGE_LINES branches=\$COVERAGE_BRANCHES functions=\$COVERAGE_FUNCTIONS\"
	"
	assert_success
	assert_output "percent=85.5 lines=85.5 branches=72.3 functions=90.0"
}

@test "parse_vitest_coverage: handles 100% coverage" {
	cat >"${BATS_TEST_TMPDIR}/coverage-summary.json" <<'EOF'
{
  "total": {
    "lines": {"pct": 100},
    "branches": {"pct": 100},
    "functions": {"pct": 100}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_coverage \"${BATS_TEST_TMPDIR}/coverage-summary.json\"
		echo \"percent=\$COVERAGE_PERCENT\"
	"
	assert_success
	assert_output "percent=100"
}

@test "parse_vitest_coverage: handles 0% coverage" {
	cat >"${BATS_TEST_TMPDIR}/coverage-summary.json" <<'EOF'
{
  "total": {
    "lines": {"pct": 0},
    "branches": {"pct": 0},
    "functions": {"pct": 0}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_coverage \"${BATS_TEST_TMPDIR}/coverage-summary.json\"
		echo \"percent=\$COVERAGE_PERCENT lines=\$COVERAGE_LINES\"
	"
	assert_success
	assert_output "percent=0 lines=0"
}

@test "parse_vitest_coverage: uses lines coverage as primary percentage" {
	cat >"${BATS_TEST_TMPDIR}/coverage-summary.json" <<'EOF'
{
  "total": {
    "lines": {"pct": 80},
    "branches": {"pct": 60},
    "functions": {"pct": 90}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/vitest.sh\"
		parse_vitest_coverage \"${BATS_TEST_TMPDIR}/coverage-summary.json\"
		echo \"percent=\$COVERAGE_PERCENT\"
	"
	assert_success
	# COVERAGE_PERCENT should equal COVERAGE_LINES
	assert_output "percent=80"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/vitest.sh: exports parse_vitest_json function" {
	run bash -c 'source "$LIB_DIR/testing/parse/vitest.sh" && bash -c "type parse_vitest_json"'
	assert_success
}

@test "testing/parse/vitest.sh: exports parse_vitest_coverage function" {
	run bash -c 'source "$LIB_DIR/testing/parse/vitest.sh" && bash -c "type parse_vitest_coverage"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/vitest.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/vitest.sh" && echo "${_LGTM_CI_TESTING_PARSE_VITEST_LOADED}"'
	assert_success
	assert_output "1"
}
