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
	# Drop the CI step variables a sharded coverage job exports (#1531).
	scrub_ci_step_env
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

@test "render-step-summary: a failed or error document never renders Passed, even with exit_code 0" {
	_leg legs/a 3 0 0 - failed
	jq '.exit_code = 0' legs/a/results.json >legs/a/r.json
	run env RESULTS_FILE=legs/a/r.json TITLE=t bash "$ACTIONS/render-step-summary.sh"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "**Status:** :x: Failed"
	: >"$GITHUB_STEP_SUMMARY"
	_leg legs/b 0 0 0 - error
	run env RESULTS_FILE=legs/b/results.json TITLE=t bash "$ACTIONS/render-step-summary.sh"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "**Status:** :x: Failed"
}

@test "render-test-summary: without a job result the document status decides the verdict" {
	_leg legs/a 3 0 0 - failed
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md 'Status: ❌ FAILED'
	# An explicit job result still wins (coverage-threshold wording, etc.).
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out2.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out2.md 'Status: ✅ PASSED'
}

@test "render-test-summary: TESTS_TOTAL_EXCLUDES_SKIPPED renders the Rust total as passed + failed" {
	_leg legs/a 5 2 3 - failed
	run env RESULTS_FILE=legs/a/results.json TESTS_TOTAL_EXCLUDES_SKIPPED=true TEST_SUITE_NAME=x \
		JOB_RESULT=failure COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Total Tests** | 7 |'
	assert_file_contains_literal out.md '| **Pass Rate** | 71% |'
}

@test "render-test-summary: counts.skipped is left out of the pass rate, the total stays inclusive (#1684)" {
	_leg legs/a 229 0 13 - passed
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Total Tests** | 242 |'
	assert_file_contains_literal out.md '| **Skipped** | 13 |'
	assert_file_contains_literal out.md '| **Pass Rate** | 100% (of 229 run) |'
	run grep -c 'Other' out.md
	assert_output "0"
	run cat "$GITHUB_OUTPUT"
	assert_output "history-summary=229 passed, 0 failed, 13 skipped"

	_leg legs/b 5 2 3 - failed
	run env RESULTS_FILE=legs/b/results.json TEST_SUITE_NAME=x JOB_RESULT=failure COMMENT_OUTPUT=out2.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out2.md '| **Total Tests** | 10 |'
	assert_file_contains_literal out2.md '| **Pass Rate** | 71% (of 7 run) |'
}

@test "render-test-summary: TESTS_TOTAL_EXCLUDES_SKIPPED with counts.skipped shows Skipped and no Other row (#1684)" {
	_leg legs/a 229 0 13 - passed
	run env RESULTS_FILE=legs/a/results.json TESTS_TOTAL_EXCLUDES_SKIPPED=true TEST_SUITE_NAME=x \
		JOB_RESULT=success COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Total Tests** | 229 |'
	assert_file_contains_literal out.md '| **Skipped** | 13 |'
	assert_file_contains_literal out.md '| **Pass Rate** | 100% |'
	run grep -c 'Other' out.md
	assert_output "0"
}

@test "render-test-summary: a document whose total is larger than its parts shows the rest as Other (#1684)" {
	# pytest's expected failures and unexpected passes are in counts.total only.
	mkdir -p legs/a
	cat >legs/a/results.json <<'JSON'
{"tool": "pytest", "status": "passed",
 "counts": {"passed": 229, "failed": 0, "skipped": 13, "total": 255},
 "duration_ms": 10, "artifacts": [], "source": {"runner": "run-pytest", "version": "abc"}}
JSON
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Total Tests** | 255 |'
	assert_file_contains_literal out.md '| **Skipped** | 13 |'
	assert_file_contains_literal out.md '| **Other** | 13 |'
	assert_file_contains_literal out.md '| **Pass Rate** | 100% (of 229 run) |'
	run cat "$GITHUB_OUTPUT"
	assert_output "history-summary=229 passed, 0 failed, 13 skipped, 13 other"

	# The Rust flag replaces the total with passed + failed: no Other row.
	: >"$GITHUB_OUTPUT"
	run env RESULTS_FILE=legs/a/results.json TESTS_TOTAL_EXCLUDES_SKIPPED=true TEST_SUITE_NAME=x \
		JOB_RESULT=success COMMENT_OUTPUT=out2.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out2.md '| **Total Tests** | 229 |'
	assert_file_contains_literal out2.md '| **Pass Rate** | 100% |'
	run grep -c 'Other' out2.md
	assert_output "0"
}

