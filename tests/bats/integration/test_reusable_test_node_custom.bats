#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-node-custom workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-node-custom.yml"

@test "reusable-test-node-custom: test job checkout order preserves tooling" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" "test"
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

@test "reusable-test-node-custom: stages node-coverage artifact preserving working-directory prefix" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /Stage coverage for test summary/ { in_step = 1 }
		in_job && in_step && /node-coverage-staged/ && /WORKING_DIRECTORY/ && /COVERAGE_SUMMARY_FILE/ {
			found = 1
		}
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node-custom: node-coverage artifact upload uses staged directory" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /Upload coverage for test summary/ { in_upload = 1 }
		in_job && in_upload && /path: node-coverage-staged\// { dir = 1 }
		in_job && in_upload && /path: \$\{\{ inputs\.working-directory \}\}\/\$\{\{ inputs\.coverage-summary-file \}\}/ {
			single = 1
		}
		END { exit !(dir && !single) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node-custom: publish-test-summary coverage-file matches node-coverage staged layout" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /Stage coverage for test summary/ { in_stage = 1 }
		in_job && in_stage && /node-coverage-staged/ && /WORKING_DIRECTORY/ && /COVERAGE_SUMMARY_FILE/ {
			stage = 1
		}
		/^  publish-test-summary:/ { in_publish = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ {
			in_publish = 0
			in_cov = 0
		}
		in_publish && /coverage-file:/ { in_cov = 1 }
		in_publish && in_cov && /inputs\.working-directory/ && /inputs\.coverage-summary-file/ {
			publish = 1
		}
		END { exit !(stage && publish) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node-custom: publish-test-summary rejects bare coverage-summary-file path" {
	run awk '
		/^  publish-test-summary:/ { in_publish = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ { in_publish = 0 }
		in_publish && /^      coverage-file: \$\{\{ inputs\.coverage-summary-file \}\}$/ {
			bare = 1
		}
		END { exit bare }
	' "$WORKFLOW"
	assert_success
}
