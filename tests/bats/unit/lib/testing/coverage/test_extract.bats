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
    "functions": {"total": 10, "covered": 9, "skipped": 0, "pct": 90},
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

@test "extract_coverage_percent: an LCOV file without a record is unreadable, not 0 (#1692)" {
	local file="${BATS_TEST_TMPDIR}/empty.info"
	echo "TN:" >"$file"

	run bash -c "source \"\$LIB_DIR/testing/coverage/extract.sh\" && extract_coverage_percent \"$file\""
	assert_failure 1
	assert_output "invalid"
}

@test "extract_coverage_percent: an LCOV record with LF:0 is still 0" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh" && extract_coverage_percent "$FIXTURES_DIR/coverage/lcov-empty.info"'
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

# =============================================================================
# LCOV records validated one by one before they are added (#1692 review)
# =============================================================================

# Prints the line percentage extract_coverage_percent gives, and its status.
lcov_percent() {
	local file="${BATS_TEST_TMPDIR}/percent.info"
	printf '%b' "$1" >"$file"
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh"; extract_coverage_percent "$1"; echo "rc=$?"' _ "$file"
	assert_success
}

@test "extract: an LCOV record without LF/LH cannot hide behind another record's totals (#1692)" {
	lcov_details 'SF:a\nDA:1,1\nLF:1\nLH:1\nend_of_record\nSF:b\nDA:1,0\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_percent 'SF:a\nDA:1,1\nLF:1\nLH:1\nend_of_record\nSF:b\nDA:1,0\nend_of_record\n'
	assert_output $'invalid\nrc=1'
	# Each total in its own record: the pair is never completed by the other.
	lcov_details 'SF:a\nLF:1\nend_of_record\nSF:b\nLH:1\nend_of_record\n'
	assert_output --partial "lines=invalid"
}

@test "extract: LCOV hits are checked against found in each record, not the file (#1692)" {
	lcov_details 'SF:a\nLF:1\nLH:2\nend_of_record\nSF:b\nLF:9\nLH:8\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:10\nLH:20\nend_of_record\nSF:b\nLF:10\nLH:0\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:10\nLH:0\nend_of_record\nSF:b\nLF:0\nLH:10\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:10\nLH:10\nBRF:5\nBRH:0\nend_of_record\nSF:b\nLF:5\nLH:5\nBRH:5\nend_of_record\n'
	assert_output "lines=100.00 branches=invalid functions=n/a statements=100.00"
}

@test "extract: an LCOV total given twice in one record is unreadable (#1692)" {
	lcov_details 'SF:a\nLF:1\nLH:0\nLF:9\nLH:9\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nLH:2\nFNF:2\nFNH:1\nFNH:1\nend_of_record\n'
	assert_output "lines=50.00 branches=n/a functions=invalid statements=50.00"
}

@test "extract: an LCOV total key in the wrong case or spacing is not dropped (#1692)" {
	lcov_details 'SF:a\nlf:90\nLH:0\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nLH:4\nend_of_record\nSF:b\nLF :90\nLH:0\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nLH:4\nbrf:9\nend_of_record\n'
	assert_output "lines=100.00 branches=invalid functions=n/a statements=100.00"
}

@test "extract: LCOV data lines without their totals make that metric unreadable (#1692)" {
	lcov_details 'SF:a\nLF:4\nLH:4\nBRDA:1,0,0,1\nend_of_record\n'
	assert_output "lines=100.00 branches=invalid functions=n/a statements=100.00"
	lcov_details 'SF:a\nLF:4\nLH:4\nFN:1,f\nFNDA:1,f\nend_of_record\n'
	assert_output "lines=100.00 branches=n/a functions=invalid statements=100.00"
	# A record that measures nothing at all still needs its line totals.
	lcov_details 'SF:a\nLF:4\nLH:4\nend_of_record\nSF:b\nend_of_record\n'
	assert_output --partial "lines=invalid"
}