@test "render-test-summary: a document with no skipped tests renders byte-identical to before (#1684)" {
	local golden="${PROJECT_ROOT}/tests/fixtures/test-summary-golden"
	mkdir -p bin
	printf '#!/bin/sh\necho 2026-01-01\n' >bin/date
	chmod +x bin/date
	_leg legs/a 10 2 0 85.5 failed
	: >"$GITHUB_OUTPUT"
	run env PATH="$PWD/bin:$PATH" RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME="Python Tests" \
		COVERAGE_ENABLED=true COVERAGE_THRESHOLD=80 JOB_RESULT=failure COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	run cmp "$golden/results-v1.txt" out.md
	assert_success
	run cmp "$golden/results-v1.output" "$GITHUB_OUTPUT"
	assert_success
}

# =============================================================================
# assert-required-check.sh with RESULTS_DIR (#1080)
# =============================================================================

@test "assert-required-check: RESULTS_DIR passes when every leg is passed or no-tests" {
	_leg legs/a 3 0 0 - passed
	_leg legs/b 0 0 0 - no-tests
	run env UPSTREAM_RESULT=success RESULTS_DIR=legs EXPECTED_COUNT=2 bash "$ACTIONS/assert-required-check.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "status=passed"
}

@test "assert-required-check: RESULTS_DIR fails on a failed leg, an error leg, an invalid document, a count mismatch" {
	_leg legs/a 3 0 0 - passed
	_leg legs/b 2 1 0 - failed
	run env UPSTREAM_RESULT=success RESULTS_DIR=legs bash "$ACTIONS/assert-required-check.sh"
	assert_failure
	assert_output --partial "reports status failed"

	rm -rf legs
	_leg legs/a 0 0 0 - error
	run env UPSTREAM_RESULT=success RESULTS_DIR=legs bash "$ACTIONS/assert-required-check.sh"
	assert_failure
	assert_output --partial "reports status error"

	rm -rf legs
	mkdir -p legs/a
	echo '{"tool": "x"}' >legs/a/results.json
	run env UPSTREAM_RESULT=success RESULTS_DIR=legs bash "$ACTIONS/assert-required-check.sh"
	assert_failure
	assert_output --partial "does not conform to results.v1"

	rm -rf legs
	_leg legs/a 3 0 0 - passed
	run env UPSTREAM_RESULT=success RESULTS_DIR=legs EXPECTED_COUNT=2 bash "$ACTIONS/assert-required-check.sh"
	assert_failure
	assert_output --partial "Expected 2 results.json legs"
	run env UPSTREAM_RESULT=success RESULTS_DIR=legs EXPECTED_COUNT=two bash "$ACTIONS/assert-required-check.sh"
	assert_failure
	assert_output --partial "EXPECTED_COUNT must be a non-negative integer"
	assert_file_contains "$GITHUB_OUTPUT" "status=failed"
}

@test "assert-required-check: an empty RESULTS_DIR or a missing directory fails closed" {
	mkdir -p legs
	run env UPSTREAM_RESULT=success RESULTS_DIR=legs bash "$ACTIONS/assert-required-check.sh"
	assert_failure
	assert_output --partial "No results.json found"
	run env UPSTREAM_RESULT=success RESULTS_DIR=absent bash "$ACTIONS/assert-required-check.sh"
	assert_failure
	assert_output --partial "results directory not found"
}

@test "render-test-summary: an errored document omits the counts table (#1371)" {
	_leg legs/a 0 0 0 - error
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md 'No test counts were parsed for this run (see the job log)'
	assert_file_contains_literal out.md 'Status: ❌ FAILED'
	run grep -c 'Total Tests' out.md
	assert_output "0"
}

@test "render-test-summary: a no-tests document on a green job renders NO TESTS (#1371)" {
	_leg legs/a 0 0 0 - no-tests
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md 'Status: ⚠️ NO TESTS'
}

@test "render-test-summary: an incomplete sharded run says so instead of totals or a percentage (#1531)" {
	local reason="incomplete coverage: shard(s) 3, 4 did not finish (cancelled or timed out; no completion manifest)"
	_leg legs/shell-results 3968 0 0 69 error
	jq --arg reason "$reason" '.incomplete = $reason' legs/shell-results/results.json >doc.json
	mv doc.json legs/shell-results/results.json

	run env RESULTS_DIR=legs EXPECTED_COUNT=1 TEST_SUITE_NAME="Shell Tests" COVERAGE_ENABLED=true \
		COVERAGE_THRESHOLD=60 JOB_RESULT=failure COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"

	assert_success
	assert_file_contains_literal out.md '**Build:** ⚠️ Test counts incomplete'
	assert_file_contains_literal out.md "**Coverage:** ⚠️ incomplete"
	assert_file_contains_literal out.md "No percentage published: ${reason}"
	assert_file_contains_literal out.md "No totals shown: ${reason} (see the job log)"
	assert_file_contains_literal out.md 'Status: ❌ FAILED'
	run grep -cE 'Total Tests|3968|69%' out.md
	assert_output "0"
	grep -qx 'history-summary=incomplete' "$GITHUB_OUTPUT"
}

