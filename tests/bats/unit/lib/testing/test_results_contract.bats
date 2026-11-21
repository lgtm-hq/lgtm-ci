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
	# Drop the CI step variables a sharded coverage job exports (#1531).
	scrub_ci_step_env
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
	refute_output --partial "add schemas/ to sparse-checkout-extra"
}

@test "results_v1_validate: a missing default schema names the sparse-checkout fix" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; unset RESULTS_V1_SCHEMA; RESULTS_V1_SCHEMA_DEFAULT=/nonexistent/schema.json results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json"'
	assert_failure 2
	assert_output --partial "schema not found"
	assert_output --partial "add schemas/ to sparse-checkout-extra of the calling job"
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
	assert_output '{"status":"failed","counts":{"passed":10,"failed":2,"skipped":1,"total":13,"xfailed":0,"xpassed":0},"duration_ms":5250,"tool":"pytest","runner":"run-pytest"}'
}

@test "conformance: pytest errors land in counts.failed; xfailed and xpassed have their own counts (#1684, #1685)" {
	run _convert pytest_results_v1 "$FIXTURES_DIR/pytest/all-outcomes.json"
	assert_success
	# A summary-only report has no per-test entries: no expected_failures.
	run jq -c '{status, counts, xf: has("expected_failures")}' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"status":"failed","counts":{"passed":2,"failed":5,"skipped":1,"total":10,"xfailed":1,"xpassed":1},"xf":false}'
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

@test "conformance: vitest coverage is recorded only from a summary readable as a whole (#1692)" {
	printf '{"total":{"lines":{"pct":90},"branches":{"pct":80},"functions":{"pct":100},"statements":{"pct":90}}}' \
		>"${BATS_TEST_TMPDIR}/cov.json"
	run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/all-passing.json" "${BATS_TEST_TMPDIR}/cov.json"
	assert_success
	run jq -c '[.status, .coverage]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["passed",{"lines":90,"branches":80,"functions":100}]'
	# "Unknown" (istanbul's blank summary) beside real numbers, or a metric
	# that is absent, is what the comment calls UNREADABLE (as on main): the
	# document records no coverage and is status error, so no gate passes.
	local summary
	for summary in '"branches":{"pct":"Unknown"},"functions":{"pct":100},"statements":{"pct":90}' \
		'"branches":{"pct":80},"functions":{"pct":100}' \
		'"branches":{"pct":250},"functions":{"pct":100},"statements":{"pct":90}' \
		'"branches":{"pct":"oops"},"functions":{"pct":100},"statements":{"pct":90}'; do
		printf '{"total":{"lines":{"pct":90},%s}}' "$summary" >"${BATS_TEST_TMPDIR}/cov.json"
		run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/all-passing.json" "${BATS_TEST_TMPDIR}/cov.json"
		run jq -c '[.status, .coverage]' "${BATS_TEST_TMPDIR}/doc.json"
		assert_output '["error",null]'
	done
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

@test "conformance: a TAP plan shortfall is informational only (#1531)" {
	{
		echo "1..10"
		printf 'ok %s t\n' 1 2 3 4
	} >"${BATS_TEST_TMPDIR}/cut.tap"
	run bash -c 'source "$LIB_DIR/testing.sh"; parse_tap_file "$1"
		echo "$TAP_PLAN $TESTS_TOTAL"' _ "${BATS_TEST_TMPDIR}/cut.tap"
	assert_success
	assert_output "10 4"
	EXIT_CODE=0 run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/cut.tap"
	assert_success
	run jq -c '{status, counts, tap_plan, incomplete}' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"status":"passed","counts":{"passed":4,"failed":0,"skipped":0,"total":4},"tap_plan":{"planned":10,"reported":4},"incomplete":null}'
}

