#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/format-security-comment.py

load "../../../helpers/common"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "format-security-comment: formats clean scan with no vulnerabilities" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	install_fixture "security/osv-results-clean.json" "$json_file"

	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" "$json_file"
	assert_success
	assert_output --partial "No security vulnerabilities found in dependencies."
	assert_output --partial "No suppressions configured."
}

@test "format-security-comment: formats vulnerability table" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	install_fixture "security/osv-results-with-vuln.json" "$json_file"

	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" "$json_file"
	assert_success
	assert_output --partial "Vulnerability Report"
	assert_output --partial "GHSA-xxxx-yyyy-zzzz in example-crate"
	assert_output --partial "Cargo.lock"
}

@test "format-security-comment: fails on missing file" {
	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" \
		"${BATS_TEST_TMPDIR}/missing.json"
	assert_failure
}

@test "format-security-comment: renders probe status from metadata key" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	install_fixture "security/osv-results-metadata-suppressions.json" "$json_file"

	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" "$json_file"
	assert_success
	assert_output --partial "GHSA-stale-2222"
	assert_output --partial "Stale — safe to remove"
	assert_output --partial "EXPIRED"
	refute_output --partial "legacy 'ai_metadata'"
}

@test "format-security-comment: legacy ai_metadata key still renders with a warning" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	install_fixture "security/osv-results-legacy-ai-metadata.json" "$json_file"

	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" "$json_file"
	assert_success
	assert_output --partial "Stale — safe to remove"
	assert_output --partial "legacy 'ai_metadata'"
	assert_output --partial "lgtm-hq/lgtm-ci#825"
}

@test "format-security-comment: fails when probe metadata is missing but TOML has dated entries" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	install_fixture "security/osv-results-no-suppressions-meta.json" "$json_file"
	install_fixture "security/osv-scanner-active-stale-expired.toml" "${BATS_TEST_TMPDIR}/.osv-scanner.toml"

	run bash -c "cd '${BATS_TEST_TMPDIR}' && python3 '${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py' osv-results.json"
	assert_failure
	assert_output --partial "Suppression status unavailable"
	assert_output --partial "neither 'metadata.suppressions' nor the legacy 'ai_metadata.suppressions'"
	assert_output --partial "GHSA-active-1111"
}

@test "format-security-comment: reads TOML suppressions without ignoreUntil" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	install_fixture "security/osv-results-no-suppressions-meta.json" "$json_file"

	install_fixture "security/osv-scanner-no-ignore-until.toml" "${BATS_TEST_TMPDIR}/.osv-scanner.toml"

	run bash -c "cd '${BATS_TEST_TMPDIR}' && python3 '${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py' osv-results.json"
	assert_success
	assert_output --partial "GHSA-xxxx-yyyy-zzzz"
	assert_output --partial "No fix available"
	refute_output --partial "No suppressions configured."
}
