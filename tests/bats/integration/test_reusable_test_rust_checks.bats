#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-rust-checks workflow (#68)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-rust-checks.yml"
FACADE="${PROJECT_ROOT}/.github/workflows/reusable-rust-checks.yml"

@test "reusable-test-rust-checks: exposes cargo test, clippy, and fmt inputs" {
	run grep -q 'toolchain:' "$WORKFLOW"
	assert_success
	run grep -q 'fmt-check:' "$WORKFLOW"
	assert_success
	run grep -q 'clippy:' "$WORKFLOW"
	assert_success
	run grep -q 'features:' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-checks: defines test, clippy, fmt, and comment jobs" {
	run grep -q '^  test:' "$WORKFLOW"
	assert_success
	run grep -q '^  clippy:' "$WORKFLOW"
	assert_success
	run grep -q '^  fmt:' "$WORKFLOW"
	assert_success
	run grep -q '^  comment-pr:' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-checks: uses run-caller-script for cargo commands" {
	run grep -q 'run-caller-script.sh' "$WORKFLOW"
	assert_success
	run grep -q 'run-cargo-test.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-checks: comment job posts via post-pr-comment action" {
	run awk '
		/^  comment-pr:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  comment-pr:/ { in_job = 0 }
		in_job && /post-pr-comment/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-rust-checks: test job has no pull-requests permission" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-checks: delegates to reusable-test-rust-checks" {
	run awk '
		/^  checks:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  checks:/ { in_job = 0 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-test-rust-checks\.yml/ { found = 1; exit }
		END { exit !found }
	' "$FACADE"
	assert_success
}
