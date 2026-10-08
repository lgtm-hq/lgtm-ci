#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Conformance tests for the results.v1 contract (#1080):
#          scripts/ci/lib/testing/results.sh and schemas/results.v1.json.
#
# Every parser fixture under tests/fixtures is converted by its parser's
# *_results_v1 wrapper and validated against the schema, so a parser change
# that breaks the contract fails here rather than in a consumer's empty
# comment. The validator is a jq interpreter of the schema file itself (no
# extra binary to pin); the negative cases below prove it rejects what the
# schema forbids.

load "../../../../helpers/common"

SCHEMA="${PROJECT_ROOT}/schemas/results.v1.json"

setup() {
	setup_temp_dir
	export LIB_DIR FIXTURES_DIR SCHEMA
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

# Run a parser wrapper and validate its output; prints the document.
# Usage: _convert <wrapper> <args...>
_convert() {
	local out="${BATS_TEST_TMPDIR}/doc.json"
	bash -c '
		source "$LIB_DIR/testing.sh"
		"$@" >"$0"
	' "$out" "$@"
	bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$1"' _ "$out"
	cat "$out"
}

# =============================================================================
# Schema file
# =============================================================================

@test "results.v1 schema: is valid JSON and declares the six required properties" {
	run jq -c '.required' "$SCHEMA"
	assert_success
	assert_output '["tool","status","counts","duration_ms","artifacts","source"]'
}

@test "results.v1 schema: every optional property keeps v1 additive (coverage, matrix, exit_code)" {
	run jq -r '.properties | keys[]' "$SCHEMA"
	assert_success
	assert_line "coverage"
	assert_line "matrix"
	assert_line "exit_code"
}

# =============================================================================
# Validator
# =============================================================================

@test "results_v1_validate: accepts the minimal valid document" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json"'
	assert_success
	assert_output ""
}

@test "results_v1_validate: accepts the full valid document" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-full.json"'
	assert_success
}

@test "results_v1_validate: reports every missing required property" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/invalid-missing-required.json"'
	assert_failure 1
	assert_output --partial '$: missing required property duration_ms'
	assert_output --partial '$.counts: missing required property total'
	assert_output --partial '$.source: missing required property version'
}

@test "results_v1_validate: rejects wrong types, bad enums, ranges, patterns and unknown properties" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/invalid-types-and-extras.json"'
	assert_failure 1
	assert_output --partial '$.tool: must be at least 1 character(s)'
	assert_output --partial '$.status: must be one of "passed", "failed", "no-tests", "error"'
	assert_output --partial '$.counts.passed: expected integer, got string'
	assert_output --partial '$.counts.failed: must be >= 0'
	assert_output --partial '$.counts.skipped: expected integer, got number'
	assert_output --partial '$.duration_ms: expected integer, got string'
	assert_output --partial '$.coverage.lines: must be <= 100'
	assert_output --partial '$.coverage: unexpected property statements'
	assert_output --partial '$.artifacts[0].kind: must match ^[a-z][a-z0-9-]*$'
	assert_output --partial '$.artifacts[0].path: must be at least 1 character(s)'
	assert_output --partial '$: unexpected property summary'
}

@test "results_v1_validate: a file that is not JSON is a hard error (2), not a schema violation" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/invalid-not-json.json"'
	assert_failure 2
	assert_output --partial "not valid JSON"
}

@test "results_v1_validate: a missing file is a hard error (2)" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$BATS_TEST_TMPDIR/absent.json"'
	assert_failure 2
	assert_output --partial "file not found"
}

@test "results_v1_validate: a missing schema is a hard error (2)" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_V1_SCHEMA=/nonexistent/schema.json results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json"'
	assert_failure 2
	assert_output --partial "schema not found"
}

@test "results_v1_validate: refuses a schema keyword the interpreter does not implement" {
	jq '.properties.tool.oneOf = [{"type": "string"}]' "$SCHEMA" >"${BATS_TEST_TMPDIR}/schema.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json" "$1"' _ "${BATS_TEST_TMPDIR}/schema.json"
	assert_failure 2
	assert_output --partial "unsupported schema keyword(s): oneOf"
}

@test "results_v1_validate: resolves local \$ref definitions (artifact items)" {
	jq '.artifacts = [{"kind": "report", "path": "x"}, {"kind": "report"}]' \
		"$FIXTURES_DIR/results/valid-minimal.json" >"${BATS_TEST_TMPDIR}/doc.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$1"' _ "${BATS_TEST_TMPDIR}/doc.json"
	assert_failure 1
	assert_output --partial '$.artifacts[1]: missing required property path'
}

