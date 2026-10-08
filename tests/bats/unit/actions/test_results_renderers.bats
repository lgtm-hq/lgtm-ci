#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for the results.v1 renderers and amenders (#1080):
#   scripts/ci/actions/render-test-summary.sh   (results.v1 -> PR comment)
#   scripts/ci/actions/render-step-summary.sh   (results.v1 -> step summary)
#   scripts/ci/actions/render-pages-results.sh  (results.v1 -> Pages page)
#   scripts/ci/actions/results-update.sh        (amend status / coverage)
#   scripts/ci/actions/write-coverage-results.sh (reusable-coverage leg)

load "../../../helpers/common"

ACTIONS="${PROJECT_ROOT}/scripts/ci/actions"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/step_summary"
	: >"$GITHUB_OUTPUT"
	: >"$GITHUB_STEP_SUMMARY"
	cd "$BATS_TEST_TMPDIR" || exit 1
	# Deterministic comment metadata (no run URL, no commit line lookups).
	unset GITHUB_RUN_ID GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_SHA GITHUB_ACTIONS
}

teardown() {
	teardown_temp_dir
}

# Write one results.v1 leg under <dir>/<artifact>/results.json.
_leg() {
	local dir="$1" passed="$2" failed="$3" skipped="$4" coverage="$5" status="$6"
	local total=$((passed + failed + skipped)) cov=""
	[[ "$coverage" != "-" ]] && cov="\"coverage\": {\"lines\": ${coverage}},"
	mkdir -p "$dir"
	cat >"${dir}/results.json" <<EOF
{"tool": "pytest", "status": "${status}",
 "counts": {"passed": ${passed}, "failed": ${failed}, "skipped": ${skipped}, "total": ${total}},
 "duration_ms": 10, ${cov} "artifacts": [], "source": {"runner": "run-pytest", "version": "abc"}}
EOF
}

# =============================================================================
# render-test-summary.sh
# =============================================================================

@test "render-test-summary: one results.v1 document renders the same comment as the legacy env inputs" {
	_leg legs/a 10 2 0 85.5 failed

	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME="Python Tests" COVERAGE_ENABLED=true \
		COVERAGE_THRESHOLD=80 JOB_RESULT=failure COMMENT_OUTPUT=from-results.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success

	run env TESTS_PASSED=10 TESTS_FAILED=2 TESTS_TOTAL=12 TESTS_SKIPPED=0 COVERAGE_PERCENT=85.5 \
		TEST_SUITE_NAME="Python Tests" COVERAGE_ENABLED=true COVERAGE_THRESHOLD=80 JOB_RESULT=failure \
		COMMENT_OUTPUT=from-env.md bash "$ACTIONS/generate-test-summary.sh"
	assert_success

	run cmp from-results.md from-env.md
	assert_success
	run grep -c 'Total Tests\*\* | 12' from-results.md
	assert_output "1"
}

@test "render-test-summary: RESULTS_DIR folds several legs before rendering" {
	_leg legs/python-results-3.12 5 0 0 80.0 passed
	_leg legs/python-results-3.13 7 0 1 90.0 passed

	run env RESULTS_DIR=legs EXPECTED_COUNT=2 TEST_SUITE_NAME="Compat" COVERAGE_ENABLED=true \
		JOB_RESULT=success COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Total Tests** | 13 |'
	assert_file_contains_literal out.md '| **Passed** | 12 ✅ |'
	assert_file_contains_literal out.md '| **Skipped** | 1 |'
	assert_file_contains_literal out.md '85.00%'
	assert_file_contains_literal out.md 'Status: ✅ PASSED'
}

@test "render-test-summary: wrong leg count fails closed instead of posting partial totals" {
	_leg legs/python-results-3.12 5 0 0 - passed

	run env RESULTS_DIR=legs EXPECTED_COUNT=2 TEST_SUITE_NAME=x JOB_RESULT=success \
		COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_failure
	assert_output --partial "expected 2 results.json legs"
	assert_file_not_exists out.md
}

@test "render-test-summary: a document that violates the schema fails the render" {
	mkdir -p legs/a
	echo '{"tool": "pytest", "status": "green"}' >legs/a/results.json

	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success \
		COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_failure
	assert_output --partial '$.status: must be one of'
}

@test "render-test-summary: missing RESULTS_DIR is an error" {
	run env RESULTS_DIR=absent TEST_SUITE_NAME=x JOB_RESULT=success bash "$ACTIONS/render-test-summary.sh"
	assert_failure
	assert_output --partial "RESULTS_DIR does not exist"
}

@test "render-test-summary: with neither RESULTS_FILE nor RESULTS_DIR the legacy env path renders" {
	run env TESTS_PASSED=3 TESTS_FAILED=0 TESTS_TOTAL=3 TEST_SUITE_NAME="Legacy" JOB_RESULT=success \
		COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Total Tests** | 3 |'
}

# =============================================================================
# render-step-summary.sh
# =============================================================================

@test "render-step-summary: renders the per-runner table from the document" {
	_leg legs/a 3 1 1 90.5 failed

	run env RESULTS_FILE=legs/a/results.json TITLE="pytest Results" bash "$ACTIONS/render-step-summary.sh"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line --index 0 "## pytest Results"
	assert_line "**Status:** :x: Failed"
	assert_line "| Passed | 3 |"
	assert_line "| Failed | 1 |"
	assert_line "| Skipped | 1 |"
	assert_line "| Total | 5 |"
	assert_line "| Coverage | 90.5% |"
}

