#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/collect-coverage.sh (#1078)
#
# Covers the coverage-format integrity contract: LCOV stays LCOV when no
# output format is requested, a conversion nothing implements fails by name
# with exit 2, and the tests/fixtures/coverage inputs (line-only, full, empty,
# invalid LCOV plus a coverage.py JSON report) each produce the documented
# result instead of an empty report.

load "../../../helpers/common"
load "../../../helpers/github_env"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/collect-coverage.sh"

setup() {
	setup_temp_dir
	setup_github_env
	save_path
	export WORK="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Run one STEP of the script inside $WORK with the given VAR=value pairs
run_step() {
	local step="$1"
	shift
	# shellcheck disable=SC2016 # $WORK and $SCRIPT are expanded by the inner bash
	run env STEP="$step" WORK="$WORK" SCRIPT="$SCRIPT" "$@" bash -c 'cd "$WORK" && exec bash "$SCRIPT"'
}

# Assert that no line in GITHUB_OUTPUT starts with "<key>="
refute_github_output_key() {
	if grep -q "^$1=" "$GITHUB_OUTPUT"; then
		echo "# Expected GITHUB_OUTPUT not to contain key: $1" >&2
		return 1
	fi
}

# =============================================================================
# merge: output format follows the input when none is requested
# =============================================================================

@test "collect-coverage merge: line-only LCOV stays LCOV and reports line coverage" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"

	run_step merge COVERAGE_FILES=lcov.info
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.lcov"
	assert_github_output "coverage-percent" "50.00"
	assert_file_exists "$WORK/merged-coverage.lcov"
	refute_output --partial "Converting"
}

@test "collect-coverage merge: full LCOV passes through without calling lcov" {
	install_fixture "coverage/lcov-full.info" "$WORK/lcov.info"
	# A single file is copied, so neither the lcov binary nor the awk fallback
	# (which rejects BR/FN records) is involved
	mock_command_record "lcov" ""

	run_step merge COVERAGE_FILES=lcov.info
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.lcov"
	assert_github_output "coverage-percent" "62.50"
	# Branch and function records survive the pass-through
	assert_file_contains "$WORK/merged-coverage.lcov" "^BRF:4"
	assert_file_contains "$WORK/merged-coverage.lcov" "^FNF:2"
	[[ ! -s "${BATS_TEST_TMPDIR}/mock_calls_lcov" ]] || fail "lcov was called for a single file"
}

@test "collect-coverage merge: empty LCOV merges to 0% with a warning, not silently" {
	install_fixture "coverage/lcov-empty.info" "$WORK/lcov.info"

	run_step merge COVERAGE_FILES=lcov.info
	assert_success
	assert_github_output "coverage-percent" "0"
	assert_output --partial "::warning::merged LCOV has no lines found"
}

@test "collect-coverage merge: invalid LCOV fails by name before merging" {
	install_fixture "coverage/lcov-invalid.info" "$WORK/lcov.info"

	run_step merge COVERAGE_FILES=lcov.info
	assert_failure 1
	assert_output --partial "invalid lcov"
	assert_output --partial "Coverage file is not valid lcov: lcov.info"
	assert_file_not_exists "$WORK/merged-coverage.lcov"
	assert_file_not_exists "$WORK/merged-coverage.json"
}

@test "collect-coverage merge: coverage.py JSON report stays JSON" {
	install_fixture "coverage/coverage.json" "$WORK/coverage.json"

	run_step merge COVERAGE_FILES=coverage.json
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.json"
	assert_github_output "coverage-percent" "80.0"
	run jq -r '.totals.percent_covered' "$WORK/merged-coverage.json"
	assert_output "80.0"
}

