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

@test "reusable-test-node: skipped jobs use static names without expressions" {
	run awk '
		/^  test-vitest:/ { vitest = 1; custom = 0 }
		/^  test-custom:/ { custom = 1; vitest = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-vitest:/ && !/^  test-custom:/ { vitest = 0; custom = 0 }
		vitest && /^    name:/ { if ($0 ~ /\$\{\{/) bad_vitest = 1 }
		custom && /^    name:/ { if ($0 ~ /\$\{\{/) bad_custom = 1 }
		END { exit (bad_vitest || bad_custom) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node: exposes pages coverage HTML inputs and staging script" {
	run grep -q 'upload-pages-coverage-html' "$WORKFLOW"
	assert_success
	run grep -q 'stage-node-pages-coverage.sh' "$WORKFLOW"
	assert_success
	run grep -q 'pages-coverage-node-version' "$WORKFLOW"
	assert_success
	run grep -q 'pages-coverage-status:' "$WORKFLOW"
	assert_success
	run grep -q 'record-pages-coverage-upload-status.sh' "$WORKFLOW"
	assert_success
	run grep -q 'pages-upload-outcome:' "$WORKFLOW"
	assert_success
	run grep -q 'PAGES_UPLOAD_OUTCOME:' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node: gates pages upload on successful staging" {
	run grep -Fq "steps.stage-pages-coverage.outcome == 'success'" "$WORKFLOW"
	assert_success
}
