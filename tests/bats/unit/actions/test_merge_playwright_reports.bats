#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/merge-playwright-reports.sh (#804):
#          the JSON fallback tolerates malformed shard reports, and (#1474)
#          the merged totals are the sum of the shards end to end.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/merge-playwright-reports.sh"

setup() {
	setup_temp_dir
	export INPUT_DIR="${BATS_TEST_TMPDIR}/reports"
	export OUTPUT_DIR="${BATS_TEST_TMPDIR}/merged"
	mkdir -p "$INPUT_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

_github_output_value() {
	grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

@test "merge-playwright-reports merge: sums per-shard JSON stats" {
	install_fixture "playwright/reports/json-shard-1of2.json" "${INPUT_DIR}/a/playwright-results.json"
	install_fixture "playwright/reports/json-shard-2of2.json" "${INPUT_DIR}/b/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	assert_equal "${OUTPUT_DIR}/merged-results.json" "$(_github_output_value merged-path)"
	run jq -c '[.stats.expected, .stats.unexpected, .stats.skipped, .stats.duration]' "${OUTPUT_DIR}/merged-results.json"
	# failed = unexpected + flaky across both shards; duration is the integer-ms
	# sum (2373 + 567), not whole seconds times 1000
	assert_output "[1,2,1,2940]"
	assert_equal "0" "$(_github_output_value unparseable-count)"
}

@test "merge-playwright-reports merge: a malformed shard is skipped, never used as base" {
	# Sorted first so it would have been the base before #804.
	install_fixture "playwright/reports/json-malformed.json" "${INPUT_DIR}/0-broken/playwright-results.json"
	install_fixture "playwright/reports/json-shard-2of2.json" "${INPUT_DIR}/1-ok/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	assert_output --partial "Unparseable Playwright report skipped"
	assert_output --partial "::warning title=Playwright merge::1 shard report(s) were not valid JSON"
	assert_equal "1" "$(_github_output_value unparseable-count)"
	run jq -c '[.stats.expected, .stats.unexpected, .stats.skipped]' "${OUTPUT_DIR}/merged-results.json"
	assert_output "[1,0,1]"
}

@test "merge-playwright-reports summary: shows skipped invalid reports" {
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	: >"$GITHUB_STEP_SUMMARY"

	run env STEP=summary TOTAL_PASSED=1 TOTAL_FAILED=0 TOTAL_SKIPPED=1 REPORT_COUNT=2 UNPARSEABLE_COUNT=1 bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "| Reports skipped (invalid JSON) | :warning: 1 |"
}

@test "merge-playwright-reports merge: only malformed reports yields no merged path" {
	install_fixture "playwright/reports/json-malformed.json" "${INPUT_DIR}/a/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	assert_output --partial "No valid JSON reports found to merge"
	assert_output --partial "::warning title=Playwright merge::1 shard report(s) were not valid JSON; nothing merged"
	assert_equal "" "$(_github_output_value merged-path)"
	# The summary must still be able to show the skipped report.
	assert_equal "1" "$(_github_output_value unparseable-count)"
	assert_file_not_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports parse-merged: malformed merged file reports zero tests" {
	install_fixture "playwright/reports/json-malformed.json" "${BATS_TEST_TMPDIR}/merged-results.json"

	run env STEP=parse-merged MERGED_PATH="${BATS_TEST_TMPDIR}/merged-results.json" bash "$SCRIPT"
	assert_success
	assert_output --partial "not valid JSON"
	assert_equal "0" "$(_github_output_value total-passed)"
}

@test "merge-playwright-reports parse-merged: reads a merge-reports JSON" {
	install_fixture "playwright/reports/json-merged.json" "${BATS_TEST_TMPDIR}/merged-results.json"

	run env STEP=parse-merged MERGED_PATH="${BATS_TEST_TMPDIR}/merged-results.json" bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_github_output_value total-passed)"
	assert_equal "2" "$(_github_output_value total-failed)"
	assert_equal "1" "$(_github_output_value total-skipped)"
}

# --- merged totals equal the sum of the shards (#1474) ----------------------
#
# The e2e-matrix merge job downloads one directory per shard artifact
# (playwright-<suite>-<browser>-<shard>/playwright-results.json). The fixture
# reports are the two legs of the consumer fixture's matrix run, one test each.

_install_matrix_shards() {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	install_fixture "playwright/reports/json-matrix-shard-2of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-results.json"
}

# Runs merge then parse-merged on the merge's own merged-path, as the
# composite action does.
_merge_then_parse() {
	run env STEP=merge REPORT_FORMAT=html bash "$SCRIPT"
	assert_success
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_success
}

@test "merge-playwright-reports: collect counts one JSON report per shard directory" {
	_install_matrix_shards

	run env STEP=collect bash "$SCRIPT"
	assert_success
	assert_output --partial "Found 0 blob reports and 2 JSON reports"
	assert_equal "2" "$(_github_output_value report-count)"
}

@test "merge-playwright-reports: parse-merged totals are the sum of two real shards" {
	_install_matrix_shards

	_merge_then_parse
	# Each shard ran one test; before #1474 the merged file kept only the
	# first shard's suites and parse-merged printed "1 passed".
	assert_output --partial "Parsed: 2 passed, 0 failed, 0 skipped"
	assert_equal "2" "$(_github_output_value total-passed)"
	assert_equal "0" "$(_github_output_value total-failed)"
	assert_equal "0" "$(_github_output_value total-skipped)"
}

@test "merge-playwright-reports: the merged report holds every shard's specs" {
	_install_matrix_shards

	run env STEP=merge REPORT_FORMAT=html bash "$SCRIPT"
	assert_success
	run jq -c '[.suites[].file] | sort' "${OUTPUT_DIR}/merged-results.json"
	assert_output '["matrix-a.spec.js","matrix-b.spec.js"]'
	run jq -c '[.stats.expected, .stats.unexpected, .stats.skipped, .stats.duration]' \
		"${OUTPUT_DIR}/merged-results.json"
	# Integer-ms sum: 1258 (1258.417) + 1400 (1400.075).
	assert_output "[2,0,0,2658]"
}

@test "merge-playwright-reports: parse-merged sums mixed-status shards" {
	install_fixture "playwright/reports/json-shard-1of2.json" "${INPUT_DIR}/a/playwright-results.json"
	install_fixture "playwright/reports/json-shard-2of2.json" "${INPUT_DIR}/b/playwright-results.json"

	_merge_then_parse
	# The same totals playwright merge-reports gives (json-merged.json): 1 / 2 / 1.
	assert_equal "1" "$(_github_output_value total-passed)"
	assert_equal "2" "$(_github_output_value total-failed)"
	assert_equal "1" "$(_github_output_value total-skipped)"
}

@test "merge-playwright-reports merge: publishes per-shard counts" {
	_install_matrix_shards

	run env STEP=merge REPORT_FORMAT=html bash "$SCRIPT"
	assert_success
	assert_output --partial "Shard report playwright-smoke-chromium-2/playwright-results.json: 1 passed, 0 failed, 0 skipped"
	run jq -c '.' <<<"$(_github_output_value shard-counts)"
	assert_success
	assert_output '[{"report":"playwright-smoke-chromium-1/playwright-results.json","passed":1,"failed":0,"skipped":0},{"report":"playwright-smoke-chromium-2/playwright-results.json","passed":1,"failed":0,"skipped":0}]'
}

@test "merge-playwright-reports: an earlier merged-results.json is not a shard" {
	_install_matrix_shards
	# A re-run's pattern also matches the earlier attempt's merged artifact.
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-merged-report/merged-results.json"

	run env STEP=collect bash "$SCRIPT"
	assert_equal "2" "$(_github_output_value json-count)"
	_merge_then_parse
	assert_equal "2" "$(_github_output_value total-passed)"
}

@test "merge-playwright-reports merge: blob zips of every shard reach one merge-reports dir" {
	# Same blob file name in both legs, as with shard index 1 of two browsers.
	mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-1/blob-report" \
		"${INPUT_DIR}/playwright-smoke-firefox-1/blob-report"
	echo chromium >"${INPUT_DIR}/playwright-smoke-chromium-1/blob-report/report-1.zip"
	echo firefox >"${INPUT_DIR}/playwright-smoke-firefox-1/blob-report/report-1.zip"
	local stub_dir="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_dir"
	# Records each argument; for a directory, also the contents of its zips.
	cat >"${stub_dir}/bunx" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
	echo "arg:${arg}"
	if [[ -d "$arg" ]]; then
		cat "$arg"/*.zip | LC_ALL=C sort | sed 's/^/zip:/'
	fi
done
STUB
	chmod +x "${stub_dir}/bunx"

	run env PATH="${stub_dir}:${PATH}" STEP=merge REPORT_FORMAT=html bash "$SCRIPT"
	assert_success
	assert_output --partial "zip:chromium"
	assert_output --partial "zip:firefox"
	# Exactly one directory argument, holding both shards' zips.
	run grep -c '^arg:/' <<<"$output"
	assert_output "1"
}

@test "merge-playwright-reports merge: the blob staging dir is removed when merge-reports fails" {
	mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-1/blob-report"
	echo chromium >"${INPUT_DIR}/playwright-smoke-chromium-1/blob-report/report-1.zip"
	local stub_dir="${BATS_TEST_TMPDIR}/bin" record="${BATS_TEST_TMPDIR}/staged-dir"
	mkdir -p "$stub_dir"
	# Records the staging directory, then fails like a broken merge.
	cat >"${stub_dir}/bunx" <<STUB
#!/usr/bin/env bash
printf '%s' "\${@: -1}" >"${record}"
exit 1
STUB
	chmod +x "${stub_dir}/bunx"

	run env PATH="${stub_dir}:${PATH}" STEP=merge REPORT_FORMAT=html bash "$SCRIPT"
	assert_failure
	[ -s "$record" ]
	# A directory: assert_file_not_exists would pass on it vacuously.
	run test -e "$(cat "$record")"
	assert_failure
}

# --- expected shards (#1474) --------------------------------------------------
#
# The workflow passes the setup job's matrix. Every leg's artifact directory
# must hold exactly one results file, or the merge fails instead of publishing
# the surviving shards' totals as the run's totals.

# The matrix as the setup job's generate-matrix.sh emits it, so a change to
# its shape breaks these tests instead of the merge in CI.
# Usage: _matrix <suites> <browsers> <shards>
_matrix() {
	local out="${BATS_TEST_TMPDIR}/matrix_output"
	: >"$out"
	env GITHUB_OUTPUT="$out" STEP=e2e-matrix SUITES="$1" BROWSERS="$2" SHARDS="$3" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-matrix.sh" >/dev/null
	sed -n 's/^matrix=//p' "$out"
}

_merge_expecting() {
	run env STEP=merge REPORT_FORMAT=html EXPECTED_MATRIX="$1" ARTIFACT_PREFIX="${2:-playwright}" bash "$SCRIPT"
}

@test "merge-playwright-reports merge: a blob-prefixed artifact with JSON shards takes the JSON path" {
	# Valid prefix; its shard directories match the old blob* name test.
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/blob_smoke-smoke-chromium-1/playwright-results.json"
	install_fixture "playwright/reports/json-matrix-shard-2of2.json" \
		"${INPUT_DIR}/blob_smoke-smoke-chromium-2/playwright-results.json"

	_merge_expecting "$(_matrix smoke chromium 2)" blob_smoke
	assert_success
	refute_output --partial "Merging blob reports"
	assert_output --partial "All 2 expected shard reports present"
	assert_file_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports merge: a shard with only an HTML report fails" {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	# The leg uploaded its HTML report but no results file.
	install_fixture "playwright/reports/html-sidecar/playwright-report/index.html" \
		"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-report/index.html"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "::error title=Playwright merge::shard playwright-smoke-chromium-2: expected 1 results file, found 0"
	assert_file_not_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports merge: a shard that uploaded nothing fails" {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "shard playwright-smoke-chromium-2: expected 1 results file, found 0"
}

@test "merge-playwright-reports merge: a shard with two results files fails" {
	_install_matrix_shards
	install_fixture "playwright/reports/json-passing.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-2/extra-results.json"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "shard playwright-smoke-chromium-2: expected 1 results file, found 2"
}

@test "merge-playwright-reports merge: a results file outside the expected shards fails" {
	_install_matrix_shards
	install_fixture "playwright/reports/json-passing.json" \
		"${INPUT_DIR}/playwright-smoke-firefox-1/playwright-results.json"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "::error title=Playwright merge::found 3 results files for 2 expected shards"
}

@test "merge-playwright-reports merge: matching shards pass, ignoring HTML and merged artifacts" {
	_install_matrix_shards
	# What the download also matches: the run-playwright HTML-only artifact, an
	# earlier attempt's merged report, and a JSON attachment in an HTML report.
	install_fixture "playwright/reports/html-sidecar/playwright-report/index.html" \
		"${INPUT_DIR}/playwright-report/index.html"
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-merged-report/merged-results.json"
	install_fixture "playwright/reports/json-passing.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-report/data/attachment.json"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_success
	assert_output --partial "All 2 expected shard reports present"
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_equal "2" "$(_github_output_value total-passed)"
}

@test "merge-playwright-reports merge: the matrix product sets the expected shards" {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/e2e-smoke-chromium-1/playwright-results.json"
	install_fixture "playwright/reports/json-matrix-shard-2of2.json" \
		"${INPUT_DIR}/e2e-smoke-firefox-1/playwright-results.json"

	# shards: 0 or 1 both yield shard ["1"].
	_merge_expecting "$(_matrix smoke chromium,firefox 1)" e2e
	assert_success
	assert_output --partial "All 2 expected shard reports present"
}

@test "merge-playwright-reports merge: an invalid expected matrix fails" {
	_install_matrix_shards

	_merge_expecting '{"shards":2}'
	assert_failure
	assert_output --partial "::error title=Playwright merge::EXPECTED_MATRIX is not a {suite, browser, shard} matrix"
}

@test "merge-playwright-reports merge: without an expected matrix the check is skipped with a warning" {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=html bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning title=Playwright merge::expected-matrix not set"
}

# --- pinned merge semantics ---------------------------------------------------

# The merge sums executions; it does not dedupe by test ID. Overlapping shards
# (the same test run in two legs) therefore count it twice. That is expected:
# Playwright's own sharding never overlaps, so a double count means the caller
# ran a test twice.
@test "merge-playwright-reports: overlapping shards count each execution" {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-results.json"

	_merge_then_parse
	assert_equal "2" "$(_github_output_value total-passed)"
	run jq -c '[.suites[].specs[].id] | length' "${OUTPUT_DIR}/merged-results.json"
	assert_output "2"
}

@test "merge-playwright-reports merge: global errors of every shard are kept" {
	local shard
	for shard in 1 2; do
		mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-${shard}"
		jq --arg message "shard ${shard} global setup failed" '.errors = [{message: $message}]' \
			"${PROJECT_ROOT}/tests/fixtures/playwright/reports/json-matrix-shard-${shard}of2.json" \
			>"${INPUT_DIR}/playwright-smoke-chromium-${shard}/playwright-results.json"
	done

	run env STEP=merge REPORT_FORMAT=html bash "$SCRIPT"
	assert_success
	run jq -c '[.errors[].message]' "${OUTPUT_DIR}/merged-results.json"
	assert_output '["shard 1 global setup failed","shard 2 global setup failed"]'
}

# --- inventory before the merge path; well-formed reports only (#1474) ------

# A bunx that records every call and succeeds, so the blob path would pass.
_stub_bunx() {
	local stub_dir="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_dir"
	cat >"${stub_dir}/bunx" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${BATS_TEST_TMPDIR}/bunx_calls"
STUB
	chmod +x "${stub_dir}/bunx"
	export PATH="${stub_dir}:${PATH}"
}

@test "merge-playwright-reports merge: a stale blob report cannot bypass the shard check" {
	_stub_bunx
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-1/blob-report-1"
	echo stale >"${INPUT_DIR}/playwright-smoke-chromium-1/blob-report-1/report.zip"
	# Shard 2 never uploaded.

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "shard playwright-smoke-chromium-2: expected 1 results file, found 0"
	assert_file_not_exists "${BATS_TEST_TMPDIR}/bunx_calls"
}

@test "merge-playwright-reports merge: with a matrix, blob zips are ignored for the checked JSON" {
	_stub_bunx
	_install_matrix_shards
	mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-1/blob-report"
	echo stale >"${INPUT_DIR}/playwright-smoke-chromium-1/blob-report/report-1.zip"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_success
	assert_output --partial "::warning title=Playwright merge::blob reports ignored with expected-matrix"
	assert_file_not_exists "${BATS_TEST_TMPDIR}/bunx_calls"
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_equal "2" "$(_github_output_value total-passed)"
}

@test "merge-playwright-reports merge: an empty shard report fails the shard check" {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-2"
	: >"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-results.json"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "::error title=Playwright merge::shard playwright-smoke-chromium-2: playwright-smoke-chromium-2/playwright-results.json is not a Playwright JSON report"
	refute_output --partial "expected shard reports present"
	assert_file_not_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports merge: a shard report without suites and stats fails" {
	local body
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-2"
	for body in 'null' '{}' '{"suites":[]}' '{"stats":{}}' '{"suites":{},"stats":{}}'; do
		printf '%s' "$body" >"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-results.json"
		_merge_expecting "$(_matrix smoke chromium 2)"
		assert_failure
		assert_output --partial "is not a Playwright JSON report"
	done
	# A truncated report too.
	install_fixture "playwright/reports/json-malformed.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-results.json"
	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "is not a Playwright JSON report"
}

# Decision: a well-formed report of zero tests is a true count, not a missing
# shard, so the merge accepts it. Requiring a test per leg is the caller's
# check on shard-counts (the consumer fixture's verify job).
@test "merge-playwright-reports merge: a well-formed zero-test shard passes and counts zero" {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	install_fixture "playwright/reports/json-empty.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-results.json"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_success
	assert_output --partial "All 2 expected shard reports present"
	run jq -c '[.[] | [.passed, .failed, .skipped]]' <<<"$(_github_output_value shard-counts)"
	assert_output "[[1,0,0],[0,0,0]]"
}

# --- stats counters must match the tests in suites (#1474) ------------------

_install_shard2_body() {
	install_fixture "playwright/reports/json-matrix-shard-1of2.json" \
		"${INPUT_DIR}/playwright-smoke-chromium-1/playwright-results.json"
	mkdir -p "${INPUT_DIR}/playwright-smoke-chromium-2"
	printf '%s' "$1" >"${INPUT_DIR}/playwright-smoke-chromium-2/playwright-results.json"
}

@test "merge-playwright-reports merge: stats that count tests the suites lack fail" {
	# shard-counts would read 1, but parse-merged counts the suites: 1 dropped.
	_install_shard2_body '{"suites":[],"stats":{"expected":1,"unexpected":0,"skipped":0,"flaky":0}}'

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "::error title=Playwright merge::shard playwright-smoke-chromium-2: playwright-smoke-chromium-2/playwright-results.json holds 0/0/0 passed/failed/skipped tests in suites but its stats count 1/0/0"
	assert_file_not_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports merge: suites holding tests the stats do not count fail" {
	local body
	body=$(jq -c '.stats.expected = 0' \
		"${PROJECT_ROOT}/tests/fixtures/playwright/reports/json-matrix-shard-2of2.json")
	_install_shard2_body "$body"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "holds 1/0/0 passed/failed/skipped tests in suites but its stats count 0/0/0"
}

@test "merge-playwright-reports merge: stats without Playwright's integer counters fail" {
	local body
	for body in \
		'{"suites":[],"stats":{}}' \
		'{"suites":[],"stats":{"expected":0,"unexpected":0,"skipped":0}}' \
		'{"suites":[],"stats":{"expected":-1,"unexpected":1,"skipped":0,"flaky":0}}' \
		'{"suites":[],"stats":{"expected":0.5,"unexpected":0,"skipped":0,"flaky":0}}' \
		'{"suites":[],"stats":{"expected":"0","unexpected":0,"skipped":0,"flaky":0}}'; do
		_install_shard2_body "$body"
		_merge_expecting "$(_matrix smoke chromium 2)"
		assert_failure
		assert_output --partial "shard playwright-smoke-chromium-2: playwright-smoke-chromium-2/playwright-results.json is not a Playwright JSON report"
	done
}

@test "merge-playwright-reports merge: a complete, consistent zero-test report passes" {
	_install_shard2_body '{"suites":[],"errors":[],"stats":{"duration":0,"expected":0,"unexpected":0,"skipped":0,"flaky":0}}'

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_success
	assert_output --partial "All 2 expected shard reports present"
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_equal "1" "$(_github_output_value total-passed)"
}

# --- one counting rule for the check, shard-counts and the totals (#1474) ---

@test "merge-playwright-reports merge: a tests value jq cannot count fails closed" {
	# The stats claim 3; before, a jq error compared "" with "" and passed, and
	# the stats fallback then published "3 passed".
	_install_shard2_body '{"suites":[{"title":"a.spec.js","specs":[{"title":"t","tests":"oops"}]}],"stats":{"expected":3,"unexpected":0,"skipped":0,"flaky":0}}'

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "::error title=Playwright merge::shard playwright-smoke-chromium-2: cannot count the tests in playwright-smoke-chromium-2/playwright-results.json"
	assert_file_not_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports: tests under config agree across check, shard-counts and totals" {
	local body
	body=$(jq -c '.config.metadata.tests = [{"status": "failed"}]' \
		"${PROJECT_ROOT}/tests/fixtures/playwright/reports/json-matrix-shard-2of2.json")
	_install_shard2_body "$body"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_success
	assert_output --partial "All 2 expected shard reports present"
	run jq -c '[.[] | [.passed, .failed, .skipped]]' <<<"$(_github_output_value shard-counts)"
	assert_output "[[1,0,0],[1,0,0]]"
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_success
	# The merged totals equal the sum of shard-counts.
	assert_equal "2" "$(_github_output_value total-passed)"
	assert_equal "0" "$(_github_output_value total-failed)"
}

@test "merge-playwright-reports merge: stats that move a test to another category fail" {
	# Suites hold one skipped test; stats claim one unexpected. The sums agree,
	# but shard-counts (suites) and the stats would disagree on the category.
	local body
	body=$(jq -c '.suites[0].specs[0].tests[0].status = "skipped"
		| .stats += {expected: 0, unexpected: 1, skipped: 0, flaky: 0}' \
		"${PROJECT_ROOT}/tests/fixtures/playwright/reports/json-matrix-shard-2of2.json")
	_install_shard2_body "$body"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_failure
	assert_output --partial "holds 0/0/1 passed/failed/skipped tests in suites but its stats count 0/1/0"
	assert_file_not_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports merge: a flaky test counts as failed on both sides of the check" {
	local body
	body=$(jq -c '.suites[0].specs[0].tests[0].status = "flaky"
		| .stats += {expected: 0, unexpected: 0, skipped: 0, flaky: 1}' \
		"${PROJECT_ROOT}/tests/fixtures/playwright/reports/json-matrix-shard-2of2.json")
	_install_shard2_body "$body"

	_merge_expecting "$(_matrix smoke chromium 2)"
	assert_success
	run jq -c '[.[] | [.passed, .failed, .skipped]]' <<<"$(_github_output_value shard-counts)"
	assert_output "[[1,0,0],[0,1,0]]"
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_equal "1" "$(_github_output_value total-failed)"
}

@test "merge-playwright-reports merge: a stats-only report merged with suite reports fails" {
	# Without an expected matrix nothing checks the shards first. The merged
	# suites would hide the stats-only report's 8/2/1, so the totals would drop
	# them: the merge must fail instead.
	_install_matrix_shards
	mkdir -p "${INPUT_DIR}/stats-only"
	printf '%s' '{"stats":{"expected":8,"unexpected":2,"skipped":1,"flaky":0}}' \
		>"${INPUT_DIR}/stats-only/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error title=Playwright merge::merged report counts 2 passed, 0 failed, 0 skipped but the shards sum to 10 passed, 2 failed, 1 skipped (for example, a report whose tests are only in its stats"
	refute_line --partial "shard-counts="
	run grep -c '^shard-counts=' "$GITHUB_OUTPUT"
	assert_output "0"
}

@test "merge-playwright-reports merge: a lone stats-only report still merges" {
	mkdir -p "${INPUT_DIR}/stats-only"
	printf '%s' '{"stats":{"expected":8,"unexpected":2,"skipped":1,"flaky":0}}' \
		>"${INPUT_DIR}/stats-only/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_equal "8" "$(_github_output_value total-passed)"
	assert_equal "2" "$(_github_output_value total-failed)"
	assert_equal "1" "$(_github_output_value total-skipped)"
}

@test "merge-playwright-reports merge: flaky tests are not counted twice in the merged stats" {
	# Stats-only report with flaky:2. The merge folds flaky into unexpected, so
	# keeping flaky:2 too would make the merged parse read 5 failed, not 3.
	install_fixture "playwright/parse-playwright-json-includes-flaky-in-stats-failed-count.json" "${INPUT_DIR}/a/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	run jq -c '[.stats.expected, .stats.unexpected, .stats.skipped, .stats.flaky]' "${OUTPUT_DIR}/merged-results.json"
	assert_output "[5,3,0,0]"
	run env STEP=parse-merged MERGED_PATH="$(_github_output_value merged-path)" bash "$SCRIPT"
	assert_equal "5" "$(_github_output_value total-passed)"
	assert_equal "3" "$(_github_output_value total-failed)"
}