@test "extract: LCOV text outside a record and unclosed records are unreadable (#1692)" {
	# A total after the last end_of_record belongs to no record.
	lcov_details 'SF:a\nLF:4\nLH:4\nend_of_record\nLF:5\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nLH:4\nend_of_record\nsomething else\n'
	assert_output --partial "lines=invalid"
	lcov_details 'SF:a\nLF:4\nLH:4\nend_of_record\nSF:b\nLF:4\nLH:4\n'
	assert_output "lines=invalid branches=invalid functions=invalid statements=invalid"
	lcov_details 'SF:a\nLF:4\nSF:b\nLF:4\nLH:4\nend_of_record\n'
	assert_output --partial "lines=invalid"
	lcov_details 'end_of_record\nSF:a\nLF:4\nLH:4\nend_of_record\n'
	assert_output --partial "lines=invalid"
}

@test "extract: well-formed LCOV from the supported producers still reads as before (#1692)" {
	# The same source file in two records (geninfo per test name), blank
	# lines, TN: between records, lcov 2.x VER:/FNL:/FNA: keys, a BOM and CRLF.
	lcov_details 'TN:t1\nSF:a\nDA:1,1\nLF:2\nLH:1\nend_of_record\n\nTN:t2\nSF:a\nDA:1,1\nLF:2\nLH:2\nend_of_record\n'
	assert_output "lines=75.00 branches=n/a functions=n/a statements=75.00"
	lcov_details 'SF:a\nVER:#1\nFNL:0,1,2\nFNA:0,1,f\nFNF:1\nFNH:1\nLF:2\nLH:2\nend_of_record\n'
	assert_output "lines=100.00 branches=n/a functions=100.00 statements=100.00"
	lcov_details '\xef\xbb\xbfSF:a\r\nDA:1,1\r\nLF:1\r\nLH:1\r\nend_of_record\r\n'
	assert_output "lines=100.00 branches=n/a functions=n/a statements=100.00"
	# BRF:0/BRH:0 is not measured; BRF:0 without its BRH is an incomplete pair.
	lcov_details 'SF:a\nLF:2\nLH:1\nBRF:0\nBRH:0\nend_of_record\n'
	assert_output "lines=50.00 branches=n/a functions=n/a statements=50.00"
	lcov_details 'SF:a\nLF:2\nLH:1\nBRF:0\nend_of_record\n'
	assert_output "lines=50.00 branches=invalid functions=n/a statements=50.00"
	local fixture
	for fixture in rust/coverage-full.lcov rust/coverage-partial.lcov detect/lcov-python.info; do
		run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh"; extract_coverage_percent "$FIXTURES_DIR/$1"' _ "$fixture"
		assert_success
	done
}

@test "extract_coverage_percent: a malformed LCOV total is unreadable, not a percentage (#1692)" {
	lcov_percent 'TN:\nSF:a\nDA:1,1\nLF:10\nLH:10\nend_of_record\nSF:b\nDA:1,0\nLF:oops\nLH:0\nend_of_record\n'
	assert_output $'invalid\nrc=1'
	lcov_percent 'SF:a\nLF:+1\nLH:1\nend_of_record\n'
	assert_output $'invalid\nrc=1'
	lcov_percent 'SF:a\nLF:1\nLH:1\nLH:1\nend_of_record\n'
	assert_output $'invalid\nrc=1'
	lcov_percent 'SF:a\nDA:1,1\nLF:1\nLH:1junk\nend_of_record\n'
	assert_output $'invalid\nrc=1'
	lcov_percent 'SF:a\nDA:1,1\nLF:4\nLH:1\nend_of_record\n'
	assert_output $'25.00\nrc=0'
}

# =============================================================================
# Cobertura: the document root, read by a real XML parse (#1692 review)
# =============================================================================