@test "collect-coverage merge: lone coverage.py data file is rendered with the coverage CLI, never copied as JSON" {
	# Minimal SQLite-headed stand-in for a .coverage data file
	printf 'SQLite format 3\000rest-of-data' >"$WORK/.coverage"
	# shellcheck disable=SC2016 # case body runs inside the mock, not here
	mock_command_multi "coverage" '
		json\ -o\ *) printf "{\"meta\":{\"version\":\"7.6.1\"},\"totals\":{\"percent_covered\":42.0}}\n" >"${3}";;
		*) echo "unexpected coverage args: $*" >&2; exit 1;;
	'

	run_step merge COVERAGE_FILES=.coverage
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.json"
	assert_github_output "coverage-percent" "42.0"
	run jq -r '.totals.percent_covered' "$WORK/merged-coverage.json"
	assert_output "42.0"
}

@test "collect-coverage merge: lone coverage.py data file renders straight to a requested lcov output" {
	printf 'SQLite format 3\000rest-of-data' >"$WORK/.coverage"
	# shellcheck disable=SC2016 # case body runs inside the mock, not here
	mock_command_multi "coverage" '
		lcov\ -o\ *) printf "TN:\nSF:src/a.py\nDA:1,1\nDA:2,0\nLF:2\nLH:1\nend_of_record\n" >"${3}";;
		*) echo "unexpected coverage args: $*" >&2; exit 1;;
	'

	run_step merge COVERAGE_FILES=.coverage OUTPUT_FORMAT=lcov
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.lcov"
	assert_github_output "merged-format" "lcov"
	assert_github_output "coverage-percent" "50.00"
	refute_output --partial "unsupported coverage conversion"
}

@test "collect-coverage merge: explicit lcov label over a coverage.py JSON report fails by name" {
	install_fixture "coverage/coverage.json" "$WORK/coverage.json"

	run_step merge COVERAGE_FILES=coverage.json INPUT_FORMAT=lcov
	assert_failure 1
	assert_output --partial "invalid lcov"
	assert_file_not_exists "$WORK/merged-coverage.lcov"
}

@test "collect-coverage merge: lone coverage.py data file without the coverage CLI fails by name" {
	if command -v coverage >/dev/null 2>&1; then
		skip "a real coverage CLI is on PATH"
	fi
	printf 'SQLite format 3\000rest-of-data' >"$WORK/.coverage"

	run_step merge COVERAGE_FILES=.coverage
	assert_failure 1
	assert_output --partial "Cannot read coverage.py data file without the coverage CLI"
	assert_file_not_exists "$WORK/merged-coverage.json"
}

@test "collect-coverage merge: explicit coverage-py label over a Cobertura XML validates the file, not the label" {
	install_fixture "coverage/sample_cobertura.xml" "$WORK/coverage.xml"

	run_step merge COVERAGE_FILES=coverage.xml INPUT_FORMAT=coverage-py
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.xml"
	assert_github_output "merged-format" "cobertura"
	assert_github_output "coverage-percent" "85.00"
}

@test "collect-coverage merge: explicit lcov label over a Cobertura XML fails by name, never 0%" {
	install_fixture "coverage/sample_cobertura.xml" "$WORK/coverage.xml"

	run_step merge COVERAGE_FILES=coverage.xml INPUT_FORMAT=lcov
	assert_failure 1
	assert_output --partial "invalid lcov"
	assert_file_not_exists "$WORK/merged-coverage.lcov"
}

@test "collect-coverage merge: explicit istanbul label over a Cobertura XML fails by name" {
	install_fixture "coverage/sample_cobertura.xml" "$WORK/coverage.xml"

	run_step merge COVERAGE_FILES=coverage.xml INPUT_FORMAT=istanbul
	assert_failure 1
	assert_output --partial "invalid json"
	assert_file_not_exists "$WORK/merged-coverage.json"
}

@test "collect-coverage merge: cobertura label over a Clover XML is rejected, not passed through" {
	install_fixture "detect/clover-php.xml" "$WORK/clover.xml"

	run_step merge COVERAGE_FILES=clover.xml INPUT_FORMAT=cobertura
	assert_failure 1
	assert_output --partial "Cannot use a clover file under the cobertura label"
}

