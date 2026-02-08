#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/pytest.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_pytest_json tests - file handling
# =============================================================================

@test "parse_pytest_json: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/pytest.sh"
		parse_pytest_json "/nonexistent/file.json"
		ret=$?
		echo "passed=$TESTS_PASSED failed=$TESTS_FAILED total=$TESTS_TOTAL ret=$ret"
	'
	assert_success
	assert_output "passed=0 failed=0 total=0 ret=1"
}

@test "parse_pytest_json: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/pytest.sh"
		parse_pytest_json ""
		ret=$?
		echo "passed=$TESTS_PASSED ret=$ret"
	'
	assert_success
	assert_output "passed=0 ret=1"
}

# =============================================================================
# parse_pytest_json tests - pytest-json-report format
# =============================================================================

@test "parse_pytest_json: parses standard pytest-json-report format" {
	cat >"${BATS_TEST_TMPDIR}/pytest.json" <<'EOF'
{
  "summary": {
    "passed": 10,
    "failed": 2,
    "skipped": 1,
    "total": 13
  },
  "duration": 5.25
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL duration=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "passed=10 failed=2 skipped=1 total=13 duration=5.25"
}

@test "parse_pytest_json: handles all passing tests" {
	cat >"${BATS_TEST_TMPDIR}/pytest.json" <<'EOF'
{
  "summary": {
    "passed": 25,
    "failed": 0,
    "skipped": 0,
    "total": 25
  },
  "duration": 12.5
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=25 failed=0 total=25"
}

@test "parse_pytest_json: calculates total when not provided" {
	cat >"${BATS_TEST_TMPDIR}/pytest.json" <<'EOF'
{
  "summary": {
    "passed": 5,
    "failed": 2,
    "skipped": 3
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "total=10"
}

@test "parse_pytest_json: handles missing fields with defaults" {
	cat >"${BATS_TEST_TMPDIR}/pytest.json" <<'EOF'
{
  "summary": {
    "passed": 5
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED\"
	"
	assert_success
	assert_output "passed=5 failed=0 skipped=0"
}

@test "parse_pytest_json: handles empty summary" {
	cat >"${BATS_TEST_TMPDIR}/pytest.json" <<'EOF'
{
  "summary": {}
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_json \"${BATS_TEST_TMPDIR}/pytest.json\"
		echo \"passed=\$TESTS_PASSED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=0 total=0"
}

# =============================================================================
# parse_pytest_coverage tests - file handling
# =============================================================================

@test "parse_pytest_coverage: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/pytest.sh"
		parse_pytest_coverage "/nonexistent/coverage.json"
		ret=$?
		echo "percent=$COVERAGE_PERCENT lines=$COVERAGE_LINES ret=$ret"
	'
	assert_success
	assert_output "percent=0 lines=0 ret=1"
}

# =============================================================================
# parse_pytest_coverage tests - coverage.py format
# =============================================================================

@test "parse_pytest_coverage: parses coverage.py JSON format" {
	cat >"${BATS_TEST_TMPDIR}/coverage.json" <<'EOF'
{
  "totals": {
    "percent_covered": 85.5,
    "covered_lines": 171,
    "covered_branches": 42
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"percent=\$COVERAGE_PERCENT lines=\$COVERAGE_LINES branches=\$COVERAGE_BRANCHES\"
	"
	assert_success
	assert_line --partial "lines=171"
	assert_line --partial "branches=42"
}

@test "parse_pytest_coverage: handles 100% coverage" {
	cat >"${BATS_TEST_TMPDIR}/coverage.json" <<'EOF'
{
  "totals": {
    "percent_covered": 100.0,
    "covered_lines": 500,
    "covered_branches": 100
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"percent=\$COVERAGE_PERCENT\"
	"
	assert_success
	assert_line --partial "percent=100"
}

@test "parse_pytest_coverage: handles 0% coverage" {
	cat >"${BATS_TEST_TMPDIR}/coverage.json" <<'EOF'
{
  "totals": {
    "percent_covered": 0,
    "covered_lines": 0,
    "covered_branches": 0
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"percent=\$COVERAGE_PERCENT lines=\$COVERAGE_LINES\"
	"
	assert_success
	assert_output "percent=0 lines=0"
}

@test "parse_pytest_coverage: handles missing branch coverage" {
	cat >"${BATS_TEST_TMPDIR}/coverage.json" <<'EOF'
{
  "totals": {
    "percent_covered": 75.0,
    "covered_lines": 150
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/pytest.sh\"
		parse_pytest_coverage \"${BATS_TEST_TMPDIR}/coverage.json\"
		echo \"branches=\$COVERAGE_BRANCHES\"
	"
	assert_success
	assert_output "branches=0"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/pytest.sh: exports parse_pytest_json function" {
	run bash -c 'source "$LIB_DIR/testing/parse/pytest.sh" && bash -c "type parse_pytest_json"'
	assert_success
}

@test "testing/parse/pytest.sh: exports parse_pytest_coverage function" {
	run bash -c 'source "$LIB_DIR/testing/parse/pytest.sh" && bash -c "type parse_pytest_coverage"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/pytest.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/pytest.sh" && echo "${_LGTM_CI_TESTING_PARSE_PYTEST_LOADED}"'
	assert_success
	assert_output "1"
}