# Prints lines and branches, and the percentage, for one whole document.
cobertura_doc() {
	local file="${BATS_TEST_TMPDIR}/doc.xml"
	printf '%s' "$1" >"$file"
	run bash -c '
		exec 2>"$2"
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$1"
		echo "lines=$COVERAGE_LINES branches=$COVERAGE_BRANCHES percent=$(extract_coverage_percent "$1")"
	' _ "$file" "${BATS_TEST_TMPDIR}/stderr"
	assert_success
}

@test "extract: a Cobertura rate outside the document root is never read (#1692)" {
	cobertura_doc '<?xml version="1.0"?><report><coverage line-rate="1" branch-rate="1"/></report>'
	assert_output "lines=invalid branches=invalid percent=invalid"
	run cat "${BATS_TEST_TMPDIR}/stderr"
	assert_output --partial "Cobertura report unreadable: root element <report> is not <coverage>"
	cobertura_doc "<?xml version=\"1.0\"?><coverage foo=' line-rate=\"1\" branch-rate=\"1\"' line-rate=\"0.1\" branch-rate=\"0.1\"></coverage>"
	assert_output "lines=10.00 branches=10.00 percent=10.00"
	cobertura_doc '<?xml version="1.0"?><!-- <coverage line-rate="1" branch-rate="1"> --><coverage line-rate="0.1" branch-rate="0.1"/>'
	assert_output "lines=10.00 branches=10.00 percent=10.00"
	cobertura_doc '<?xml version="1.0"?><?pi <coverage line-rate="1" ?><coverage line-rate="0.1"/>'
	assert_output "lines=10.00 branches=0 percent=10.00"
	cobertura_doc '<?xml version="1.0"?><coverage line-rate="0.1"><![CDATA[<coverage line-rate="1">]]></coverage>'
	assert_output "lines=10.00 branches=0 percent=10.00"
}

@test "extract: a Cobertura document that is not well-formed is unreadable (#1692)" {
	cobertura_doc '<?xml version="1.0"?><coverage foo="x" line-rate="1"></coverage><coverage line-rate="0.1"/>'
	assert_output "lines=invalid branches=invalid percent=invalid"
	cobertura_doc '<?xml version="1.0"?><coverage line-rate="1" line-rate="0.1"/>'
	assert_output "lines=invalid branches=invalid percent=invalid"
	cobertura_doc '<?xml version="1.0"?><coverage line-rate="1">'
	assert_output "lines=invalid branches=invalid percent=invalid"
}

@test "extract: a present but empty or malformed Cobertura rate is unreadable (#1692)" {
	# An unreadable branch rate makes the whole report unreadable for the gate.
	cobertura_doc '<?xml version="1.0"?><coverage line-rate="1" branch-rate=""/>'
	assert_output "lines=100.00 branches=invalid percent=invalid"
	cobertura_doc '<?xml version="1.0"?><coverage line-rate="1." branch-rate="nan"/>'
	assert_output "lines=invalid branches=invalid percent=invalid"
	cobertura_doc '<?xml version="1.0"?><coverage line-rate="1e3" branch-rate="0,5"/>'
	assert_output "lines=invalid branches=invalid percent=invalid"
}

@test "extract: Cobertura entities and declarations are refused, kcov's DOCTYPE is not (#1692)" {
	cobertura_doc '<?xml version="1.0"?><!DOCTYPE coverage [<!ENTITY x SYSTEM "file:///etc/passwd">]><coverage line-rate="1"/>'
	assert_output "lines=invalid branches=invalid percent=invalid"
	cobertura_doc '<?xml version="1.0"?><!DOCTYPE coverage SYSTEM "http://example.invalid/x.dtd"><coverage line-rate="1"/>'
	assert_output "lines=invalid branches=invalid percent=invalid"
	cobertura_doc "<?xml version=\"1.0\"?><!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-04.dtd'><coverage line-rate=\"1\">&x;</coverage>"
	assert_output "lines=invalid branches=invalid percent=invalid"
	# kcov v43 (src/writers/cobertura-writer.cc), never resolved.
	cobertura_doc "<?xml version=\"1.0\" ?>
<!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-04.dtd'>
<coverage line-rate=\"0.950\" lines-covered=\"19\" lines-valid=\"20\" branch-rate=\"1.0\" branches-covered=\"1.0\" branches-rate=\"1.0\" complexity=\"1.0\" version=\"1.9\" timestamp=\"1\">
</coverage>"
	assert_output "lines=95.00 branches=100.00 percent=95.00"
}

