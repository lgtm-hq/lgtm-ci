#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for publish workflows that reuse lgtm-ci tooling

load "../../helpers/common"

@test "reusable-test-python-publish: preserves .lgtm-ci-tooling on repo checkout" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run awk '
		/Checkout repository/ { in_step = 1 }
		in_step && /clean: false/ { found = 1; exit }
		in_step && /^      - name:/ && !/Checkout repository/ { exit }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-test-node-publish: preserves .lgtm-ci-tooling on repo checkout" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run awk '
		/Checkout repository/ { in_step = 1 }
		in_step && /clean: false/ { found = 1; exit }
		in_step && /^      - name:/ && !/Checkout repository/ { exit }
		END { exit !found }
	' "$workflow"
	assert_success
}
