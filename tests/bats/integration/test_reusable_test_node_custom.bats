#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-node-custom workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-node-custom.yml"

_test_checkout_order_ok() {
	awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /^    steps:/ { in_steps = 1 }
		in_job && in_steps && /^      - name: Harden runner/ { harden = NR }
		in_job && in_steps && /^      - name: Checkout repository/ { repo = NR }
		in_job && in_steps && /^      - name: Checkout lgtm-ci tooling/ { tooling = NR }
		END {
			ok = (harden > 0 && repo > 0 && tooling > 0 && harden < repo && repo < tooling)
			exit !ok
		}
	' "$WORKFLOW"
}

@test "reusable-test-node-custom: test job checkout order preserves tooling" {
	run _test_checkout_order_ok
	assert_success
}

@test "reusable-test-node-custom: requires test-command input" {
	run grep -E '^      test-command:$' "$WORKFLOW"
	assert_success
	run awk '/^      test-command:/{getline; print}' "$WORKFLOW" | grep -q 'required: true'
	assert_success
}

@test "reusable-test-node-custom: test job name uses job-name input" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /^    name: \$\{\{ inputs\.job-name \}\}$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node-custom: does not define vitest-only test-command branching" {
	run grep -q 'test-vitest:' "$WORKFLOW"
	assert_failure
	run grep -q 'test-custom:' "$WORKFLOW"
	assert_failure
}