@test "extract: Cobertura scientific notation and single quotes are read correctly (#1692)" {
	# coverage.py writes %.4g: 1.234e-05 is 0.001234%, which rounds to 0.00.
	cobertura_doc '<?xml version="1.0"?><coverage line-rate="1.234e-05" branch-rate="5e-1"/>'
	assert_output "lines=0.00 branches=50.00 percent=0.00"
	cobertura_doc "<?xml version=\"1.0\"?><coverage line-rate='0.5' branch-rate = '0.25'/>"
	assert_output "lines=50.00 branches=25.00 percent=50.00"
}

# =============================================================================
# JSON reports and the no-python3 fallback (#1692 review)
# =============================================================================

# Prints the details and the percentage for one JSON body.
json_details() {
	local file="${BATS_TEST_TMPDIR}/${2:-coverage}.json"
	printf '%s' "$1" >"$file"
	run bash -c '
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$1"
		echo "lines=$COVERAGE_LINES branches=$COVERAGE_BRANCHES functions=$COVERAGE_FUNCTIONS statements=$COVERAGE_STATEMENTS"
		extract_coverage_percent "$1"; echo "rc=$?"
	' _ "$file"
	assert_success
}

@test "extract: coverage.py JSON percentages must be numbers from 0 to 100 (#1692)" {
	local meta='"meta":{"version":"7.6.1"}'
	json_details "{${meta},\"totals\":{\"percent_covered\":null}}"
	assert_line "lines=invalid branches=0 functions=0 statements=0"
	assert_line "invalid"
	assert_line "rc=1"
	json_details "{${meta},\"totals\":{\"percent_covered\":80,\"percent_covered_branches\":null}}"
	assert_line "lines=80 branches=invalid functions=0 statements=0"
	json_details "{${meta},\"totals\":{\"percent_covered\":180}}"
	assert_line "invalid"
	json_details "{${meta},\"totals\":{\"percent_covered\":80.5,\"percent_covered_branches\":70}}"
	assert_line "lines=80.5 branches=70 functions=0 statements=0"
	assert_line "80.5"
	assert_line "rc=0"
}

@test "extract_coverage_percent: an istanbul summary's line percentage is checked (#1692)" {
	# A coverage-summary.json is detected as generic json, which has no
	# details reader (unchanged); its percentage is read, and the whole
	# summary must be readable for it to count (#1692 review).
	json_details '{"total":{"lines":{"pct":85},"branches":{"pct":90},"functions":{"pct":80},"statements":{"pct":85}}}'
	assert_line "85"
	assert_line "rc=0"
	# istanbul's json-summary always writes all four metrics, and the comment
	# reads each as required (as on main): one that is absent is unreadable
	# for the gate too (#1692, round 3).
	json_details '{"total":{"lines":{"pct":85},"branches":{"pct":90}}}'
	assert_line "invalid"
	assert_line "rc=1"
	json_details '{"total":{"lines":{"pct":85},"branches":{"pct":null}}}'
	assert_line "invalid"
	assert_line "rc=1"
	json_details '{"total":{"lines":{"pct":85},"statements":{"pct":101}}}'
	assert_line "invalid"
	json_details '{"total":{"lines":{"pct":"Unknown"},"branches":{"pct":75}}}'
	assert_line "invalid"
	assert_line "rc=1"
	json_details '{"total":{"lines":{"pct":-1}}}'
	assert_line "invalid"
}

