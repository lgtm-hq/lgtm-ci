#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for harden-runner support files used by resolve-egress-allowlist

load "../../../helpers/common"

ACTION="${PROJECT_ROOT}/.github/actions/harden-runner/action.yml"

@test "harden-runner: no local composite action.yml (invoke step-security directly)" {
	[[ ! -f "$ACTION" ]]
}

@test "harden-runner: still ships resolve-egress-endpoints.sh for sibling resolve" {
	[ -x "${PROJECT_ROOT}/.github/actions/harden-runner/resolve-egress-endpoints.sh" ]
	run grep -F \
		'../harden-runner/resolve-egress-endpoints.sh' \
		"${PROJECT_ROOT}/.github/actions/resolve-egress-allowlist/action.yml"
	assert_success
}
