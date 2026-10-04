#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: No lgtm-ci composite may stand in for step-security/harden-runner (#412/#420/#913)

load "../../../helpers/common"

@test "harden-runner: no local composite action (invoke step-security directly)" {
	[[ ! -e "${PROJECT_ROOT}/.github/actions/harden-runner" ]]
}

@test "harden-runner: the resolve composite is gone (its output could never reach the pre hook)" {
	[[ ! -e "${PROJECT_ROOT}/.github/actions/resolve-egress-allowlist" ]]
	[[ ! -e "${PROJECT_ROOT}/scripts/ci/actions/resolve-egress-endpoints.sh" ]]
	[[ ! -e "${PROJECT_ROOT}/scripts/ci/actions/sync-harden-runner-bundle.sh" ]]
}
