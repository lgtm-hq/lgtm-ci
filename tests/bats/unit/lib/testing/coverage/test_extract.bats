#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/coverage/extract.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export FIXTURES_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# extract_coverage_percent tests - coverage-py format
# =============================================================================

@test "extract_coverage_percent: parses coverage-py JSON" {
	# Use .coverage.json naming to trigger coverage-py detection path
	local cov_file="${BATS_TEST_TMPDIR}/.coverage.json"
	cat >"$cov_file" <<'EOF'
{
  "totals": {
    "percent_covered": 85.5
  }
}
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$cov_file\""
	assert_success
	assert_output "85.5"
}

# =============================================================================
# extract_coverage_percent tests - istanbul format
# =============================================================================

@test "extract_coverage_percent: parses istanbul summary JSON" {
	local file="${BATS_TEST_TMPDIR}/coverage-summary.json"
	cat >"$file" <<'EOF'
{
  "total": {
    "lines": {"total": 100, "covered": 85, "skipped": 0, "pct": 85},
    "branches": {"total": 50, "covered": 40, "skipped": 0, "pct": 80},
    "statements": {"total": 120, "covered": 100, "skipped": 0, "pct": 83.33}
  }
}
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_success
	assert_output "85"
}

@test "extract_coverage_percent: parses istanbul full JSON with per-file coverage" {
	local file="${BATS_TEST_TMPDIR}/coverage.json"
	cat >"$file" <<'EOF'
{
  "/src/app.js": {
    "path": "/src/app.js",
    "statementMap": {},
    "lines": {"total": 100, "covered": 80},
    "s": {}
  }
}
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_success
	assert_output "80"
}

# =============================================================================
# extract_coverage_percent tests - cobertura format
# =============================================================================

@test "extract_coverage_percent: parses cobertura XML" {
	local file="${BATS_TEST_TMPDIR}/coverage.xml"
	cat >"$file" <<'EOF'
<?xml version="1.0" ?>
<coverage line-rate="0.85" branch-rate="0.80">
  <packages></packages>
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_success
	assert_output "85.00"
}

@test "extract_coverage_percent: parses sample_cobertura.xml fixture" {
	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"\$FIXTURES_DIR/coverage/sample_cobertura.xml\""
	assert_success
	assert_output "85.00"
}

# =============================================================================
# extract_coverage_percent tests - lcov format
# =============================================================================

@test "extract_coverage_percent: parses LCOV format" {
	local file="${BATS_TEST_TMPDIR}/coverage.info"
	cat >"$file" <<'EOF'
TN:
SF:/src/a.js
DA:1,1
DA:2,1
DA:3,0
LF:3
LH:2
end_of_record
SF:/src/b.js
DA:1,1
LF:1
LH:1
end_of_record
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_success
	assert_output "75.00"
}

@test "extract_coverage_percent: handles empty LCOV file" {
	local file="${BATS_TEST_TMPDIR}/empty.info"
	echo "TN:" >"$file"

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_success
	assert_output "0"
}

# =============================================================================
# extract_coverage_percent tests - edge cases
# =============================================================================

@test "extract_coverage_percent: returns 0 for missing file" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh" && extract_coverage_percent "/nonexistent"'
	assert_failure
	assert_output "0"
}

@test "extract_coverage_percent: returns 0 for unknown format" {
	local file="${BATS_TEST_TMPDIR}/random.html"
	echo "<html></html>" >"$file"

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_failure
	assert_output "0"
}

@test "extract_coverage_percent: parses generic JSON with .coverage field" {
	local file="${BATS_TEST_TMPDIR}/coverage-data.json"
	echo '{"coverage": 92.5}' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_success
	assert_output "92.5"
}

# =============================================================================
# extract_coverage_details tests - cobertura
# =============================================================================

@test "extract_coverage_details: extracts cobertura details" {
	local file="${BATS_TEST_TMPDIR}/coverage.xml"
	cat >"$file" <<'EOF'
<?xml version="1.0" ?>
<coverage line-rate="0.85" branch-rate="0.70">
  <packages></packages>
</coverage>
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/coverage/extract.sh\"
		extract_coverage_details \"$file\"
		echo \"lines=\$COVERAGE_LINES\"
		echo \"branches=\$COVERAGE_BRANCHES\"
	"
	assert_success
	assert_line "lines=85.00"
	assert_line "branches=70.00"
}