@test "conformance: totals count every ok/not ok line as on main; tap_plan records the mismatch (#1531, #1539)" {
	# Leaked nested TAP (kcov xtrace) inflates the totals exactly as on main;
	# 4 result lines against the one plan (2) are recorded as approximate.
	printf '1..2\nok 1 a\nok 1 mocked == x ]]\n1..1\nnot ok 2 b\n' >"${BATS_TEST_TMPDIR}/leaky.tap"
	printf 'ok 1 a\n' >"${BATS_TEST_TMPDIR}/noplan.tap"
	run bash -c 'source "$LIB_DIR/testing.sh"
		for f in "$@"; do parse_tap_file "$f"; echo "${TAP_PLAN:--} $TESTS_PASSED $TESTS_FAILED $TESTS_TOTAL"; done' _ \
		"${BATS_TEST_TMPDIR}/leaky.tap" "${BATS_TEST_TMPDIR}/noplan.tap"
	assert_success
	assert_output $'2 2 1 3\n- 1 0 1'
	run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/leaky.tap" "${BATS_TEST_TMPDIR}/noplan.tap"
	assert_success
	run jq -c '[.status, .tap_plan, has("incomplete")]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["failed",{"planned":2,"reported":4},false]'
}

@test "conformance: no tap_plan when the results match the plan or no file has a plan (#1539)" {
	printf '1..2\nok 1 a\nnot ok 2 b\n' >"${BATS_TEST_TMPDIR}/exact.tap"
	run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/exact.tap"
	assert_success
	run jq -c '[.status, .counts.total, has("tap_plan")]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["failed",2,false]'

	printf 'ok 1 a\n' >"${BATS_TEST_TMPDIR}/noplan.tap"
	run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/noplan.tap"
	assert_success
	run jq -c '[.counts.total, has("tap_plan")]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '[1,false]'
}

@test "conformance: a killed exit code (143) is failed, not incomplete, as on main (#1531)" {
	printf '1..1\nok 1 a\n' >"${BATS_TEST_TMPDIR}/a.tap"
	EXIT_CODE=143 run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/a.tap"
	assert_success
	run jq -c '[.status, has("incomplete")]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["failed",false]'
}

