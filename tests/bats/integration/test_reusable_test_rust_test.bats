#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-rust-test workflow (#68)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-rust-test.yml"
FACADE="${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml"

@test "reusable-test-rust-test: exposes cargo test inputs" {
	run grep -q 'toolchain:' "$WORKFLOW"
	assert_success
	run grep -q 'features:' "$WORKFLOW"
	assert_success
	run grep -q 'workspace:' "$WORKFLOW"
	assert_success
	run grep -q 'extra-args:' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-test: defines test and comment-pr jobs" {
	run grep -q '^  test:' "$WORKFLOW"
	assert_success
	run grep -q '^  comment-pr:' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-test: uses run-caller-script for cargo test" {
	run grep -q 'run-caller-script.sh' "$WORKFLOW"
	assert_success
	run grep -q 'run-cargo-test.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-test: test job has no pull-requests permission" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-test: delegates PR comment to reusable-test-pr-comment" {
	run awk '
		/^  comment-pr:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  comment-pr:/ { in_job = 0 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-test-pr-comment\.yml/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: delegates to reusable-test-rust-test" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-test-rust-test\.yml/ { found = 1; exit }
		END { exit !found }
	' "$FACADE"
	assert_success
}