# =============================================================================
# Expected failures and unexpected passes (#1685)
# =============================================================================

# The adopter's run as a results.v1 document: 13 expected failures with
# reasons (one hostile), written to legs/a/results.json.
_xfail_doc() {
	mkdir -p legs/a
	jq -n '{tool: "pytest", status: "passed",
		counts: {passed: 229, failed: 0, skipped: 13, total: 255, xfailed: 13, xpassed: 0},
		duration_ms: 10, artifacts: [], source: {runner: "run-pytest", version: "abc"},
		expected_failures: {
			tests: ([{id: "tests/test_api.py::test_hostile_reason",
				reason: "@org/team #1 <img src=x> [x](javascript:y) <!-- lgtm-ci:history:start -->"}]
				+ [range(12) | {id: "tests/test_api.py::test_known_bug_\(.)", reason: "known bug: upstream fix pending"}]),
			omitted: 0}}' >legs/a/results.json
}

@test "render-test-summary: the adopter's document renders its golden comment (#1685)" {
	local golden="${PROJECT_ROOT}/tests/fixtures/test-summary-golden"
	mkdir -p bin
	printf '#!/bin/sh\necho 2026-01-01\n' >bin/date
	chmod +x bin/date
	_xfail_doc
	: >"$GITHUB_OUTPUT"
	run env PATH="$PWD/bin:$PATH" RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME="Python Tests" \
		JOB_RESULT=success COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	run cmp "$golden/results-v1-xfail.txt" out.md
	assert_success
	run cmp "$golden/results-v1-xfail.output" "$GITHUB_OUTPUT"
	assert_success
}

@test "render-test-summary: unexpected passes from a document; a strict xpass stays failed (#1685)" {
	mkdir -p legs/a
	cat >legs/a/results.json <<'JSON'
{"tool": "pytest", "status": "failed",
 "counts": {"passed": 10, "failed": 1, "skipped": 0, "total": 14, "xfailed": 1, "xpassed": 2},
 "duration_ms": 10, "artifacts": [], "source": {"runner": "run-pytest", "version": "abc"}}
JSON
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md 'Status: ❌ FAILED'
	assert_file_contains_literal out.md '| **Unexpected passes** | 2 ⚠️ |'
	assert_file_contains_literal out.md '⚠️ 2 tests marked as expected failures passed: remove the marker from them.'
	run grep -c 'Other' out.md
	assert_output "0"
}

@test "render-test-summary: matrix legs where only some carry the new fields (#1685)" {
	_leg legs/a 229 0 13 - passed
	_xfail_doc
	mv legs/a/results.json legs/b.json
	_leg legs/a 229 0 13 - passed
	mkdir -p legs/b && mv legs/b.json legs/b/results.json
	run env RESULTS_DIR=legs TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Total Tests** | 497 |'
	assert_file_contains_literal out.md '| **Skipped** | 26 |'
	assert_file_contains_literal out.md '| **Expected failures** | 13 |'
	assert_file_contains_literal out.md '| **Pass Rate** | 100% (of 458 run) |'
	assert_file_contains_literal out.md '- `tests/test_api.py::test_known_bug_11`: known bug: upstream fix pending'
	run grep -c 'Other' out.md
	assert_output "0"
	run cat "$GITHUB_OUTPUT"
	assert_output "history-summary=458 passed, 0 failed, 26 skipped, 13 expected failures"
}

@test "render-test-summary: a document list cut at the cap shows the rest as a count (#1685)" {
	mkdir -p legs/a
	jq -n '{tool: "pytest", status: "passed",
		counts: {passed: 0, failed: 0, skipped: 0, total: 70, xfailed: 70},
		duration_ms: 10, artifacts: [], source: {runner: "run-pytest", version: "abc"},
		expected_failures: {tests: [range(50) | {id: "t::\(.)", reason: "r"}], omitted: 20}}' >legs/a/results.json
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '- and 20 more'
	run grep -c '^- `t::' out.md
	assert_output "50"
}