@test "collect-coverage merge: reports merged-format for LCOV and JSON inputs" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"
	run_step merge COVERAGE_FILES=lcov.info
	assert_success
	assert_github_output "merged-format" "lcov"

	: >"$GITHUB_OUTPUT"
	install_fixture "coverage/coverage.json" "$WORK/coverage.json"
	run_step merge COVERAGE_FILES=coverage.json
	assert_success
	assert_github_output "merged-format" "json"
}

@test "collect-coverage merge: undetectable input fails with a message" {
	echo "nothing to see" >"$WORK/report.txt"

	run_step merge COVERAGE_FILES=report.txt
	assert_failure 1
	assert_output --partial "Cannot detect coverage format: report.txt"
}

@test "collect-coverage merge: explicit json output on a coverage.py report is a no-op conversion" {
	install_fixture "coverage/coverage.json" "$WORK/coverage.json"

	run_step merge COVERAGE_FILES=coverage.json OUTPUT_FORMAT=json
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.json"
}

@test "collect-coverage merge: explicit lcov output on LCOV input keeps the file" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"

	run_step merge COVERAGE_FILES=lcov.info OUTPUT_FORMAT=lcov
	assert_success
	assert_github_output "merged-coverage-file" "merged-coverage.lcov"
}

# =============================================================================
# merge: unsupported conversions fail by name, never an empty report
# =============================================================================

@test "collect-coverage merge: LCOV to json has no converter and exits 2" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"

	run_step merge COVERAGE_FILES=lcov.info OUTPUT_FORMAT=json
	assert_failure 2
	assert_output --partial "::error::unsupported coverage conversion: lcov -> json"
	assert_file_not_exists "$WORK/merged-coverage.json"
	refute_github_output_key "merged-coverage-file"
	refute_github_output_key "coverage-percent"
}

@test "collect-coverage merge: unsupported conversion is refused before a merge that would itself fail" {
	install_fixture "coverage/lcov-full.info" "$WORK/a.info"
	install_fixture "coverage/lcov-full.info" "$WORK/b.info"
	# Two full LCOV files need the lcov binary; shadow it with one that fails
	# so the awk fallback path (which rejects BR/FN records) is what would run
	mock_command "lcov" "lcov should not be reached" 1

	run_step merge COVERAGE_FILES="a.info,b.info" OUTPUT_FORMAT=json
	assert_failure 2
	assert_output --partial "::error::unsupported coverage conversion: lcov -> json"
	refute_output --partial "lcov should not be reached"
	refute_output --partial "branch/function coverage records"
}

@test "collect-coverage merge: implemented converter failing at runtime stays exit 1" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"
	# lcov -> cobertura is implemented but delegates to lcov_cobertura; when
	# that tool fails the error is a tool failure, not an unsupported pair
	mock_command "lcov_cobertura" "boom" 1

	run_step merge COVERAGE_FILES=lcov.info OUTPUT_FORMAT=cobertura
	assert_failure 1
	assert_output --partial "Conversion failed"
	refute_output --partial "unsupported coverage conversion"
	assert_file_not_exists "$WORK/merged-coverage.xml"
}

@test "collect-coverage merge: failed conversion leaves a pre-existing OUTPUT_FILE untouched" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"
	echo "caller-owned" >"$WORK/existing.xml"
	mock_command "lcov_cobertura" "boom" 1

	run_step merge COVERAGE_FILES=lcov.info OUTPUT_FORMAT=cobertura OUTPUT_FILE=existing.xml
	assert_failure 1
	assert_output --partial "Conversion failed"
	run cat "$WORK/existing.xml"
	assert_output "caller-owned"
}

@test "collect-coverage merge: a converter that emits a header-only LCOV is rejected, not published" {
	# An istanbul summary has no statementMap; the manual istanbul->lcov
	# converter falls back to a bare "TN:" file and exits 0
	echo '{"total": {"lines": {"total": 10, "covered": 8, "pct": 80}}}' >"$WORK/coverage-summary.json"

	run_step merge COVERAGE_FILES=coverage-summary.json INPUT_FORMAT=istanbul OUTPUT_FORMAT=lcov
	assert_failure 1
	assert_output --partial "Conversion produced no usable lcov report"
	assert_file_not_exists "$WORK/merged-coverage.lcov"
}