@test "conformance: a RESULTS_INCOMPLETE reason marks complete TAP incomplete (#1531)" {
	printf '1..1\nok 1 a\n' >"${BATS_TEST_TMPDIR}/a.tap"
	RESULTS_INCOMPLETE="incomplete coverage: shard(s) 3 did not finish" \
		run _convert tap_results_v1 "${BATS_TEST_TMPDIR}/a.tap"
	assert_success
	run jq -c '[.status, .incomplete]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["error","incomplete coverage: shard(s) 3 did not finish"]'
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

@test "conformance: osv-scanner counts the listed issues when issues_count is smaller, and an unreadable count is error" {
	local file="${BATS_TEST_TMPDIR}/osv.json" body
	# A zero or missing count beside listed issues is failed, never passed.
	for body in '"issues_count": 0, "issues": [{"m": 1}, {"m": 2}]' '"issues": [{"m": 1}, {"m": 2}]' \
		'"issues_count": "x", "issues": [{"m": 1}, {"m": 2}]'; do
		printf '{"results": [{"tool": "osv_scanner", %s}]}\n' "$body" >"$file"
		run _convert osv_results_v1 "$file"
		assert_success
		run jq -r '"\(.status) \(.counts.failed) \(.counts.total)"' "${BATS_TEST_TMPDIR}/doc.json"
		assert_output "failed 2 2"
	done
	# The count wins when it is the larger; a whole-number float is a count.
	printf '%s\n' '{"results": [{"tool": "osv_scanner", "issues_count": 3.0, "issues": []}]}' >"$file"
	run _convert osv_results_v1 "$file"
	assert_success
	run jq -r '"\(.status) \(.counts.failed)"' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "failed 3"
	# Missing, negative, fractional or text count with nothing listed: error.
	for body in '"success": true' '"issues_count": -1' '"issues_count": 1.5' '"issues_count": "2"' \
		'"issues_count": null, "issues": []'; do
		printf '{"results": [{"tool": "osv_scanner", %s}]}\n' "$body" >"$file"
		run _convert osv_results_v1 "$file"
		assert_success
		run jq -r .status "${BATS_TEST_TMPDIR}/doc.json"
		assert_output "error"
	done
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

# env -u BASH_ENV: kcov instruments nested bash through BASH_ENV and its
# injected script trips `set -u` before the test body runs (#856).
@test "conformance: a one-line JUnit report keeps its root on the prolog line and still parses under set -euo pipefail" {
	printf '<?xml version="1.0"?><testsuites tests="2" failures="0" time="0.5"><testsuite name="s" tests="2" failures="0"><testcase name="a"/><testcase name="b"/></testsuite></testsuites>\n' \
		>"${BATS_TEST_TMPDIR}/one-line.xml"
	run env -u BASH_ENV bash -euo pipefail -c 'source "$LIB_DIR/testing.sh"; junit_results_v1 "$1" | jq -c "[.status, .counts.total, .duration_ms]"' _ "${BATS_TEST_TMPDIR}/one-line.xml"
	assert_success
	assert_output '["passed",2,500]'
	# A report without a time attribute leaves duration at 0 instead of
	# killing the strict shell.
	run env -u BASH_ENV bash -euo pipefail -c 'source "$LIB_DIR/testing.sh"; junit_results_v1 "$1" | jq -r .duration_ms' _ "$FIXTURES_DIR/rust/junit-two-tests.xml"
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
	# stderr is captured too: a SIGPIPE'd writer used to leak
	# "grep: write error: Broken pipe" here while the document stayed right.
	run env -u BASH_ENV bash -euo pipefail -c 'trap "" PIPE; source "$LIB_DIR/testing.sh"; junit_results_v1 "$1" 2>&1 | jq -c "[.status, .counts.total, .duration_ms]"' _ "${BATS_TEST_TMPDIR}/big.xml"
	assert_success
	assert_output '["passed",2000,12500]'
}

# =============================================================================
# Expected failures and unexpected passes (#1685)
# =============================================================================

@test "results.v1 schema: counts.xfailed, counts.xpassed and expected_failures are optional (#1685)" {
	run jq -c '[.properties.counts.required, (.properties.counts.properties | has("xfailed"), has("xpassed")), .properties.expected_failures.properties.tests.maxItems, (.["$defs"].expected_failure.properties | .id.maxLength, .reason.maxLength)]' "$SCHEMA"
	assert_success
	assert_output '[["passed","failed","skipped","total"],true,true,50,500,500]'
	# Documents written before #1685 still validate.
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$FIXTURES_DIR/results/valid-minimal.json"'
	assert_success
}

@test "results_v1_validate: accepts a document with the new counts and an expected_failures list (#1685)" {
	jq '.counts += {"xfailed": 13, "xpassed": 0} | .expected_failures = {"tests": [{"id": "t.py::a", "reason": ""}], "omitted": 2}' \
		"$FIXTURES_DIR/results/valid-minimal.json" >"${BATS_TEST_TMPDIR}/doc.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$1"' _ "${BATS_TEST_TMPDIR}/doc.json"
	assert_success
	assert_output ""
}

@test "results_v1_validate: rejects a negative or non-integer new count and an unbounded list (#1685)" {
	jq '.counts += {"xfailed": -1, "xpassed": 1.5}
		| .expected_failures = {"tests": ([range(51) | {"id": "t", "reason": ""}] + [{"id": "", "reason": ("r" * 501)}]), "omitted": "3"}' \
		"$FIXTURES_DIR/results/valid-minimal.json" >"${BATS_TEST_TMPDIR}/doc.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$1"' _ "${BATS_TEST_TMPDIR}/doc.json"
	assert_failure 1
	assert_output --partial '$.counts.xfailed: must be >= 0'
	assert_output --partial '$.counts.xpassed: expected integer, got number'
	assert_output --partial '$.expected_failures.tests: must have at most 50 item(s)'
	assert_output --partial '$.expected_failures.tests[51].id: must be at least 1 character(s)'
	assert_output --partial '$.expected_failures.tests[51].reason: must be at most 500 character(s)'
	assert_output --partial '$.expected_failures.omitted: expected integer, got string'
	# A string count is a type error as well.
	jq '.counts.xfailed = "13"' "$FIXTURES_DIR/results/valid-minimal.json" >"${BATS_TEST_TMPDIR}/doc2.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate "$1"' _ "${BATS_TEST_TMPDIR}/doc2.json"
	assert_failure 1
	assert_output --partial '$.counts.xfailed: expected integer, got string'
}

@test "results_v1_build: new counts only when given; a malformed one makes the status error (#1685)" {
	run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=3 TESTS_TOTAL=3 results_v1_build | jq -c .counts'
	assert_output '{"passed":3,"failed":0,"skipped":0,"total":3}'
	run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=3 TESTS_TOTAL=5 TESTS_XFAILED=2 TESTS_XPASSED=0 results_v1_build | jq -c "[.status, .counts]"'
	assert_output '["passed",{"passed":3,"failed":0,"skipped":0,"total":5,"xfailed":2,"xpassed":0}]'
	# A malformed count never reads as a pass, even with failed at 0.
	for bad in -1 1.5 abc; do
		run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=3 TESTS_TOTAL=3 TESTS_XPASSED="$1" results_v1_build | jq -c "[.status, (.counts | has(\"xpassed\"))]"' _ "$bad"
		assert_output '["error",false]'
	done
}

@test "results_v1_build: bounds the expected failures list (#1685)" {
	jq -n '[{"id": "t::long", "reason": ("x" * 600)}, {"id": "", "reason": "dropped"}, {"reason": "no id"},
		{"id": "t::no-reason"}, {"id": "t::number", "reason": 5}, {"id": ("i" * 501), "reason": "r"}]
		+ [range(60) | {"id": "t::\(.)", "reason": "r"}]' >"${BATS_TEST_TMPDIR}/xf.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y RESULTS_EXPECTED_FAILURES_FILE="$1" results_v1_build >"$2" && results_v1_validate "$2"' _ "${BATS_TEST_TMPDIR}/xf.json" "${BATS_TEST_TMPDIR}/doc.json"
	assert_success
	# 64 usable entries (two have no id): 50 listed, 14 omitted.
	run jq -c '.expected_failures | [(.tests | length), .omitted, (.tests[0].reason | length), (.tests[0].reason | endswith("…")), .tests[1], .tests[2], (.tests[3].id | length)]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '[50,14,500,true,{"id":"t::no-reason","reason":""},{"id":"t::number","reason":""},500]'
	# A missing file, a file that is not an array and an empty list add nothing.
	printf '{"tests": []}' >"${BATS_TEST_TMPDIR}/obj.json"
	printf '[]' >"${BATS_TEST_TMPDIR}/empty.json"
	for f in "${BATS_TEST_TMPDIR}/absent.json" "${BATS_TEST_TMPDIR}/obj.json" "${BATS_TEST_TMPDIR}/empty.json"; do
		run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y RESULTS_EXPECTED_FAILURES_FILE="$1" results_v1_build | jq -c "has(\"expected_failures\")"' _ "$f"
		assert_output "false"
	done
}

@test "conformance: pytest xfailed, xpassed, strict xpass and reasons (#1685)" {
	run _convert pytest_results_v1 "$FIXTURES_DIR/pytest/xfail-outcomes.json"
	assert_success
	# The strict xpass stays failed; the non-strict one is an unexpected pass.
	run jq -c '[.status, .counts]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["failed",{"passed":1,"failed":1,"skipped":0,"total":8,"xfailed":5,"xpassed":1}]'
	run jq -c '.expected_failures | [.omitted, [.tests[].id]]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '[0,["tests/test_x.py::test_marked_raises","tests/test_x.py::test_imperative_hostile","tests/test_x.py::test_not_run","tests/test_x.py::test_long_reason","tests/test_x.py::test_wasxfail"]]'
	# Reasons: the crash message (XFailed prefix removed), a stage wasxfail
	# first. The document keeps the hostile text raw; renderers sanitise it.
	run jq -r '.expected_failures.tests[] | select(.id | test("long") | not) | .reason' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "$(printf '%s\n' 'assert 1 == 2' '@org/team #1 <img src=x> [x](javascript:y) <!-- lgtm-ci:history:start -->' '[NOTRUN] not run' 'reason from wasxfail')"
	# The 10 000-character reason is cut to 500 with an ellipsis.
	run jq -c '.expected_failures.tests[3].reason | [length, endswith("…")]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '[500,true]'
}

@test "conformance: pytest expected failures beyond the cap are counted, not listed (#1685)" {
	run _convert pytest_results_v1 "$FIXTURES_DIR/pytest/xfail-over-cap.json"
	assert_success
	run jq -c '[.status, .counts.xfailed, (.expected_failures | (.tests | length), .omitted, .tests[49].reason)]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["passed",60,50,10,"known bug 49"]'
}

@test "conformance: junit counts pytest.xfail elements as xfailed, out of skipped (#1685)" {
	run _convert junit_results_v1 "$FIXTURES_DIR/junit/pytest-xfail.xml"
	assert_success
	# The non-strict xpass is a plain passing testcase in JUnit: passed.
	run jq -c '[.status, .counts, has("expected_failures")]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["failed",{"passed":2,"failed":1,"skipped":0,"total":7,"xfailed":4},false]'
	# A report without them keeps a document without the field.
	run _convert junit_results_v1 "$FIXTURES_DIR/junit/single-suite-mixed.xml"
	assert_success
	run jq -c '.counts | has("xfailed")' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "false"
}

@test "conformance: playwright test.fail() tests that failed are xfailed; one that passed stays failed (#1685)" {
	run _convert playwright_results_v1 "$FIXTURES_DIR/playwright/reports/json-expected-failures.json"
	assert_success
	run jq -c '[.status, .counts]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["failed",{"passed":1,"failed":1,"skipped":1,"total":5,"xfailed":2}]'
	# Reports without test.fail() keep documents without the field.
	run _convert playwright_results_v1 "$FIXTURES_DIR/playwright/reports/json-mixed.json"
	assert_success
	run jq -c '.counts | has("xfailed")' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "false"
}

# =============================================================================
# Review fixes (#1702)
# =============================================================================

@test "results_v1_build: an optional count over nine digits is error, never wrapped to a small number (#1702)" {
	local field value
	for field in TESTS_XFAILED TESTS_XPASSED; do
		# 9 digits: kept.
		run bash -c 'source "$LIB_DIR/testing/results.sh"; env RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=1 TESTS_TOTAL=1 "$1=999999999" bash -c "source \"\$LIB_DIR/testing/results.sh\"; results_v1_build" | jq -c "[.status, .counts.xfailed, .counts.xpassed]"' _ "$field"
		if [[ "$field" == TESTS_XFAILED ]]; then
			assert_output '["passed",999999999,null]'
		else
			assert_output '["passed",null,999999999]'
		fi
		# 10 digits, 2^63 and 2^64: status error, the field left out, never 0
		# or negative.
		for value in 1000000000 9223372036854775808 18446744073709551616; do
			run bash -c 'env RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=1 TESTS_TOTAL=1 "$1=$2" bash -c "source \"\$LIB_DIR/testing/results.sh\"; results_v1_build" | jq -c "[.status, (.counts | has(\"xfailed\") or has(\"xpassed\"))]"' _ "$field" "$value"
			assert_output '["error",false]'
		done
	done
}

@test "results_v1_build: a required count over nine digits is error, not a wrapped pass or no-tests (#1702)" {
	local value
	for value in 1000000000 9223372036854775808 18446744073709551616; do
		# A failed count of 2^64 used to wrap to 0 in the status check: passed.
		run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=1 TESTS_TOTAL=1 TESTS_FAILED="$1" results_v1_build | jq -r .status' _ "$value"
		assert_output "error"
		# A total of 2^64 used to wrap to 0: no-tests.
		run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=1 TESTS_TOTAL="$1" results_v1_build | jq -r .status' _ "$value"
		assert_output "error"
	done
	# Nine digits with leading zeros still read as decimal.
	run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=1 TESTS_TOTAL=1 TESTS_FAILED=000000008 results_v1_build | jq -r .status'
	assert_output "failed"
}

@test "results_v1_build: a list near the size limit in multibyte text reaches jq as a file, not an argument (#1702)" {
	# 50 entries, each a 500-character id and reason of 4-byte characters:
	# about 200 KB of JSON, over Linux's 128 KiB limit for one argument.
	jq -n '[range(60) | {id: ("😀" * 500), reason: ("é😀" * 250)}]' >"${BATS_TEST_TMPDIR}/xf.json"
	run bash -c '[ "$(wc -c <"$1")" -gt 131072 ]' _ "${BATS_TEST_TMPDIR}/xf.json"
	assert_success
	run bash -c 'source "$LIB_DIR/testing/results.sh"; RESULTS_TOOL=x RESULTS_RUNNER=y TESTS_PASSED=1 TESTS_TOTAL=61 TESTS_XFAILED=60 RESULTS_EXPECTED_FAILURES_FILE="$1" results_v1_build >"$2" && results_v1_validate "$2"' \
		_ "${BATS_TEST_TMPDIR}/xf.json" "${BATS_TEST_TMPDIR}/doc.json"
	assert_success
	run jq -c '.expected_failures | [(.tests | length), .omitted, (.tests[0].id | length), (.tests[49].reason | length)]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '[50,10,500,500]'
	# The list is never put on a jq command line.
	run grep -nE -- '--argjson (xfail|xfail_doc|expected_failures) ' "$LIB_DIR/testing/results.sh"
	assert_failure
}

@test "results_v1_github_outputs: publishes tests-xfailed and tests-xpassed, 0 when absent (#1702)" {
	jq '.counts += {"xfailed": 3, "xpassed": 1}' "$FIXTURES_DIR/results/valid-minimal.json" >"${BATS_TEST_TMPDIR}/doc.json"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_github_outputs "$1"; grep -E "^tests-x" "$GITHUB_OUTPUT"' _ "${BATS_TEST_TMPDIR}/doc.json"
	assert_output "$(printf '%s\n' 'tests-xfailed=3' 'tests-xpassed=1')"
	: >"$GITHUB_OUTPUT"
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_github_outputs "$1"; grep -E "^tests-x" "$GITHUB_OUTPUT"' _ "$FIXTURES_DIR/results/valid-minimal.json"
	assert_output "$(printf '%s\n' 'tests-xfailed=0' 'tests-xpassed=0')"
}

@test "conformance: junit ignores pytest.xfail text inside CDATA and comments (#1702)" {
	cat >"${BATS_TEST_TMPDIR}/cdata.xml" <<'XML'
<testsuite tests="3" failures="0" errors="0" skipped="2">
  <testcase name="passing"><system-out><![CDATA[example XML: <skipped type="pytest.xfail" message="example"/>
second line]]></system-out></testcase>
  <!-- <skipped type="pytest.xfail" message="in a comment"/> -->
  <testcase name="ordinary_skip"><skipped type="pytest.skip" message="unavailable"/></testcase>
  <testcase name="real_xfail"><skipped
     type="pytest.xfail" message="real"/></testcase>
</testsuite>
XML
	run _convert junit_results_v1 "${BATS_TEST_TMPDIR}/cdata.xml"
	assert_success
	# One real expected failure; the ordinary skip stays skipped.
	run jq -c '.counts' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"passed":1,"failed":0,"skipped":1,"total":3,"xfailed":1}'

	# Only the quoted tag (no real one): no expected failures at all.
	sed -e '/real_xfail/,/testcase>/d' -e 's/skipped="2"/skipped="1"/; s/tests="3"/tests="2"/' \
		"${BATS_TEST_TMPDIR}/cdata.xml" >"${BATS_TEST_TMPDIR}/quoted.xml"
	run _convert junit_results_v1 "${BATS_TEST_TMPDIR}/quoted.xml"
	assert_success
	run jq -c '.counts' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '{"passed":1,"failed":0,"skipped":1,"total":2}'
}

