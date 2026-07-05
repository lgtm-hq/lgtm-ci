#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/scan-vulnerabilities.sh counts step

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_run_counts() {
	local results_file="$1"
	run env \
		STEP=counts \
		RESULTS_FILE="$results_file" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"
}

_write_results_fixture() {
	local file="$1"
	cat >"$file" <<'EOF'
{
  "matches": [
    {"vulnerability": {"severity": "Critical", "id": "CVE-1"}, "artifact": {"name": "a", "version": "1.0"}},
    {"vulnerability": {"severity": "High", "id": "CVE-2"}, "artifact": {"name": "b", "version": "1.0"}},
    {"vulnerability": {"severity": "High", "id": "CVE-3"}, "artifact": {"name": "c", "version": "1.0"}},
    {"vulnerability": {"severity": "Medium", "id": "CVE-4"}, "artifact": {"name": "d", "version": "1.0"}},
    {"vulnerability": {"severity": "Low", "id": "CVE-5"}, "artifact": {"name": "e", "version": "1.0"}},
    {"vulnerability": {"severity": "Low", "id": "CVE-6"}, "artifact": {"name": "f", "version": "1.0"}},
    {"vulnerability": {"severity": "Low", "id": "CVE-7"}, "artifact": {"name": "g", "version": "1.0"}},
    {"vulnerability": {"severity": "Negligible", "id": "CVE-8"}, "artifact": {"name": "h", "version": "1.0"}}
  ]
}
EOF
}

@test "scan-vulnerabilities counts: fails when RESULTS_FILE is not set" {
	run env STEP=counts \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"

	assert_failure
	assert_output --partial "RESULTS_FILE is required"
}

@test "scan-vulnerabilities counts: fails when results file is missing" {
	_run_counts "${BATS_TEST_TMPDIR}/does-not-exist.json"

	assert_failure
	assert_output --partial "Results file not found or unreadable"
	run grep -qE -- '^critical-count=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "scan-vulnerabilities counts: fails on malformed JSON" {
	printf 'not-json{{{\n' >"${BATS_TEST_TMPDIR}/results.json"

	_run_counts "${BATS_TEST_TMPDIR}/results.json"

	assert_failure
	assert_output --partial "Failed to parse grype results with jq"
	run grep -qE -- '^critical-count=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "scan-vulnerabilities counts: emits correct counts for known severities" {
	_write_results_fixture "${BATS_TEST_TMPDIR}/results.json"

	_run_counts "${BATS_TEST_TMPDIR}/results.json"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^vulnerabilities-found=true$'
	assert_file_contains "$GITHUB_OUTPUT" '^critical-count=1$'
	assert_file_contains "$GITHUB_OUTPUT" '^high-count=2$'
	assert_file_contains "$GITHUB_OUTPUT" '^medium-count=1$'
	assert_file_contains "$GITHUB_OUTPUT" '^low-count=3$'
}

@test "scan-vulnerabilities counts: emits zeros when no matches present" {
	printf '{"matches": []}\n' >"${BATS_TEST_TMPDIR}/results.json"

	_run_counts "${BATS_TEST_TMPDIR}/results.json"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^vulnerabilities-found=false$'
	assert_file_contains "$GITHUB_OUTPUT" '^critical-count=0$'
	assert_file_contains "$GITHUB_OUTPUT" '^high-count=0$'
	assert_file_contains "$GITHUB_OUTPUT" '^medium-count=0$'
	assert_file_contains "$GITHUB_OUTPUT" '^low-count=0$'
}
