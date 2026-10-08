#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/aggregate-results.sh (results.v1 legs, #1080)

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	touch "$GITHUB_OUTPUT"
	cd "$BATS_TEST_TMPDIR" || exit 1
}

teardown() {
	teardown_temp_dir
}

# Write one results.v1 leg the way a runner upload lands after download:
# <results_dir>/<artifact-name>/results/<runner>/<value>/results.json
# Usage: _write_leg <results_dir> <runner> <key> <value> <passed> <failed> <skipped> <total> <coverage|-> <status>
_write_leg() {
	local results_dir="$1" runner="$2" key="$3" value="$4"
	local passed="$5" failed="$6" skipped="$7" total="$8" coverage="$9" status="${10}"
	local dir="${results_dir}/${results_dir}-${value}/results/${runner}/${value}"
	local coverage_json=""
	if [[ "$coverage" != "-" ]]; then
		coverage_json="\"coverage\": {\"lines\": ${coverage}},"
	fi

	mkdir -p "$dir"
	cat >"${dir}/results.json" <<EOF
{
  "tool": "${runner}",
  "status": "${status}",
  "counts": {"passed": ${passed}, "failed": ${failed}, "skipped": ${skipped}, "total": ${total}},
  "duration_ms": 100,
  ${coverage_json}
  "artifacts": [{"kind": "report", "path": "${runner}-${value}.json"}],
  "source": {"runner": "run-${runner}", "version": "abc"},
  "matrix": {"key": "${key}", "value": "${value}"}
}
EOF
}

@test "aggregate-results: sums python metrics across matrix legs" {
	_write_leg python-results pytest python-version "3.12" 5 1 0 6 80.00 failed
	_write_leg python-results pytest python-version "3.14" 7 0 1 8 90.00 passed

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=12"
	assert_file_contains "$GITHUB_OUTPUT" "tests-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "tests-skipped=1"
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=14"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.00"
	assert_file_contains "$GITHUB_OUTPUT" "status=failed"
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}

@test "aggregate-results: sums rust and node legs the same way" {
	_write_leg rust-results nextest rust-toolchain "stable" 5 0 0 5 80.00 passed
	_write_leg rust-results nextest rust-toolchain "beta" 7 0 0 7 90.00 passed
	_write_leg node-results vitest node-version "20" 5 0 0 5 - passed
	_write_leg node-results vitest node-version "22" 7 0 0 7 - passed

	run env RESULTS_DIR=rust-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-passed=12"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.00"
	assert_file_contains "$GITHUB_OUTPUT" "passed=true"

	: >"$GITHUB_OUTPUT"
	run env RESULTS_DIR=node-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "tests-total=12"
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent="
	assert_file_contains "$GITHUB_OUTPUT" "status=passed"
	assert_file_contains "$GITHUB_OUTPUT" "passed=true"
}

@test "aggregate-results: a single leg's coverage literal is passed through verbatim" {
	_write_leg python-results pytest python-version "3.12" 5 0 0 5 85.71428571428571 passed

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=85.71428571428571"

	: >"$GITHUB_OUTPUT"
	rm -rf python-results
	_write_leg python-results pytest python-version "3.12" 5 0 0 5 100.0 passed
	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "coverage-percent=100.0"
}

@test "aggregate-results: marks failed when any leg is not passed; error wins over failed" {
	_write_leg python-results pytest python-version "3.12" 5 0 0 5 80.00 passed
	_write_leg python-results pytest python-version "3.14" 3 2 0 5 70.00 failed

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
	assert_file_contains "$GITHUB_OUTPUT" "status=failed"

	: >"$GITHUB_OUTPUT"
	_write_leg python-results pytest python-version "3.13" 0 0 0 0 - error
	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "status=error"
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}

@test "aggregate-results: no-tests legs are not passed" {
	_write_leg python-results pytest python-version "3.12" 0 0 0 0 - no-tests

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "status=no-tests"
	assert_file_contains "$GITHUB_OUTPUT" "passed=false"
}

@test "aggregate-results: validates leg count against matrix json" {
	_write_leg python-results pytest python-version "3.12" 5 0 0 5 80.00 passed

	run env \
		RESULTS_DIR=python-results \
		MATRIX_JSON='{"include":[{"python-version":"3.12"},{"python-version":"3.14"}]}' \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "Expected 2 matrix results, found 1"
}

@test "aggregate-results: rejects a leg that violates the schema before summing" {
	_write_leg python-results pytest python-version "3.12" 5 0 0 5 80.00 passed
	mkdir -p python-results/python-results-3.14/results/pytest/3.14
	echo '{"tool":"pytest","status":"green"}' >python-results/python-results-3.14/results/pytest/3.14/results.json

	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial '$.status: must be one of'
	assert_output --partial 'missing required property counts'
}

@test "aggregate-results: writes a schema-valid aggregate document on request" {
	_write_leg python-results pytest python-version "3.12" 5 1 0 6 80.00 failed
	_write_leg python-results pytest python-version "3.14" 7 0 1 8 90.00 passed

	run env RESULTS_DIR=python-results AGGREGATE_OUTPUT=out/results.json \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	run jq -c '{tool, status, counts, duration_ms, coverage, artifacts: (.artifacts | length), source}' out/results.json
	assert_output '{"tool":"pytest","status":"failed","counts":{"passed":12,"failed":1,"skipped":1,"total":14},"duration_ms":200,"coverage":{"lines":85.00},"artifacts":2,"source":{"runner":"aggregate-results","version":"abc"}}'
	run bash -c 'source "$LIB_DIR/testing/results.sh"; results_v1_validate out/results.json'
	assert_success
}

@test "aggregate-results: aggregate document keeps a single leg's coverage literal" {
	_write_leg python-results pytest python-version "3.12" 5 0 0 5 100.0 passed

	run env RESULTS_DIR=python-results AGGREGATE_OUTPUT=out/results.json \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_success
	run grep -c '"lines": 100.0$' out/results.json
	assert_output "1"
}

@test "aggregate-results: fails without GITHUB_OUTPUT" {
	_write_leg python-results pytest python-version "3.12" 5 0 0 5 80.00 passed

	run env -u GITHUB_OUTPUT RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}

@test "aggregate-results: fails when no results documents exist" {
	mkdir -p python-results
	run env RESULTS_DIR=python-results \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "No results.json documents found"
}

@test "aggregate-results: requires RESULTS_DIR" {
	run env -u RESULTS_DIR \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"

	assert_failure
	assert_output --partial "RESULTS_DIR is required"
}