@test "results_v1_build: a coverage value outside 0 to 100 records no coverage and is status error (#1692)" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		export RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1
		build() { local rc=0 doc; doc=$(results_v1_build 2>/dev/null) || rc=$?; echo "$(jq -c "[.status, .coverage]" <<<"$doc") rc=$rc"; }
		COVERAGE_LINES=500 build
		COVERAGE_LINES=90 COVERAGE_BRANCHES=100.5 build
		COVERAGE_LINES=90 COVERAGE_FUNCTIONS=-1 build
		COVERAGE_LINES=90 COVERAGE_BRANCHES=invalid build
		COVERAGE_LINES=invalid build
		COVERAGE_LINES=100 COVERAGE_BRANCHES=0 build
		COVERAGE_LINES=100 COVERAGE_BRANCHES=Unknown COVERAGE_FUNCTIONS=n/a build
	'
	assert_success
	assert_line --index 0 '["error",null] rc=1'
	assert_line --index 1 '["error",null] rc=1'
	assert_line --index 2 '["error",null] rc=1'
	assert_line --index 3 '["error",null] rc=1'
	assert_line --index 4 '["error",null] rc=1'
	assert_line --index 5 '["passed",{"lines":100,"branches":0}] rc=0'
	assert_line --index 6 '["passed",{"lines":100}] rc=0'
}