@test "render-test-summary: the simple inputs pass through without a document; the document wins over them (#1685)" {
	run env TESTS_PASSED=229 TESTS_FAILED=0 TESTS_TOTAL=255 TESTS_SKIPPED=13 TESTS_XFAILED=13 \
		TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Expected failures** | 13 |'

	# With a document, stray inputs are ignored and a malformed one does not warn.
	_leg legs/a 229 0 13 - passed
	run env RESULTS_FILE=legs/a/results.json TESTS_XFAILED=junk TESTS_XPASSED=7 \
		TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out2.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	refute_output --partial "::warning::"
	run grep -cE 'Expected failures|Unexpected passes' out2.md
	assert_output "0"
}

@test "render-test-summary: leaves no temporary directory behind (#1685)" {
	_xfail_doc
	mkdir -p tmp
	run env TMPDIR="$PWD/tmp" RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success \
		COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	run ls -A tmp
	assert_output ""
}

# =============================================================================
# Review fixes (#1702)
# =============================================================================

@test "render-test-summary: the simple-input path ignores a RESULTS_EXPECTED_FAILURES_FILE from the environment (#1702)" {
	jq -n '{tests: [{id: "LEAKED-FROM-ENV", reason: "x"}], omitted: 0}' >leak.json
	run env RESULTS_EXPECTED_FAILURES_FILE="$PWD/leak.json" TESTS_PASSED=5 TESTS_TOTAL=6 TESTS_XFAILED=1 \
		TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md bash "$ACTIONS/render-test-summary.sh"
	assert_success
	assert_file_contains_literal out.md '| **Expected failures** | 1 |'
	run grep -c 'LEAKED-FROM-ENV\|<details>' out.md
	assert_output "0"
}

@test "render-step-summary: Expected failures and Unexpected passes rows when above 0 (#1702)" {
	_leg legs/a 3 0 1 - passed
	jq '.counts += {"total": 7, "xfailed": 2, "xpassed": 1}' legs/a/results.json >legs/a/r.json
	run env RESULTS_FILE=legs/a/r.json TITLE="pytest Results" bash "$ACTIONS/render-step-summary.sh"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_line "| Skipped | 1 |"
	assert_line "| Expected failures | 2 |"
	assert_line "| Unexpected passes | 1 ⚠️ |"
	assert_line "| Total | 7 |"

	# None, or 0: no rows, the table as before.
	: >"$GITHUB_STEP_SUMMARY"
	jq '.counts += {"xfailed": 0, "xpassed": 0}' legs/a/results.json >legs/a/z.json
	run env RESULTS_FILE=legs/a/z.json TITLE="pytest Results" bash "$ACTIONS/render-step-summary.sh"
	assert_success
	run grep -cE 'Expected failures|Unexpected passes' "$GITHUB_STEP_SUMMARY"
	assert_output "0"
}

@test "render-pages-results: Expected failures and Unexpected passes rows when above 0 (#1702)" {
	_leg legs/a 3 0 1 - passed
	jq '.counts += {"total": 7, "xfailed": 2, "xpassed": 1}' legs/a/results.json >legs/a/r.json
	run env RESULTS_FILE=legs/a/r.json OUTPUT_DIR=site TITLE=t bash "$ACTIONS/render-pages-results.sh"
	assert_success
	assert_file_contains_literal site/index.html '<tr><td>Expected failures</td><td>2</td></tr>'
	assert_file_contains_literal site/index.html '<tr><td>Unexpected passes</td><td>1</td></tr>'

	run env RESULTS_FILE=legs/a/results.json OUTPUT_DIR=site2 TITLE=t bash "$ACTIONS/render-pages-results.sh"
	assert_success
	run grep -cE 'Expected failures|Unexpected passes' site2/index.html
	assert_output "0"
}

@test "render-test-summary: a document list of 50 large entries keeps the comment within the budget (#1702)" {
	mkdir -p legs/a
	jq -n '{tool: "pytest", status: "passed",
		counts: {passed: 1, failed: 0, skipped: 0, total: 51, xfailed: 50},
		duration_ms: 1, artifacts: [], source: {runner: "run-pytest", version: "x"},
		expected_failures: {tests: [range(50) | {id: ("<" * 500), reason: ("<" * 500)}], omitted: 0}}' >legs/a/results.json
	run env RESULTS_FILE=legs/a/results.json TEST_SUITE_NAME=x JOB_RESULT=success COMMENT_OUTPUT=out.md \
		bash "$ACTIONS/render-test-summary.sh"
	assert_success
	run bash -c '[ "$(wc -c <out.md)" -lt 25000 ]'
	assert_success
	local shown
	shown=$(grep -c '^- `' out.md)
	assert_file_contains_literal out.md "- and $((50 - shown)) more"
	assert_file_contains_literal out.md "</details>"
}
