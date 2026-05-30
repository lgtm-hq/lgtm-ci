#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for coverage PR comment gating (issue #168 §11)

load "../../helpers/common"

@test "reusable-test-rust: pr_comment_ready uses comment-ready output" {
	run awk '
		/^      pr_comment_ready:/ { block = 1 }
		block && /comment-ready == .true./ { found = 1; exit }
		block && /^      [a-zA-Z]/ && !/^      pr_comment_ready:/ { exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-rust.yml"
	assert_success
}

@test "reusable-test-rust-coverage: pr_comment_ready uses comment-ready output" {
	run awk '
		/^      pr_comment_ready:/ { block = 1 }
		block && /comment-ready == .true./ { found = 1; exit }
		block && /^      [a-zA-Z]/ && !/^      pr_comment_ready:/ { exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-rust-coverage.yml"
	assert_success
}

@test "reusable-test-node: coverage comment artifact gated on comment-ready" {
	run awk '
		/^      - name: Upload coverage PR comment artifact/ { in_step = 1 }
		in_step && /comment-ready == .true./ { found = 1; exit }
		in_step && /^      - name:/ && !/Upload coverage PR comment artifact/ { exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"
	assert_success
}

@test "generate-coverage-comment action: exposes comment-ready output" {
	run grep -q '^  comment-ready:' \
		"${PROJECT_ROOT}/.github/actions/generate-coverage-comment/action.yml"
	assert_success
}
