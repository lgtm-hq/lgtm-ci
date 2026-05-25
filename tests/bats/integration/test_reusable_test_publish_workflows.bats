#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for publish workflows that reuse lgtm-ci tooling

load "../../helpers/common"

_publish_checkout_order_ok() {
	local workflow="$1"
	awk '
		/^    steps:/ { in_steps = 1 }
		in_steps && /^      - name: Harden runner/ { harden = NR }
		in_steps && /^      - name: Checkout repository/ { repo = NR }
		in_steps && /^      - name: Checkout lgtm-ci tooling/ { tooling = NR }
		END {
			ok = (harden > 0 && repo > 0 && tooling > 0 && harden < repo && repo < tooling)
			exit !ok
		}
	' "$workflow"
}

_publish_tooling_actions_ok() {
	local workflow="$1"
	awk '
		/\.\/\.lgtm-ci-tooling\/\.github\/actions\/generate-coverage-badge/ { badge = 1 }
		/\.\/\.lgtm-ci-tooling\/\.github\/actions\/publish-test-results/ { publish = 1 }
		END { exit !(badge && publish) }
	' "$workflow"
}

@test "reusable-test-python-publish: checkout order preserves tooling in isolated jobs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run _publish_checkout_order_ok "$workflow"
	assert_success
}

@test "reusable-test-python-publish: uses local tooling actions for badge and Pages publish" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run _publish_tooling_actions_ok "$workflow"
	assert_success
}

@test "reusable-test-python-publish: does not rely on clean: false workaround" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run grep -q 'clean: false' "$workflow"
	assert_failure
}

@test "reusable-test-node-publish: checkout order preserves tooling in isolated jobs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run _publish_checkout_order_ok "$workflow"
	assert_success
}

@test "reusable-test-node-publish: uses local tooling actions for badge and Pages publish" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run _publish_tooling_actions_ok "$workflow"
	assert_success
}

@test "reusable-test-node-publish: does not rely on clean: false workaround" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run grep -q 'clean: false' "$workflow"
	assert_failure
}
