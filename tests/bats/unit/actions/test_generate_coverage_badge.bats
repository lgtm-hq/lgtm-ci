#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-coverage-badge.sh

load "../../../helpers/common"
load "../../../helpers/coverage_gate_golden"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "generate-coverage-badge: outputs for readable reports are unchanged (#1692)" {
	local name
	for name in "${COVERAGE_GATE_CASES[@]}"; do
		[[ "$name" == badge-* ]] || continue
		run coverage_gate_render "$name" "${BATS_TEST_TMPDIR}/${name}"
		assert_success
		assert_output "$(cat "${PROJECT_ROOT}/tests/fixtures/coverage-gate-golden/${name}.txt")"
	done
}

# The Opus P1 input: LF:oops in the second record (#1692 review).
write_malformed_lcov() {
	printf 'TN:\nSF:a\nDA:1,1\nLF:10\nLH:10\nend_of_record\nSF:b\nDA:1,0\nLF:oops\nLH:0\nend_of_record\n' >"$1"
}

@test "generate-coverage-badge: an unreadable report fails calculate with no percentage or colour (#1692)" {
	local outputs="${BATS_TEST_TMPDIR}/github-output" report
	for report in lcov.info coverage.xml; do
		case "$report" in
		lcov.info) write_malformed_lcov "${BATS_TEST_TMPDIR}/${report}" ;;
		coverage.xml) printf '<?xml version="1.0"?>\n<report><coverage line-rate="1"/></report>\n' \
			>"${BATS_TEST_TMPDIR}/${report}" ;;
		esac
		: >"$outputs"
		run env GITHUB_OUTPUT="$outputs" STEP=calculate COVERAGE_FILE="${BATS_TEST_TMPDIR}/${report}" \
			bash "${PROJECT_ROOT}/scripts/ci/actions/generate-coverage-badge.sh"
		assert_failure 1
		assert_output --partial "line coverage is not a number"
		run cat "$outputs"
		assert_output $'coverage-percent=invalid\nbadge-color=lightgrey'
	done
}

@test "generate-coverage-badge: a percentage that is not a number draws an unknown grey badge (#1692)" {
	local outputs="${BATS_TEST_TMPDIR}/github-output" format
	for format in svg json; do
		: >"$outputs"
		run env GITHUB_OUTPUT="$outputs" STEP=generate COVERAGE_PERCENT=invalid FORMAT="$format" \
			OUTPUT_PATH="${BATS_TEST_TMPDIR}/badge.${format}" \
			bash "${PROJECT_ROOT}/scripts/ci/actions/generate-coverage-badge.sh"
		assert_success
		run cat "${BATS_TEST_TMPDIR}/badge.${format}"
		assert_output --partial "unknown"
		refute_output --partial "invalid"
		refute_output --regexp '[0-9]\.[0-9]%'
		refute_output --partial "#44cc11"
		refute_output --partial "#e05d44"
		run grep "badge-url" "$outputs"
		assert_output --partial "coverage-unknown-lightgrey"
	done
	local summary="${BATS_TEST_TMPDIR}/summary"
	: >"$summary"
	run env GITHUB_OUTPUT="$outputs" GITHUB_STEP_SUMMARY="$summary" STEP=summary COVERAGE_PERCENT=invalid \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-coverage-badge.sh"
	assert_success
	run cat "$summary"
	assert_output --partial "Coverage: **unknown**"
}

@test "generate-coverage-badge: a report unreadable only in its branches gives no percentage or colour (#1692)" {
	local outputs="${BATS_TEST_TMPDIR}/github-output" report="${BATS_TEST_TMPDIR}/lcov.info"
	printf 'SF:a\nDA:1,1\nLF:1\nLH:1\nBRF:oops\nBRH:1\nend_of_record\n' >"$report"
	: >"$outputs"
	run env GITHUB_OUTPUT="$outputs" STEP=calculate COVERAGE_FILE="$report" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-coverage-badge.sh"
	assert_failure 1
	run cat "$outputs"
	assert_output $'coverage-percent=invalid\nbadge-color=lightgrey'
}