# =============================================================================
# extract_coverage_details tests - lcov
# =============================================================================

@test "extract_coverage_details: extracts lcov details" {
	local file="${BATS_TEST_TMPDIR}/coverage.info"
	cat >"$file" <<'EOF'
TN:
SF:/src/a.js
FN:1,func1
FNDA:1,func1
FNF:1
FNH:1
DA:1,1
DA:2,0
LF:2
LH:1
BRF:4
BRH:2
end_of_record
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/coverage/extract.sh\"
		extract_coverage_details \"$file\"
		echo \"lines=\$COVERAGE_LINES\"
		echo \"branches=\$COVERAGE_BRANCHES\"
		echo \"functions=\$COVERAGE_FUNCTIONS\"
	"
	assert_success
	assert_line "lines=50.00"
	assert_line "branches=50.00"
	assert_line "functions=100.00"
}

# =============================================================================
# extract_coverage_details tests - istanbul summary
# =============================================================================

@test "extract_coverage_details: extracts istanbul summary details" {
	# The detect_coverage_format function detects .json files as "istanbul" only
	# when they contain "path" or "statementMap" keys. The coverage-summary.json
	# format (with .total.lines.pct) is detected as generic "json", which doesn't
	# have a details handler. To test the istanbul details path, we need a
	# per-file istanbul format that triggers istanbul detection.
	local file="${BATS_TEST_TMPDIR}/istanbul-coverage.json"
	cat >"$file" <<'EOF'
{
  "/src/app.js": {
    "path": "/src/app.js",
    "statementMap": {},
    "s": {},
    "lines": {"total": 100, "covered": 85},
    "branches": {"total": 50, "covered": 40},
    "functions": {"total": 20, "covered": 18},
    "statements": {"total": 120, "covered": 100}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/coverage/extract.sh\"
		extract_coverage_details \"$file\"
		echo \"lines=\$COVERAGE_LINES\"
		echo \"branches=\$COVERAGE_BRANCHES\"
		echo \"functions=\$COVERAGE_FUNCTIONS\"
		echo \"statements=\$COVERAGE_STATEMENTS\"
	"
	assert_success
	assert_line "lines=85"
	assert_line "branches=80"
	assert_line "functions=90"
	assert_line --partial "statements=83.33"
}

# =============================================================================
# extract_coverage_details tests - edge cases
# =============================================================================

@test "extract_coverage_details: returns 1 for missing file" {
	run bash -c '
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "/nonexistent"
	'
	assert_failure
}

@test "extract_coverage_details: initializes to 0 before returning 1 for missing file" {
	run bash -c '
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "/nonexistent" || true
		echo "lines=$COVERAGE_LINES"
	'
	assert_success
	assert_line "lines=0"
}

@test "extract_coverage_details: initializes all values to 0" {
	local file="${BATS_TEST_TMPDIR}/empty.html"
	echo "<html></html>" >"$file"

	run bash -c "
		source \"\$LIB_DIR/testing/coverage/extract.sh\"
		extract_coverage_details \"$file\"
		echo \"lines=\$COVERAGE_LINES\"
		echo \"branches=\$COVERAGE_BRANCHES\"
		echo \"functions=\$COVERAGE_FUNCTIONS\"
		echo \"statements=\$COVERAGE_STATEMENTS\"
	"
	assert_success
	assert_line "lines=0"
	assert_line "branches=0"
	assert_line "functions=0"
	assert_line "statements=0"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "extract.sh: exports extract_coverage_percent function" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh" && declare -f extract_coverage_percent >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "extract.sh: exports extract_coverage_details function" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh" && declare -f extract_coverage_details >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "extract.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing/coverage/extract.sh"
		source "$LIB_DIR/testing/coverage/extract.sh"
		declare -f extract_coverage_percent >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "extract.sh: sets _LGTM_CI_TESTING_COVERAGE_EXTRACT_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh" && echo "${_LGTM_CI_TESTING_COVERAGE_EXTRACT_LOADED}"'
	assert_success
	assert_output "1"
}