@test "results_v1_set_coverage: an unreadable value records no coverage and sets status error (#1692)" {
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1 COVERAGE_LINES= results_v1_build >"$1"
		results_v1_set_coverage "$1" invalid 2>/dev/null
		jq -c "[.status, .coverage]" "$1"
		RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1 COVERAGE_LINES= results_v1_build >"$1"
		results_v1_set_coverage "$1" 120 2>/dev/null
		jq -c "[.status, .coverage]" "$1"
		RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1 COVERAGE_LINES= results_v1_build >"$1"
		results_v1_set_coverage "$1" 87.5
		jq -c "[.status, .coverage]" "$1"
	' _ "$BATS_TEST_TMPDIR/doc.json"
	assert_success
	assert_line --index 0 '["error",null]'
	assert_line --index 1 '["error",null]'
	assert_line --index 2 '["passed",{"lines":87.5}]'
}

@test "pytest and vitest results.v1: a raw coverage percentage above 100 is status error (#1692)" {
	printf '%s' '{"meta":{"version":"7.6.1"},"totals":{"percent_covered":500,"percent_covered_branches":90}}' \
		>"$BATS_TEST_TMPDIR/coverage.json"
	printf '%s' '{"total":{"lines":{"pct":1000},"branches":{"pct":90},"functions":{"pct":80}}}' \
		>"$BATS_TEST_TMPDIR/coverage-summary.json"
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		source "$LIB_DIR/testing/parse/pytest.sh"
		pytest_coverage_metrics "$1"
		RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1 results_v1_build 2>/dev/null | jq -c "[.status, .coverage]"
		COVERAGE_LINES=$(jq -r ".total.lines.pct" "$2") COVERAGE_BRANCHES=90 \
			RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1 results_v1_build 2>/dev/null | jq -c "[.status, .coverage]"
	' _ "$BATS_TEST_TMPDIR/coverage.json" "$BATS_TEST_TMPDIR/coverage-summary.json"
	assert_success
	assert_line --index 0 '["error",null]'
	assert_line --index 1 '["error",null]'
}

