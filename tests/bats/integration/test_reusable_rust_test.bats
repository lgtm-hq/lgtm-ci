#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for unified reusable-rust-test workflow (#168 §13)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml"

@test "reusable-rust-test: exposes coverage flag and nextest inputs" {
	run grep -qE '^      coverage:' "$WORKFLOW"
	assert_success
	run grep -qE '^      toolchain:' "$WORKFLOW"
	assert_success
	run grep -q 'run-rust-nextest.sh' "$WORKFLOW"
	assert_success
	run grep -q 'run-rust-nextest-coverage.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: defines both nextest paths and excludes legacy coverage comment" {
	run awk '
		/run-rust-nextest\.sh/ { nextest = 1 }
		/run-rust-nextest-coverage\.sh/ { cov = 1 }
		/generate-coverage-comment/ { bad = 1 }
		END { exit !(nextest && cov) || bad }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: runs nextest and llvm-cov nextest under mutually exclusive if conditions" {
	run awk '
		/run-rust-nextest\.sh/ { nextest_step = 1 }
		/run-rust-nextest-coverage\.sh/ { cov_step = 1 }
		/if: \$\{\{ !inputs\.coverage \}\}/ { nextest_if = 1 }
		/if: inputs\.coverage/ { cov_if = 1 }
		END {
			exit !(nextest_step && cov_step && nextest_if && cov_if)
		}
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: defines test and comment-pr jobs" {
	run grep -q '^  test:' "$WORKFLOW"
	assert_success
	run grep -q '^  comment-pr:' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: delegates PR comment to reusable-test-pr-comment" {
	run awk '
		/^  comment-pr:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  comment-pr:/ { in_job = 0 }
		in_job && /reusable-test-pr-comment\.yml/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: test job has no pull-requests permission" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}