@test "render-step-summary: exit_code decides the status line and extra rows go first" {
	_leg legs/a 3 0 0 - passed
	jq '.exit_code = 0' legs/a/results.json >legs/a/r.json

	export EXTRA_ROWS=$'Browsers|chromium\nProject|smoke'
	run env RESULTS_FILE=legs/a/r.json TITLE="Playwright E2E Results" bash "$ACTIONS/render-step-summary.sh"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "**Status:** :white_check_mark: Passed"
	assert_line --index 4 "| Browsers | chromium |"
	assert_line --index 5 "| Project | smoke |"
	assert_line --index 6 "| Passed | 3 |"
	refute_output --partial "Coverage"
}

@test "render-step-summary: no tests prints the empty notice" {
	_leg legs/a 0 0 0 - no-tests
	run env RESULTS_FILE=legs/a/results.json TITLE="vitest Results" bash "$ACTIONS/render-step-summary.sh"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "> No tests were found."
	assert_line "**Status:** :white_check_mark: Passed"
}

@test "render-step-summary: rejects a document that violates the schema" {
	mkdir -p legs/a
	echo '{"tool": "x"}' >legs/a/results.json
	run env RESULTS_FILE=legs/a/results.json TITLE=t bash "$ACTIONS/render-step-summary.sh"
	assert_failure
	assert_output --partial "missing required property"
}

# =============================================================================
# render-pages-results.sh
# =============================================================================

@test "render-pages-results: writes results.json and an index.html for one document" {
	_leg legs/a 4 0 0 77.7 passed
	run env RESULTS_FILE=legs/a/results.json OUTPUT_DIR=site/results TITLE="Unit <Tests>" \
		bash "$ACTIONS/render-pages-results.sh"
	assert_success
	run cmp legs/a/results.json site/results/results.json
	assert_success
	assert_file_contains site/results/index.html '<h1>Unit &lt;Tests&gt;</h1>'
	assert_file_contains site/results/index.html '<tr><td>Passed</td><td>4</td></tr>'
	assert_file_contains site/results/index.html '<tr><td>Line coverage</td><td>77.7</td></tr>'
	assert_file_contains site/results/index.html 'href="results.json"'
}

@test "render-pages-results: aggregates a RESULTS_DIR into one document" {
	_leg legs/a 4 0 0 - passed
	_leg legs/b 1 1 0 - failed
	run env RESULTS_DIR=legs OUTPUT_DIR=site bash "$ACTIONS/render-pages-results.sh"
	assert_success
	run jq -c '[.status, .counts.total, .source.runner]' site/results.json
	assert_output '["failed",6,"aggregate-results"]'
	assert_file_contains site/index.html 'Status: <strong>failed</strong>'
}

# =============================================================================
# results-update.sh
# =============================================================================

@test "results-update: sets status and coverage, republishes outputs, keeps the document valid" {
	_leg legs/a 3 0 0 - passed
	run env RESULTS_FILE=legs/a/results.json STATUS=failed COVERAGE_LINES=84.21 COVERAGE_BRANCHES=n/a \
		bash "$ACTIONS/results-update.sh"
	assert_success
	run jq -c '[.status, .coverage]' legs/a/results.json
	assert_output '["failed",{"lines":84.21}]'
	assert_file_contains "$GITHUB_OUTPUT" "status=failed"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=84.21"
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=3"
}

@test "results-update: a non-numeric coverage (N/A) leaves the document without coverage" {
	_leg legs/a 3 0 0 - passed
	run env RESULTS_FILE=legs/a/results.json COVERAGE_LINES=N/A bash "$ACTIONS/results-update.sh"
	assert_success
	run jq -c 'has("coverage")' legs/a/results.json
	assert_output "false"
	run grep -c coverage-percent "$GITHUB_OUTPUT"
	assert_output "0"
}

@test "results-update: rejects an invalid status and a missing document" {
	_leg legs/a 3 0 0 - passed
	run env RESULTS_FILE=legs/a/results.json STATUS=green bash "$ACTIONS/results-update.sh"
	assert_failure
	assert_output --partial '$.status: must be one of'
	run env RESULTS_FILE=legs/none.json STATUS=failed bash "$ACTIONS/results-update.sh"
	assert_failure
	assert_output --partial "document not found"
}

# =============================================================================
# write-coverage-results.sh
# =============================================================================

@test "write-coverage-results: merged percentages and the threshold verdict become a valid document" {
	run env COVERAGE_PERCENT=91.25 COVERAGE_BRANCHES=80 COVERAGE_FUNCTIONS=n/a THRESHOLD_PASSED=true \
		MERGED_COVERAGE_FILE=coverage/merged.json RESULTS_SOURCE_VERSION=abc \
		bash "$ACTIONS/write-coverage-results.sh"
	assert_success
	run jq -c '{tool, status, counts, coverage, artifacts, source}' results/coverage/default/results.json
	assert_output '{"tool":"coverage","status":"passed","counts":{"passed":0,"failed":0,"skipped":0,"total":0},"coverage":{"lines":91.25,"branches":80},"artifacts":[{"kind":"coverage","path":"coverage/merged.json"}],"source":{"runner":"collect-coverage","version":"abc"}}'
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=91.25"
	assert_file_contains "$GITHUB_OUTPUT" "results-json=results/coverage/default/results.json"
}

@test "write-coverage-results: a failed threshold is status failed" {
	run env COVERAGE_PERCENT=12 THRESHOLD_PASSED=false bash "$ACTIONS/write-coverage-results.sh"
	assert_success
	run jq -r .status results/coverage/default/results.json
	assert_output "failed"
}