@test "pytest results.v1: an unreadable branch total records no coverage, whatever the line percentage (#1692)" {
	local totals
	for totals in '"num_branches":5,"covered_branches":9' '"num_branches":null,"covered_branches":null' \
		'"percent_covered_branches":"oops"'; do
		printf '{"meta":{"version":"7.6.1"},"totals":{"percent_covered":90,%s}}' "$totals" \
			>"$BATS_TEST_TMPDIR/coverage.json"
		run bash -c '
			source "$LIB_DIR/testing/results.sh"
			source "$LIB_DIR/testing/parse/pytest.sh"
			pytest_coverage_metrics "$1"
			RESULTS_TOOL=t RESULTS_RUNNER=r TESTS_TOTAL=1 results_v1_build 2>/dev/null | jq -c "[.status, .coverage]"
		' _ "$BATS_TEST_TMPDIR/coverage.json"
		assert_output '["error",null]'
	done
}

@test "junit results.v1: an LCOV report with more functions hit than found records no coverage (#1692)" {
	printf 'SF:a.rs\nDA:1,1\nLF:1\nLH:1\nFNF:2\nFNH:9\nend_of_record\n' >"$BATS_TEST_TMPDIR/lcov.info"
	run bash -c '
		source "$LIB_DIR/testing/results.sh"
		source "$LIB_DIR/testing/parse/junit.sh"
		junit_results_v1 "$1" "$2" 2>/dev/null | jq -c "[.status, .coverage]"
	' _ "$FIXTURES_DIR/rust/junit-one-test.xml" "$BATS_TEST_TMPDIR/lcov.info"
	assert_output '["error",null]'
}

