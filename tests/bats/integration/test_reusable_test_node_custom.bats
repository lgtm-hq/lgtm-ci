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
		in_job && in_steps && /^      - name: Checkout repository/ { repo = NR }
		in_job && in_steps && /^      - name: Harden runner/ { harden = NR }
		in_job && in_steps && /^      - name: Checkout lgtm-ci tooling/ { tooling = NR }
		END {
			ok = (repo > 0 && harden > 0 && tooling > 0 && repo < harden && harden < tooling)
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
	run awk '
		/^      test-command:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      test-command:/ { in_input = 0 }
		in_input && /required: true/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
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

@test "reusable-test-node-custom: aggregate-tests derives passed from matrix result" {
	run awk '
		/^  aggregate-tests:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate-tests:/ { in_job = 0 }
		in_job && /needs\.test\.result/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	run awk '
		/value: \$\{\{ jobs\.test\.outputs\.passed/ { bad = 1 }
		END { exit bad }
	' "$WORKFLOW"
	assert_success
}
