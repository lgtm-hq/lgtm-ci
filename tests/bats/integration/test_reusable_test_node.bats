#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-node workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"

_test_custom_checkout_order_ok() {
	awk '
		/^  test-custom:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-custom:/ { in_job = 0 }
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

@test "reusable-test-node: test-custom checkout order preserves tooling" {
	run _test_custom_checkout_order_ok
	assert_success
}

@test "reusable-test-node: test-custom does not rely on clean: false workaround" {
	run awk '
		/^  test-custom:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-custom:/ { in_job = 0 }
		in_job && /clean: false/ { found = 1 }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}