@test "conformance: vitest istanbul Unknown percentages are omitted, numbers kept" {
	# Restored (#1692 round 4): istanbul's blank metric ("Unknown" with a total
	# and covered of 0) is not measured, as on main; the numbers are kept.
	local blank='{"total":0,"covered":0,"skipped":0,"pct":"Unknown"}'
	printf '{"total":{"lines":{"pct":90},"branches":%s,"functions":{"pct":100},"statements":{"pct":90}}}' \
		"$blank" >"${BATS_TEST_TMPDIR}/cov.json"
	run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/all-passing.json" "${BATS_TEST_TMPDIR}/cov.json"
	assert_success
	run jq -c '[.status, .coverage]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["passed",{"lines":90,"functions":100}]'
}

@test "conformance: an empty istanbul coverage map records no coverage and stays passed, as on main (#1692)" {
	run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/all-passing.json" \
		"$FIXTURES_DIR/vitest/coverage-summary-empty-map.json"
	assert_success
	run jq -c '[.status, .coverage]' "${BATS_TEST_TMPDIR}/doc.json"
	assert_output '["passed",null]'
	# "Unknown" beside a total or covered count above 0 is not that blank metric.
	local metric
	for metric in '{"total":5,"covered":0,"pct":"Unknown"}' '{"total":0,"covered":2,"pct":"Unknown"}' \
		'{"total":0,"pct":"Unknown"}'; do
		printf '{"total":{"lines":{"pct":90},"branches":%s,"functions":{"pct":100},"statements":{"pct":90}}}' \
			"$metric" >"${BATS_TEST_TMPDIR}/cov.json"
		run _convert vitest_results_v1 "$FIXTURES_DIR/vitest/all-passing.json" "${BATS_TEST_TMPDIR}/cov.json"
		run jq -c '[.status, .coverage]' "${BATS_TEST_TMPDIR}/doc.json"
		assert_output '["error",null]'
	done
}
