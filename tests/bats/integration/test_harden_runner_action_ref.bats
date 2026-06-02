#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for harden-runner workflow pins

load "../../helpers/common"

VALIDATE="${PROJECT_ROOT}/scripts/ci/actions/validate-harden-runner-action-ref.sh"

@test "validate-harden-runner-action-ref: all reusables use local composite path" {
	run bash "$VALIDATE"
	assert_success
}