# =============================================================================
# Builder
# =============================================================================

@test "results_v1_build: emits a schema-valid document from the environment" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		TESTS_PASSED=3 TESTS_FAILED=0 TESTS_SKIPPED=1 TESTS_TOTAL=4 TESTS_DURATION_MS=1500 EXIT_CODE=0 \
		COVERAGE_LINES=85.5 COVERAGE_BRANCHES=n/a COVERAGE_FUNCTIONS=Unknown \
		RESULTS_ARTIFACTS=$'"'"'report=x/pytest-results.json\ncoverage=x/coverage.json'"'"' \
		MATRIX_KEY=python-version MATRIX_VALUE=3.12 \
		RESULTS_TOOL=pytest RESULTS_RUNNER=run-pytest RESULTS_SOURCE_VERSION=deadbeef \
		results_v1_build >"$BATS_TEST_TMPDIR/doc.json"
		results_v1_validate "$BATS_TEST_TMPDIR/doc.json"
		jq -c "{status, counts, duration_ms, coverage, artifacts: (.artifacts | length), matrix, exit_code, source}" "$BATS_TEST_TMPDIR/doc.json"
	'
	assert_success
	assert_output '{"status":"passed","counts":{"passed":3,"failed":0,"skipped":1,"total":4},"duration_ms":1500,"coverage":{"lines":85.5},"artifacts":2,"matrix":{"key":"python-version","value":"3.12"},"exit_code":0,"source":{"runner":"run-pytest","version":"deadbeef"}}'
}

@test "results_v1_build: status rule - failed count, non-zero exit, no tests, parse error" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		export RESULTS_TOOL=t RESULTS_RUNNER=r
		TESTS_FAILED=1 TESTS_TOTAL=3 results_v1_build | jq -r .status
		TESTS_FAILED=0 TESTS_TOTAL=3 EXIT_CODE=2 results_v1_build | jq -r .status
		TESTS_FAILED=0 TESTS_TOTAL=0 EXIT_CODE=0 results_v1_build | jq -r .status
		TESTS_FAILED=0 TESTS_TOTAL=3 EXIT_CODE=0 results_v1_build | jq -r .status
		RESULTS_PARSE_STATUS=missing TESTS_TOTAL=3 results_v1_build | jq -r .status
		RESULTS_STATUS=passed TESTS_TOTAL=0 results_v1_build | jq -r .status
	'
	assert_success
	assert_line --index 0 "failed"
	assert_line --index 1 "failed"
	assert_line --index 2 "no-tests"
	assert_line --index 3 "passed"
	assert_line --index 4 "error"
	assert_line --index 5 "passed"
}

@test "results_v1_build: omits coverage without a lines value and never emits a non-numeric metric" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		export RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1
		COVERAGE_LINES="" COVERAGE_BRANCHES=50 results_v1_build | jq -c "has(\"coverage\")"
		COVERAGE_LINES=N/A results_v1_build | jq -c "has(\"coverage\")"
		COVERAGE_LINES=90.0 COVERAGE_BRANCHES=Unknown COVERAGE_FUNCTIONS=12.5 results_v1_build | jq -c .coverage
	'
	assert_success
	assert_line --index 0 "false"
	assert_line --index 1 "false"
	assert_line --index 2 '{"lines":90.0,"functions":12.5}'
}

@test "results_v1_build: source.version falls back to LGTM_CI_TOOLING_SHA then unknown" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		export RESULTS_TOOL=t RESULTS_RUNNER=r
		results_v1_build | jq -r .source.version
		LGTM_CI_TOOLING_SHA=abc123 results_v1_build | jq -r .source.version
		LGTM_CI_TOOLING_SHA=abc123 RESULTS_SOURCE_VERSION=explicit results_v1_build | jq -r .source.version
	'
	assert_success
	assert_line --index 0 "unknown"
	assert_line --index 1 "abc123"
	assert_line --index 2 "explicit"
}

@test "results_v1_write: creates parent directories, writes, and validates" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		cd "$BATS_TEST_TMPDIR"
		RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1 results_v1_write "$(results_v1_path run-x 3.12)"
		jq -r .tool results/run-x/3.12/results.json
	'
	assert_success
	assert_output "t"
}

@test "results_v1_path: single-leg runners land under default" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_path run-bats-tests ""; echo; results_v1_path run-pytest 3.13'
	assert_success
	assert_line --index 0 "results/run-bats-tests/default/results.json"
	assert_line --index 1 "results/run-pytest/3.13/results.json"
}