@test "extract_coverage_details: istanbul summary metrics detected as istanbul are checked (#1692)" {
	# The summary shape under a file that detection reads as istanbul.
	local file="${BATS_TEST_TMPDIR}/summary.json"
	printf '%s' '{"total":{"lines":{"pct":85},"branches":{"pct":null},"functions":{"pct":"90"}},"x":{"path":"a","statementMap":{}}}' >"$file"
	run bash -c '
		source "$LIB_DIR/testing/coverage/extract.sh"
		detect_coverage_format "$1"
		extract_coverage_details "$1"
		echo "lines=$COVERAGE_LINES branches=$COVERAGE_BRANCHES functions=$COVERAGE_FUNCTIONS statements=$COVERAGE_STATEMENTS"
	' _ "$file"
	assert_success
	assert_line "istanbul"
	assert_line "lines=85 branches=invalid functions=invalid statements=invalid"
}

@test "extract: istanbul per-file totals that are not whole numbers are unreadable (#1692)" {
	local entry='"path":"/a.js","statementMap":{}'
	json_details "{\"/a.js\":{${entry},\"lines\":{\"total\":10,\"covered\":\"8\"},\"branches\":{\"total\":4,\"covered\":5}}}" istanbul
	# Metrics the file does not have are not measured (0), as before.
	assert_line "lines=invalid branches=invalid functions=0 statements=0"
	assert_line "invalid"
	assert_line "rc=1"
	json_details "{\"/a.js\":{${entry},\"lines\":{\"total\":10,\"covered\":8},\"branches\":{\"total\":4,\"covered\":2},\"functions\":{\"total\":0,\"covered\":0},\"statements\":{\"total\":10,\"covered\":8}}}" istanbul
	assert_line "lines=80 branches=50 functions=0 statements=80"
	assert_line "80"
}

@test "extract: a generic JSON report without a readable percentage is unreadable (#1692)" {
	json_details '{"coverage":"high"}' generic
	assert_line "invalid"
	assert_line "rc=1"
	json_details '{"something":1}' generic
	assert_line "invalid"
	json_details '{"coverage":92.5}' generic
	assert_line "92.5"
	assert_line "rc=0"
}

@test "extract: without a python3 a Cobertura report is unreadable, never read by text (#1692)" {
	local file="${BATS_TEST_TMPDIR}/coverage.xml"
	printf '<?xml version="1.0"?>\n<coverage line-rate="1" branch-rate="1">\n</coverage>\n' >"$file"
	run bash -c '
		command() { if [[ "${2:-}" == python3 ]]; then return 1; fi; builtin command "$@"; }
		source "$LIB_DIR/testing/coverage/extract.sh"
		extract_coverage_details "$1"
		echo "lines=$COVERAGE_LINES branches=$COVERAGE_BRANCHES"
	' _ "$file"
	assert_success
	assert_line --partial "::warning::No python3 on this runner; the Cobertura report cannot be read"
	assert_line "lines=invalid branches=invalid"
}

# =============================================================================
# One whole-report validity check for every consumer (#1692 second review)
# =============================================================================

# Prints the unreadable metrics, the readability status and the percentage.
readable() {
	local file="${BATS_TEST_TMPDIR}/${2:-coverage.info}"
	printf '%b' "$1" >"$file"
	run bash -c '
		source "$LIB_DIR/testing/coverage/extract.sh"
		coverage_report_readable "$1"
		echo "status=$?"
		echo "percent=$(extract_coverage_percent "$1")"
	' _ "$file"
	assert_success
}

@test "coverage_report_readable: a malformed branch or function total makes the whole LCOV unreadable (#1692)" {
	readable 'SF:a\nDA:1,1\nLF:1\nLH:1\nBRF:oops\nBRH:1\nend_of_record\n'
	assert_output $'branches\nstatus=1\npercent=invalid'
	readable 'SF:a\nDA:1,1\nLF:1\nLH:1\nBRH:5\nend_of_record\n'
	assert_output $'branches\nstatus=1\npercent=invalid'
	readable 'SF:a\nDA:1,1\nLF:1\nLH:1\nFNF:1\nFNH:1\nFNH:1\nend_of_record\n'
	assert_output $'functions\nstatus=1\npercent=invalid'
	readable 'SF:a\nDA:1,1\nLF:4\nLH:1\nBRF:2\nBRH:1\nFNF:1\nFNH:1\nend_of_record\n'
	assert_output $'status=0\npercent=25.00'
}

