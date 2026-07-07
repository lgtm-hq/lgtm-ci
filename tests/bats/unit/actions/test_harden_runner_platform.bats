#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Platform guard tests for harden-runner composite pre-step

load "../../../helpers/common"

ACTION="${PROJECT_ROOT}/.github/actions/harden-runner/action.yml"

@test "harden-runner: agent pre-step is guarded for Linux only" {
	run awk '
		/- name: Ensure agent state for post cleanup/ { found = 1 }
		found && /^      if: runner\.os == .Linux./ { linux_guard = 1; exit }
		END { exit !linux_guard }
	' "$ACTION"
	assert_success
}

@test "harden-runner: pre-step still uses /home/agent path on Linux" {
	run grep -F '/home/agent' "$ACTION"
	assert_success
}

@test "harden-runner: documents validate-runner-policy prerequisite" {
	run grep -F 'validate-runner-policy' "$ACTION"
	assert_success
}
