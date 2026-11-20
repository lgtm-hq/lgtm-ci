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
		echo \"statements=\$COVERAGE_STATEMENTS\"
	"
	assert_success
	assert_line "lines=50.00"
	assert_line "branches=50.00"
	assert_line "functions=100.00"
	assert_line "statements=50.00"
}

# =============================================================================
# extract_coverage_details tests - lcov fixtures (#1078)
#
# These run under `set -eo pipefail` (not -u): in a `bash -c` string there is
# no BASH_SOURCE, which bash 5.2 reports as unbound while sourcing. The full
# `set -euo pipefail` path is covered by test_collect_coverage.bats, which
# runs the real script.
# =============================================================================

@test "extract_coverage_details: line-only LCOV reports branches and functions as n/a" {
	run bash -c '
		set -eo pipefail
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$FIXTURES_DIR/coverage/lcov-line-only.info"
		echo "lines=$COVERAGE_LINES"
		echo "branches=$COVERAGE_BRANCHES"
		echo "functions=$COVERAGE_FUNCTIONS"
		echo "statements=$COVERAGE_STATEMENTS"
	'
	assert_success
	assert_line "lines=50.00"
	assert_line "branches=n/a"
	assert_line "functions=n/a"
	assert_line "statements=50.00"
}

@test "extract_coverage_details: full LCOV fixture sums every record type" {
	run bash -c '
		set -eo pipefail
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$FIXTURES_DIR/coverage/lcov-full.info"
		echo "lines=$COVERAGE_LINES"
		echo "branches=$COVERAGE_BRANCHES"
		echo "functions=$COVERAGE_FUNCTIONS"
	'
	assert_success
	assert_line "lines=62.50"
	assert_line "branches=33.33"
	assert_line "functions=66.67"
}

@test "extract_coverage_details: empty LCOV fixture is 0 lines and n/a elsewhere" {
	run bash -c '
		set -eo pipefail
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$FIXTURES_DIR/coverage/lcov-empty.info"
		echo "lines=$COVERAGE_LINES"
		echo "branches=$COVERAGE_BRANCHES"
		echo "functions=$COVERAGE_FUNCTIONS"
	'
	assert_success
	assert_line "lines=0"
	assert_line "branches=n/a"
	assert_line "functions=n/a"
}

@test "extract_coverage_details: invalid LCOV fixture does not abort a set -e caller" {
	# No LF/LH records: the line total the format requires is absent, so lines
	# are invalid, not 0% (#1692); branches are legitimately not measured.
	run bash -c '
		set -eo pipefail
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$FIXTURES_DIR/coverage/lcov-invalid.info"
		echo "lines=$COVERAGE_LINES"
		echo "branches=$COVERAGE_BRANCHES"
	'
	assert_success
	assert_line "lines=invalid"
	assert_line "branches=n/a"
}

# Prints the four details for one LCOV body written to a temporary file.
lcov_details() {
	local file="${BATS_TEST_TMPDIR}/coverage.info"
	printf '%b' "$1" >"$file"
	run bash -c '
		set -eo pipefail
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$1"
		echo "lines=$COVERAGE_LINES branches=$COVERAGE_BRANCHES functions=$COVERAGE_FUNCTIONS statements=$COVERAGE_STATEMENTS"
	' _ "$file"
	assert_success
}

@test "extract_coverage_details: malformed LCOV counts are invalid before any arithmetic (#1692)" {
	lcov_details 'SF:a\nLF:10\nLH:5\nBRF:oops\nBRH:2\nend_of_record\n'
	assert_output "lines=50.00 branches=invalid functions=n/a statements=50.00"
	lcov_details 'SF:a\nLF:1\nLH:1junk\nend_of_record\n'
	assert_output "lines=invalid branches=n/a functions=n/a statements=invalid"
	# One bad record among good ones spoils the whole total.
	lcov_details 'SF:a\nLF:4\nLH:2\nend_of_record\nSF:b\nLF:-4\nLH:2\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nLH:2\nFNF:2\nFNH:2.0\nend_of_record\n'
	assert_output "lines=50.00 branches=n/a functions=invalid statements=50.00"
	lcov_details 'SF:a\nLF:4\nLH:2\nFNF:1234567890\nFNH:2\nend_of_record\n'
	assert_output --partial "functions=invalid"
}

