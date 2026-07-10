#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/remove-tooling-checkout.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/remove-tooling-checkout.sh"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "remove-tooling-checkout.sh: fails without GITHUB_WORKSPACE" {
	run env -u GITHUB_WORKSPACE bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_WORKSPACE is required"
}

@test "remove-tooling-checkout.sh: fails when workspace directory missing" {
	run env GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/missing-ws" bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_WORKSPACE does not exist"
}

@test "remove-tooling-checkout.sh: removes .lgtm-ci-tooling directory" {
	local ws="${BATS_TEST_TMPDIR}/ws"
	mkdir -p "${ws}/.lgtm-ci-tooling/scripts"
	echo keep >"${ws}/README.md"
	echo tooling >"${ws}/.lgtm-ci-tooling/scripts/x.sh"

	run env GITHUB_WORKSPACE="$ws" bash "$SCRIPT"
	assert_success
	assert_output --partial "Removed temporary lgtm-ci tooling checkout"
	[[ ! -e "${ws}/.lgtm-ci-tooling" ]]
	[[ -f "${ws}/README.md" ]]
}

@test "remove-tooling-checkout.sh: succeeds when tooling dir already absent" {
	local ws="${BATS_TEST_TMPDIR}/ws-empty"
	mkdir -p "$ws"

	run env GITHUB_WORKSPACE="$ws" bash "$SCRIPT"
	assert_success
	assert_output --partial "Removed temporary lgtm-ci tooling checkout"
}
