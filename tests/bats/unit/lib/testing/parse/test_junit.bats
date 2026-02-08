#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/junit.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_junit_xml tests - file handling
# =============================================================================

@test "parse_junit_xml: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/junit.sh"
		parse_junit_xml "/nonexistent/file.xml"
		ret=$?
		echo "passed=$TESTS_PASSED failed=$TESTS_FAILED skipped=$TESTS_SKIPPED total=$TESTS_TOTAL ret=$ret"
	'
	assert_success
	assert_output "passed=0 failed=0 skipped=0 total=0 ret=1"
}

@test "parse_junit_xml: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/junit.sh"
		parse_junit_xml ""
		ret=$?
		echo "passed=$TESTS_PASSED ret=$ret"
	'
	assert_success
	assert_output "passed=0 ret=1"
}

# =============================================================================
# parse_junit_xml tests - single testsuite format
# =============================================================================

@test "parse_junit_xml: parses single testsuite element" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tests" tests="10" failures="2" errors="1" skipped="1">
  <testcase name="test1"/>
</testsuite>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL errors=\$TESTS_ERRORS\"
	"
	assert_success
	# failures(2) + errors(1) = 3 total failed, passed = 10 - 3 - 1 = 6
	assert_output "passed=6 failed=3 skipped=1 total=10 errors=1"
}

@test "parse_junit_xml: handles testsuite with all passing" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tests" tests="5" failures="0" errors="0" skipped="0">
  <testcase name="test1"/>
</testsuite>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=5 failed=0 total=5"
}

@test "parse_junit_xml: handles missing optional attributes" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tests" tests="5" failures="1">
  <testcase name="test1"/>
</testsuite>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	# errors and skipped default to 0
	assert_output "passed=4 failed=1 skipped=0 total=5"
}

# =============================================================================
# parse_junit_xml tests - testsuites (aggregate) format
# =============================================================================

@test "parse_junit_xml: parses testsuites with summary attributes" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="20" failures="3" errors="1" skipped="2">
  <testsuite name="suite1" tests="10" failures="1" errors="0" skipped="1"/>
  <testsuite name="suite2" tests="10" failures="2" errors="1" skipped="1"/>
</testsuites>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	# Uses root testsuites attributes: failures(3) + errors(1) = 4, passed = 20 - 4 - 2 = 14
	assert_output "passed=14 failed=4 skipped=2 total=20"
}

@test "parse_junit_xml: aggregates from child testsuites when root has no attributes" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="suite1" tests="10" failures="1" errors="0" skipped="1"/>
  <testsuite name="suite2" tests="15" failures="2" errors="1" skipped="0"/>
</testsuites>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	# Summed: tests=25, failures=3, errors=1, skipped=1
	# failed = 3 + 1 = 4, passed = 25 - 4 - 1 = 20
	assert_output "passed=20 failed=4 skipped=1 total=25"
}

@test "parse_junit_xml: handles mixed root and child attributes" {
	# Root has tests but child has failures
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="10">
  <testsuite name="suite1" tests="5" failures="1" errors="0" skipped="0"/>
  <testsuite name="suite2" tests="5" failures="1" errors="0" skipped="1"/>
</testsuites>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	# Root has tests=10, child failures summed = 2, skipped summed = 1
	# passed = 10 - 2 - 1 = 7
	assert_output "passed=7 failed=2 skipped=1 total=10"
}

# =============================================================================
# parse_junit_xml tests - edge cases
# =============================================================================

@test "parse_junit_xml: handles XML prolog and DOCTYPE" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE testsuite SYSTEM "junit.dtd">
<testsuite name="tests" tests="3" failures="0" errors="0" skipped="0">
  <testcase name="test1"/>
</testsuite>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"total=\$TESTS_TOTAL passed=\$TESTS_PASSED\"
	"
	assert_success
	assert_output "total=3 passed=3"
}

@test "parse_junit_xml: handles XML comments" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- This is a comment -->
<testsuite name="tests" tests="5" failures="1" errors="0" skipped="0">
  <!-- Another comment -->
  <testcase name="test1"/>
</testsuite>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"total=\$TESTS_TOTAL failed=\$TESTS_FAILED\"
	"
	assert_success
	assert_output "total=5 failed=1"
}

@test "parse_junit_xml: prevents negative passed count" {
	# Edge case where failures + skipped > total (malformed input)
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tests" tests="5" failures="3" errors="3" skipped="2">
  <testcase name="test1"/>
</testsuite>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED\"
	"
	assert_success
	# Should be clamped to 0, not negative
	assert_output "passed=0"
}

@test "parse_junit_xml: handles attribute order variations" {
	cat >"${BATS_TEST_TMPDIR}/junit.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite failures="2" name="tests" skipped="1" tests="10" errors="0">
  <testcase name="test1"/>
</testsuite>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/junit.sh\"
		parse_junit_xml \"${BATS_TEST_TMPDIR}/junit.xml\"
		echo \"passed=\$TESTS_PASSED failed=\$TESTS_FAILED skipped=\$TESTS_SKIPPED total=\$TESTS_TOTAL\"
	"
	assert_success
	assert_output "passed=7 failed=2 skipped=1 total=10"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/junit.sh: exports parse_junit_xml function" {
	run bash -c 'source "$LIB_DIR/testing/parse/junit.sh" && bash -c "type parse_junit_xml"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/junit.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/junit.sh" && echo "${_LGTM_CI_TESTING_PARSE_JUNIT_LOADED}"'
	assert_success
	assert_output "1"
}
