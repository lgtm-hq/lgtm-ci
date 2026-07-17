#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-shell coverage-run timeout (#556)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-shell.yml"

@test "reusable-test-shell: coverage-run step has timeout-minutes below job default" {
	run awk '
		/^      - name: Run BATS tests with coverage/ { in_step = 1 }
		in_step && /^      - name:/ && !/^      - name: Run BATS tests with coverage/ { in_step = 0 }
		in_step && /^        id: coverage-run/ { saw_id = 1 }
		in_step && /^        timeout-minutes: 45/ { saw_timeout = 1 }
		END { exit !(saw_id && saw_timeout) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: job timeout-minutes defaults to 60" {
	run awk '/^      timeout-minutes:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: 60'
}