@test "results_v1_github_outputs: publishes the public step outputs from the document" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_github_outputs "$FIXTURES_DIR/results/valid-full.json"; cat "$GITHUB_OUTPUT"'
	assert_success
	assert_line "tests-passed=10"
	assert_line "tests-failed=2"
	assert_line "tests-skipped=1"
	assert_line "tests-total=13"
	assert_line "status=failed"
	assert_line "duration-ms=5250"
	assert_line "coverage-percent=85.5"
}

@test "results_v1_github_outputs: no coverage-percent line without coverage" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_github_outputs "$FIXTURES_DIR/results/valid-minimal.json"; cat "$GITHUB_OUTPUT"'
	assert_success
	refute_output --partial "coverage-percent"
	assert_line "status=passed"
}

# =============================================================================
# Parser conformance: every fixture through its parser and the schema
# =============================================================================

@test "conformance: every pytest report fixture validates (with and without coverage)" {
	local f
	for f in "$FIXTURES_DIR"/pytest/*.json; do
		case "$f" in *coverage*) continue ;; esac
		run _convert pytest_results_v1 "$f"
		assert_success
		run _convert pytest_results_v1 "$f" "$FIXTURES_DIR/pytest/coverage-standard.json"
		assert_success
		assert_output --partial '"lines": 85.5'
	done
}

@test "conformance: pytest coverage formats - coverage.py branches, cobertura, line-only lcov" {
	run _convert pytest_results_v1 "$FIXTURES_DIR/pytest/standard-report.json" "$FIXTURES_DIR/pytest/coverage-no-branches.json"
	assert_success
	run jq -c .coverage "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"lines":75.0}'

	run _convert pytest_results_v1 "$FIXTURES_DIR/pytest/standard-report.json" "$FIXTURES_DIR/coverage/sample_cobertura.xml"
	assert_success
	run jq -c '.coverage | keys' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["branches","lines"]'

	run _convert pytest_results_v1 "$FIXTURES_DIR/pytest/standard-report.json" "$FIXTURES_DIR/coverage/lcov-line-only.info"
	assert_success
	run jq -c '.coverage | keys' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["lines"]'
}

@test "conformance: pytest standard report carries counts, status and duration in ms" {
	run _convert pytest_results_v1 "$FIXTURES_DIR/pytest/standard-report.json"
	assert_success
	run jq -c '{status, counts, duration_ms, tool, runner: .source.runner}' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"status":"failed","counts":{"passed":10,"failed":2,"skipped":1,"total":13},"duration_ms":5250,"tool":"pytest","runner":"run-pytest"}'
}

@test "conformance: pytest missing or malformed report is status error with zero counts" {
	run _convert pytest_results_v1 "$BATS_TEST_TMPDIR/absent.json"
	assert_success
	run jq -c '[.status, .counts.total]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["error",0]'

	run _convert pytest_results_v1 "$FIXTURES_DIR/playwright/reports/json-malformed.json"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
}

@test "conformance: every vitest report fixture validates (with istanbul coverage)" {
	local f
	for f in "$FIXTURES_DIR"/vitest/*.json "$FIXTURES_DIR"/json/vitest-4-results.json; do
		case "$f" in *coverage*) continue ;; esac
		run _convert vitest_results_v1 "$f" "$FIXTURES_DIR/vitest/coverage-summary-standard.json"
		assert_success
	done
}

@test "conformance: vitest timestamps become duration_ms and todo tests are skipped" {
	run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/with-timestamps.json"
	assert_success
	run jq -r .duration_ms "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "10000"

	run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/with-todo.json"
	assert_success
	run jq -c .counts "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"passed":1,"failed":0,"skipped":3,"total":4}'
}

@test "conformance: vitest report without a numeric total is status error" {
	run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/non-numeric-total.json"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
}

@test "conformance: vitest istanbul Unknown percentages are omitted, numbers kept" {
	printf '{"total":{"lines":{"pct":90},"branches":{"pct":"Unknown"},"functions":{"pct":100}}}' \
		>"${BATS_TEST_TMPDIR}/cov.json"
	run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/all-passing.json" "${BATS_TEST_TMPDIR}/cov.json"
	assert_success
	run jq -c .coverage "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"lines":90,"functions":100}'
}

@test "conformance: every playwright fixture validates, including native reporter output" {
	local f
	for f in "$FIXTURES_DIR"/playwright/*.json "$FIXTURES_DIR"/playwright/reports/*.json; do
		run _convert playwright_results_v1 "$f"
		assert_success
	done
}

@test "conformance: playwright native mixed report - counts, half-up ms duration, failed status" {
	run _convert playwright_results_v1 "$FIXTURES_DIR/playwright/reports/json-mixed.json"
	assert_success
	run jq -c '{status, counts, duration_ms}' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"status":"failed","counts":{"passed":1,"failed":2,"skipped":1,"total":4},"duration_ms":2375}'
}

@test "conformance: playwright malformed and missing reports are status error" {
	run _convert playwright_results_v1 "$FIXTURES_DIR/playwright/reports/json-malformed.json"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
	run _convert playwright_results_v1 "$BATS_TEST_TMPDIR/absent.json"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
}

@test "conformance: every junit fixture validates (nextest tool label, lcov coverage)" {
	local f
	for f in "$FIXTURES_DIR"/junit/*.xml "$FIXTURES_DIR"/rust/*.xml "$FIXTURES_DIR"/playwright/reports/junit-mixed.xml; do
		RESULTS_TOOL=cargo-nextest run _convert junit_results_v1 "$f" "$FIXTURES_DIR/rust/coverage-partial.lcov"
		assert_success
		assert_output --partial '"tool": "cargo-nextest"'
		assert_output --partial '"lines": 75.00'
	done
}

@test "conformance: junit skipped tests count under skipped and in total" {
	run _convert junit_results_v1 "$FIXTURES_DIR/rust/junit-skipped-pass-rate.xml"
	assert_success
	run jq -c .counts "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"passed":5,"failed":2,"skipped":3,"total":10}'
}

@test "conformance: junit root time attribute becomes duration_ms" {
	printf '<?xml version="1.0"?>\n<testsuites tests="1" failures="0" time="1.2345">\n<testsuite name="s" tests="1" failures="0"><testcase name="t"/></testsuite>\n</testsuites>\n' \
		>"${BATS_TEST_TMPDIR}/junit.xml"
	run _convert junit_results_v1 "${BATS_TEST_TMPDIR}/junit.xml"
	assert_success
	run jq -c '[.duration_ms, .status]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '[1235,"passed"]'
}

@test "conformance: junit file without a testsuite element is status error" {
	printf 'nope\n' >"${BATS_TEST_TMPDIR}/junit.xml"
	run _convert junit_results_v1 "${BATS_TEST_TMPDIR}/junit.xml"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
}

@test "conformance: TAP skipped directives count as skipped, several files sum" {
	printf 'ok 1 a\nok 2 b # skip because\nnot ok 3 c\n# comment\n' >"${BATS_TEST_TMPDIR}/a.tap"
	printf 'ok 1 d\nok 2 e # SKIP\n' >"${BATS_TEST_TMPDIR}/b.tap"
	run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/a.tap" "${BATS_TEST_TMPDIR}/b.tap"
	assert_success
	run jq -c '{tool, status, counts}' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"tool":"bats","status":"failed","counts":{"passed":2,"failed":1,"skipped":2,"total":5}}'
}

@test "conformance: TAP with no readable file is status error" {
	run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/absent.tap"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
}

@test "conformance: every osv-scanner fixture validates; findings land in failed and total" {
	local f
	for f in "$FIXTURES_DIR"/security/osv-results-*.json; do
		run _convert osv_results_v1 "$f"
		assert_success
		assert_output --partial '"tool": "osv-scanner"'
	done
	run _convert osv_results_v1 "$FIXTURES_DIR/security/osv-results-with-vuln.json"
	run jq -c '{status, counts}' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"status":"failed","counts":{"passed":0,"failed":1,"skipped":0,"total":1}}'
}

@test "conformance: a clean osv-scanner run is passed; a non-zero exit with no findings is error" {
	run _convert osv_results_v1 "$FIXTURES_DIR/security/osv-results-clean.json"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "passed"
	EXIT_CODE=1 run _convert osv_results_v1 "$FIXTURES_DIR/security/osv-results-clean.json"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
}

@test "results_v1_build: a count that is not a non-negative integer is status error, never sanitised to passed" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		export RESULTS_TOOL=t RESULTS_RUNNER=r EXIT_CODE=0
		TESTS_PASSED=1 TESTS_FAILED=-1 TESTS_TOTAL=1 results_v1_build | jq -r .status
		TESTS_PASSED=1.5 TESTS_TOTAL=1 results_v1_build | jq -r .status
		TESTS_PASSED=one TESTS_TOTAL=1 results_v1_build | jq -r .status
	'
	assert_success
	assert_line --index 0 "error"
	assert_line --index 1 "error"
	assert_line --index 2 "error"
}

@test "conformance: a pytest report with a negative count is status error" {
	printf '{"summary": {"passed": 1, "failed": -1, "total": 1}}' >"${BATS_TEST_TMPDIR}/bad.json"
	run _convert pytest_results_v1 "${BATS_TEST_TMPDIR}/bad.json"
	assert_success
	run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "error"
}

@test "results_v1_validate: schema preflight rejects an unsupported keyword under an absent optional property" {
	jq '.properties.coverage.oneOf = [{"type": "object"}]' "$SCHEMA" >"${BATS_TEST_TMPDIR}/schema.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json" "$1"' _ "${BATS_TEST_TMPDIR}/schema.json"
	assert_failure 2
	assert_output --partial "unsupported schema keyword(s): oneOf"
}

@test "results_v1_validate: schema preflight rejects a \$ref carrying sibling constraints" {
	jq '.properties.artifacts.items.minLength = 1' "$SCHEMA" >"${BATS_TEST_TMPDIR}/schema.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json" "$1"' _ "${BATS_TEST_TMPDIR}/schema.json"
	assert_failure 2
	assert_output --partial "sibling keyword(s) is not supported: minLength"
}

@test "results_v1_validate: the shipped schema passes its own preflight" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_schema_preflight "$SCHEMA"'
	assert_success
	assert_output ""
}

@test "conformance: a one-line JUnit report keeps its root on the prolog line and still parses under set -euo pipefail" {
	printf '<?xml version="1.0"?><testsuites tests="2" failures="0" time="0.5"><testsuite name="s" tests="2" failures="0"><testcase name="a"/><testcase name="b"/></testsuite></testsuites>\n' \
		>"${BATS_TEST_TMPDIR}/one-line.xml"
	run bash -euo pipefail -c 'source "$LIB_DIR/testing.sh"; junit_results_v1 "$1" | jq -c "[.status, .counts.total, .duration_ms]"' _ "${BATS_TEST_TMPDIR}/one-line.xml"
	assert_success
	assert_output '["passed",2,500]'
	# A report without a time attribute leaves duration at 0 instead of
	# killing the strict shell.
	run bash -euo pipefail -c 'source "$LIB_DIR/testing.sh"; junit_results_v1 "$1" | jq -r .duration_ms' _ "$FIXTURES_DIR/rust/junit-two-tests.xml"
	assert_success
	assert_output "0"
}

@test "results_v1_validate: a file holding two concatenated documents is a hard error" {
	cat "$FIXTURES_DIR/results/valid-minimal.json" "$FIXTURES_DIR/results/valid-minimal.json" >"${BATS_TEST_TMPDIR}/two.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$1"' _ "${BATS_TEST_TMPDIR}/two.json"
	assert_failure 2
	assert_output --partial "expected exactly one JSON document"
}

@test "results_v1_validate: schema preflight rejects a non-boolean additionalProperties and a non-local \$ref" {
	jq '.properties.coverage.additionalProperties = {"type": "number"}' "$SCHEMA" >"${BATS_TEST_TMPDIR}/schema.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json" "$1"' _ "${BATS_TEST_TMPDIR}/schema.json"
	assert_failure 2
	assert_output --partial "additionalProperties must be a boolean"
	jq '.properties.artifacts.items = {"$ref": "https://example.invalid/artifact.json"}' "$SCHEMA" >"${BATS_TEST_TMPDIR}/schema2.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json" "$1"' _ "${BATS_TEST_TMPDIR}/schema2.json"
	assert_failure 2
	assert_output --partial "only local #/\$defs/<name> references are supported"
}

@test "conformance: a JUnit report past the pipe buffer (> 64 KiB) parses under set -euo pipefail" {
	{
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="nextest-run" tests="2000" failures="0" errors="0" time="12.5">\n<testsuite name="big" tests="2000" failures="0" errors="0" skipped="0">\n'
		for i in $(seq 1 2000); do
			printf '<testcase name="module::path::test_case_number_%d" classname="crate::module" time="0.001"/>\n' "$i"
		done
		printf '</testsuite>\n</testsuites>\n'
	} >"${BATS_TEST_TMPDIR}/big.xml"
	[[ "$(wc -c <"${BATS_TEST_TMPDIR}/big.xml")" -gt 65536 ]]
	run bash -euo pipefail -c 'source "$LIB_DIR/testing.sh"; junit_results_v1 "$1" | jq -c "[.status, .counts.total, .duration_ms]"' _ "${BATS_TEST_TMPDIR}/big.xml"
	assert_success
	assert_output '["passed",2000,12500]'
}