@test "coverage_report_readable: Cobertura, coverage.py and istanbul summaries are judged whole (#1692)" {
	readable '<?xml version="1.0"?>\n<coverage line-rate="1" branch-rate="">\n</coverage>\n' coverage.xml
	assert_output $'branches\nstatus=1\npercent=invalid'
	readable '{"meta":{"version":"7.6.1"},"totals":{"percent_covered":95,"num_branches":null,"covered_branches":null}}' coverage.json
	assert_output $'branches\nstatus=1\npercent=invalid'
	readable '{"total":{"lines":{"pct":85},"branches":{"pct":90},"functions":{"pct":101},"statements":{"pct":85}}}' summary.json
	assert_output $'functions\nstatus=1\npercent=invalid'
	readable '{"total":{"lines":{"pct":85},"branches":{"pct":90},"functions":{"pct":80},"statements":{"pct":85}}}' summary.json
	assert_output $'status=0\npercent=85'
	readable '{"total":{"lines":{"pct":85},"branches":{"pct":90}}}' summary.json
	assert_output $'functions\nstatements\nstatus=1\npercent=invalid'
}

@test "coverage_report_readable: a missing file or an unknown format is left to the caller (#1692)" {
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh"; coverage_report_readable /nonexistent; echo "status=$?"'
	assert_output "status=2"
	printf '<html></html>' >"${BATS_TEST_TMPDIR}/report.html"
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh"; coverage_report_readable "$1"; echo "status=$?"' \
		_ "${BATS_TEST_TMPDIR}/report.html"
	assert_output "status=2"
}

@test "extract: coverage.py branch keys must agree with each other and be counts in range (#1692)" {
	local meta='"meta":{"version":"7.6.1"}' totals
	for totals in '"num_branches":10,"covered_branches":5,"percent_covered_branches":95' \
		'"num_branches":10,"covered_branches":5,"percent_branches_covered":95' \
		'"num_branches":1e400,"covered_branches":5' '"num_branches":10,"covered_branches":5.5' \
		'"num_branches":10,"covered_branches":5,"percent_covered_branches":500'; do
		readable "{${meta},\"totals\":{\"percent_covered\":90,${totals}}}" coverage.json
		assert_output $'branches\nstatus=1\npercent=invalid'
	done
	# Rounded display values within half a point still agree.
	readable "{${meta},\"totals\":{\"percent_covered\":90,\"num_branches\":3,\"covered_branches\":2,\"percent_branches_covered\":66.67}}" coverage.json
	assert_output $'status=0\npercent=90'
}

@test "extract: an LCOV file with a NUL byte is unreadable on every awk (#1692)" {
	# BWK awk (macOS) ends a line at a NUL: LH:10<NUL>junk would read as LH:10.
	readable 'SF:a\nLF:10\nLH:10\0junk\nend_of_record\n'
	assert_output $'lines\nbranches\nfunctions\nstatements\nstatus=1\npercent=invalid'
}

@test "extract: LCOV totals are summed without wrapping at 2^31 (#1692)" {
	local file="${BATS_TEST_TMPDIR}/big.info" index
	for index in 1 2 3; do
		printf 'SF:f%s\nLF:999999999\nLH:999999999\nend_of_record\n' "$index" >>"$file"
	done
	run bash -c 'source "$LIB_DIR/testing/coverage/extract.sh"; _lcov_read_metrics "$1"' _ "$file"
	assert_success
	assert_output "2999999997 2999999997 absent absent absent absent"
}