@test "collect-coverage merge: explicit json label over a coverage.py data file fails by name" {
	printf 'SQLite format 3\000rest-of-data' >"$WORK/coverage.json"

	run_step merge COVERAGE_FILES=coverage.json INPUT_FORMAT=json
	assert_failure 1
	assert_output --partial "invalid json"
	assert_file_not_exists "$WORK/merged-coverage.json"
}

@test "collect-coverage merge: unknown OUTPUT_FORMAT is rejected up front" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"

	run_step merge COVERAGE_FILES=lcov.info OUTPUT_FORMAT=yaml
	assert_failure 1
	assert_output --partial "Invalid OUTPUT_FORMAT: yaml"
}

@test "collect-coverage merge: mixed LCOV and JSON inputs are rejected" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"
	install_fixture "coverage/coverage.json" "$WORK/coverage.json"

	run_step merge COVERAGE_FILES="lcov.info,coverage.json"
	assert_failure 1
	assert_output --partial "Mixed coverage formats detected"
}

# =============================================================================
# convert step
# =============================================================================

@test "collect-coverage convert: LCOV to json exits 2 with the unsupported-conversion error" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/lcov.info"

	run_step convert INPUT_FILE=lcov.info OUTPUT_FORMAT=json
	assert_failure 2
	assert_output --partial "::error::unsupported coverage conversion: lcov -> json"
	assert_file_not_exists "$WORK/coverage.json"
}

# =============================================================================
# summary step: line-only LCOV renders n/a for unmeasured metrics
# =============================================================================

@test "collect-coverage summary: line-only LCOV renders branches and functions as n/a" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/merged-coverage.lcov"

	run_step summary COVERAGE_FILE=merged-coverage.lcov
	assert_success
	assert_github_output "lines-coverage" "50.00"
	assert_github_output "branches-coverage" "n/a"
	assert_github_output "functions-coverage" "n/a"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "| Lines | 50.00% |"
	assert_line "| Branches | n/a |"
	assert_line "| Functions | n/a |"
	refute_output --partial "| Branches | 0% |"
}

@test "collect-coverage summary: full LCOV renders every metric as a percentage" {
	install_fixture "coverage/lcov-full.info" "$WORK/merged-coverage.lcov"

	run_step summary COVERAGE_FILE=merged-coverage.lcov
	assert_success
	assert_github_output "lines-coverage" "62.50"
	assert_github_output "branches-coverage" "33.33"
	assert_github_output "functions-coverage" "66.67"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "| Branches | 33.33% |"
	assert_line "| Functions | 66.67% |"
}

@test "collect-coverage summary: empty LCOV does not fail the step and shows a real 0% for lines" {
	install_fixture "coverage/lcov-empty.info" "$WORK/merged-coverage.lcov"

	run_step summary COVERAGE_FILE=merged-coverage.lcov
	assert_success
	assert_github_output "lines-coverage" "0"
	assert_github_output "branches-coverage" "n/a"
	assert_github_output "functions-coverage" "n/a"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "| Lines | 0% |"
	assert_line "| Branches | n/a |"
}

@test "collect-coverage merge: unrelated JSON is rejected instead of reading as 0%" {
	echo '{"unrelated": true}' >"$WORK/coverage.json"

	run_step merge COVERAGE_FILES=coverage.json
	assert_failure 1
	assert_output --partial "not a parsable coverage report"
	assert_file_not_exists "$WORK/merged-coverage.json"
}

# =============================================================================
# detect step
# =============================================================================

@test "collect-coverage detect: finds lcov.info and labels it lcov" {
	install_fixture "coverage/lcov-line-only.info" "$WORK/coverage-artifacts/lcov.info"

	run_step detect
	assert_success
	assert_github_output "files-found" "1"
	assert_output --partial "coverage-artifacts/lcov.info (lcov)"
}