@test "extract_coverage_details: an LCOV hit total without its found total, or above it, is invalid (#1692)" {
	lcov_details 'SF:a\nLF:4\nLH:5\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nLH:2\nBRH:1\nend_of_record\n'
	assert_output --partial "branches=invalid"
	lcov_details 'SF:a\nLF:0\nLH:1\nend_of_record\n'
	assert_output --partial "lines=invalid"
}

@test "extract_coverage_details: well-formed LCOV keeps 0, n/a and CRLF line endings as before (#1692)" {
	lcov_details 'SF:a\r\nLF:4\r\nLH:1\r\nBRF:0\r\nBRH:0\r\nend_of_record\r\n'
	assert_output "lines=25.00 branches=n/a functions=n/a statements=25.00"
	lcov_details 'SF:a\nLF:0\nLH:0\nend_of_record\n'
	assert_output "lines=0 branches=n/a functions=n/a statements=0"
}

# Prints lines and branches for one Cobertura root element.
cobertura_details() {
	local file="${BATS_TEST_TMPDIR}/coverage.xml"
	printf '<?xml version="1.0" ?>\n%s\n<packages><package line-rate="0.5" branch-rate="0.5"/></packages>\n</coverage>\n' \
		"$1" >"$file"
	run bash -c '
		set -eo pipefail
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$1"
		echo "lines=$COVERAGE_LINES branches=$COVERAGE_BRANCHES"
	' _ "$file"
	assert_success
}

@test "extract_coverage_details: malformed or missing Cobertura root rates are invalid (#1692)" {
	cobertura_details '<coverage line-rate="1..0" branch-rate="0.8">'
	assert_output "lines=invalid branches=80.00"
	cobertura_details '<coverage lines-valid="10" branch-rate="0.8">'
	assert_output "lines=invalid branches=80.00"
	cobertura_details '<coverage line-rate="1.01" branch-rate="-0.1">'
	assert_output "lines=invalid branches=invalid"
	cobertura_details '<coverage line-rate=" 0.5" branch-rate="0.5x">'
	assert_output "lines=invalid branches=invalid"
}

@test "extract_coverage_details: Cobertura reads the root element only, as coverage.py writes it (#1692)" {
	cobertura_details '<coverage version="7.6.1" line-rate="1.234e-05" branch-rate="0" complexity="0">'
	assert_output "lines=0.00 branches=0.00"
	# A minified report: nested rates on the same line are not the root's.
	cobertura_details '<coverage line-rate="1" branch-rate="0.75"><sources/><x line-rate="0.1" branch-rate="0.2"/>'
	assert_output "lines=100.00 branches=75.00"
	# Without branch-rate, branches keep their old initial 0.
	cobertura_details '<coverage line-rate="0.9">'
	assert_output "lines=90.00 branches=0"
}

@test "extract.sh: COVERAGE_INVALID is invalid" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh" && echo "$COVERAGE_INVALID"'
	assert_success
	assert_output "invalid"
}

@test "extract_coverage_percent: line-only LCOV fixture under set -eo pipefail" {
	run bash -c '
		set -eo pipefail
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_percent "$FIXTURES_DIR/coverage/lcov-line-only.info"
	'
	assert_success
	assert_output "50.00"
}

@test "extract_coverage_percent: coverage.json fixture is read as coverage-py" {
	run bash -c '
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_percent "$FIXTURES_DIR/coverage/coverage.json"
	'
	assert_success
	assert_output "80.0"
}

@test "extract.sh: COVERAGE_NOT_MEASURED is n/a" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh" && echo "$COVERAGE_NOT_MEASURED"'
	assert_success
	assert_output "n/a"
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
