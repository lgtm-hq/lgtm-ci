#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/classify-suppressions.py

load "../../../helpers/common"

CLASSIFY_SCRIPT="${PROJECT_ROOT}/scripts/ci/security/classify-suppressions.py"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR"
}

teardown() {
	teardown_temp_dir
}

@test "classify-suppressions: classifies active stale and expired entries" {
	install_fixture "security/osv-scanner-active-stale-expired.toml" ".osv-scanner.toml"

	local probe_json
	probe_json=$(cat "${FIXTURES_DIR}/security/probe-active-1111.json")

	run bash -c "printf '%s' '$probe_json' | python3 '$CLASSIFY_SCRIPT'"
	assert_success
	assert_output --partial '"active": ["GHSA-active-1111"]'
	assert_output --partial '"stale": ["GHSA-stale-2222"]'
	assert_output --partial '"expired": ["GHSA-expired-3333"]'
	assert_output --partial '"expired_until": {"GHSA-expired-3333": "2020-01-01"}'
}

@test "classify-suppressions: honors CONFIG_PATH override" {
	mkdir -p config
	install_fixture "security/osv-scanner-custom-path.toml" "config/custom.toml"

	local probe_json='{"results":[{"packages":[{"vulnerabilities":[{"id":"CVE-2024-00001"}]}]}]}'

	run bash -c "export CONFIG_PATH=config/custom.toml; printf '%s' '$probe_json' | python3 '$CLASSIFY_SCRIPT'"
	assert_success
	assert_output --partial '"active": ["CVE-2024-00001"]'
}

@test "classify-suppressions: treats missing ignoreUntil as permanent suppression" {
	install_fixture "security/osv-scanner-permanent.toml" ".osv-scanner.toml"

	local probe_json='{"results":[{"packages":[{"vulnerabilities":[{"id":"GHSA-permanent-active"}]}]}]}'

	run bash -c "printf '%s' '$probe_json' | python3 '$CLASSIFY_SCRIPT'"
	assert_success
	assert_output --partial '"active": ["GHSA-permanent-active"]'
	assert_output --partial '"stale": ["GHSA-permanent-stale"]'
	assert_output --partial '"expired": []'
}

@test "classify-suppressions: fails on empty probe output" {
	install_fixture "security/osv-scanner-probe-missing.toml" ".osv-scanner.toml"

	run bash -c "printf '' | python3 '$CLASSIFY_SCRIPT'"
	assert_failure
}
