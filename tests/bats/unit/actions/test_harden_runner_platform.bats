#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for retired local harden-runner composite (#412/#420)

load "../../../helpers/common"

ACTION="${PROJECT_ROOT}/.github/actions/harden-runner/action.yml"

@test "harden-runner: local composite is retired and fails closed" {
	run grep -F 'RETIRED (#412/#420)' "$ACTION"
	assert_success
	run grep -F 'exit 1' "$ACTION"
	assert_success
}

@test "harden-runner: does not nest step-security/harden-runner" {
	run awk '
		/uses:[[:space:]]+step-security\/harden-runner/ { bad = 1 }
		END { exit bad }
	' "$ACTION"
	assert_success
}

@test "harden-runner: still ships resolve-egress-endpoints.sh for sibling resolve" {
	[ -x "${PROJECT_ROOT}/.github/actions/harden-runner/resolve-egress-endpoints.sh" ]
	run grep -F \
		'../harden-runner/resolve-egress-endpoints.sh' \
		"${PROJECT_ROOT}/.github/actions/resolve-egress-allowlist/action.yml"
	assert_success
}
