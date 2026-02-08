#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/playwright.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_playwright_json tests - file handling
# =============================================================================

@test "parse_playwright_json: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/playwright.sh"
		parse_playwright_json "/nonexistent/file.json"
		ret=$?
		echo "passed=$TESTS_PASSED failed=$TESTS_FAILED total=$TESTS_TOTAL ret=$ret"
	'
	assert_success
	assert_output "passed=0 failed=0 total=0 ret=1"
}

@test "parse_playwright_json: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/playwright.sh"
		parse_playwright_json ""
		ret=$?
		echo "passed=$TESTS_PASSED ret=$ret"
	'
	assert_success
	assert_output "passed=0 ret=1"
}

# =============================================================================
# parse_playwright_json tests - nested suites format
# =============================================================================

@test "parse_playwright_json: parses nested suites with expected/unexpected status" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "suites": [
    {
      "title": "Suite 1",
      "tests": [
        {"title": "test1", "status": "expected"},
        {"title": "test2", "status": "expected"},
        {"title": "test3", "status": "unexpected"}
      ]
    },
    {
      "title": "Suite 2",
      "tests": [
        {"title": "test4", "status": "expected"},
        {"title": "test5", "status": "skipped"}
      ]
    }
  ],
  "stats": {
    "duration": 5000
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=3 failed=1 skipped=1 total=5"
}

@test "parse_playwright_json: handles passed/failed status variants" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "suites": [
    {
      "tests": [
        {"title": "test1", "status": "passed"},
        {"title": "test2", "status": "failed"},
        {"title": "test3", "status": "passed"}
      ]
    }
  ]
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=2 failed=1 total=3"
}

@test "parse_playwright_json: counts timedOut as failed" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "suites": [
    {
      "tests": [
        {"title": "test1", "status": "expected"},
        {"title": "test2", "status": "timedOut"}
      ]
    }
  ]
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=1 failed=1 total=2"
}

@test "parse_playwright_json: counts flaky as failed" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "suites": [
    {
      "tests": [
        {"title": "test1", "status": "expected"},
        {"title": "test2", "status": "flaky"},
        {"title": "test3", "status": "expected"}
      ]
    }
  ]
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=2 failed=1 total=3"
}

# =============================================================================
# parse_playwright_json tests - stats format
# =============================================================================

@test "parse_playwright_json: falls back to stats object" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "stats": {
    "expected": 8,
    "unexpected": 2,
    "skipped": 1,
    "duration": 10000
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=8 failed=2 skipped=1 total=11"
}

@test "parse_playwright_json: includes flaky in stats failed count" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "stats": {
    "expected": 5,
    "unexpected": 1,
    "flaky": 2,
    "skipped": 0,
    "duration": 3000
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	# failed = unexpected(1) + flaky(2) = 3
	assert_output "passed=5 failed=3 total=8"
}

# =============================================================================
# parse_playwright_json tests - duration handling
# =============================================================================

@test "parse_playwright_json: converts duration from ms to seconds" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "stats": {
    "expected": 1,
    "duration": 5500
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	# 5500ms rounds to 6s (5500 + 500) / 1000 = 6
	assert_output "duration=6"
}

@test "parse_playwright_json: handles small duration" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "stats": {
    "expected": 1,
    "duration": 100
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	# 100ms + 500 = 600, / 1000 = 0 (integer division)
	assert_output "duration=0"
}

@test "parse_playwright_json: handles missing duration" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "stats": {
    "expected": 1
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"duration=\$TESTS_DURATION\"
	"
	assert_success
	assert_output "duration=0"
}

# =============================================================================
# parse_playwright_json tests - edge cases
# =============================================================================

@test "parse_playwright_json: handles deeply nested suites" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "suites": [
    {
      "title": "Root",
      "suites": [
        {
          "title": "Nested",
          "tests": [
            {"title": "test1", "status": "expected"},
            {"title": "test2", "status": "expected"}
          ],
          "suites": [
            {
              "title": "Deeply Nested",
              "tests": [
                {"title": "test3", "status": "unexpected"}
              ]
            }
          ]
        }
      ],
      "tests": [
        {"title": "root test", "status": "expected"}
      ]
    }
  ]
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=3 failed=1 total=4"
}

@test "parse_playwright_json: handles empty suites" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "suites": []
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "total=0"
}

@test "parse_playwright_json: handles all passing tests" {
	cat >"${BATS_TEST_TMPDIR}/playwright.json" <<'EOF'
{
  "suites": [
    {
      "tests": [
        {"title": "test1", "status": "expected"},
        {"title": "test2", "status": "expected"},
        {"title": "test3", "status": "expected"}
      ]
    }
  ]
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/playwright.sh\"
		parse_playwright_json \"${BATS_TEST_TMPDIR}/playwright.json\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=3 failed=0 total=3"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/playwright.sh: exports parse_playwright_json function" {
	run bash -c 'source "$LIB_DIR/testing/parse/playwright.sh" && bash -c "type parse_playwright_json"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/playwright.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/playwright.sh" && echo "${_LGTM_CI_TESTING_PARSE_PLAYWRIGHT_LOADED}"'
	assert_success
	assert_output "1"
}
