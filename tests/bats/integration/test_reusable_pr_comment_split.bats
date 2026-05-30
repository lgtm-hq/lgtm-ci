#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for split PR-comment reusable workflows (#231)

load "../../helpers/common"

_lint_only_has_no_pr_permissions() {
	local workflow="$1"
	run awk '
		/^jobs:/ { in_jobs = 1 }
		in_jobs && /^[^ ]/ && !/^jobs:/ { in_jobs = 0 }
		in_jobs && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "$workflow"
}

_orchestrator_delegates_comment() {
	local workflow="$1"
	local comment_reusable="$2"
	run awk -v reusable="$comment_reusable" '
		/^  comment(-pr)?:/ { in_comment = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  comment(-pr)?:/ { in_comment = 0 }
		in_comment && $0 ~ "uses: \\./\\.github/workflows/" reusable { found = 1; exit }
		END { exit !found }
	' "$workflow"
}


@test "reusable-quality-lint: no pull-requests permission" {
	run _lint_only_has_no_pr_permissions \
		"${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml"
	assert_success
}

@test "ci.yml: calls reusable-quality-lint directly" {
	run awk '
		/^  quality:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  quality:/ { in_job = 0 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-quality-lint\.yml/ { found = 1; exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/ci.yml"
	assert_success
}

@test "ci.yml: calls reusable-quality-pr-comment directly" {
	run awk '
		/^  quality-pr-comment:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  quality-pr-comment:/ { in_job = 0 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-quality-pr-comment\.yml/ { found = 1; exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/ci.yml"
	assert_success
}

@test "reusable-quality.yml removed in favor of split reusables" {
	run test ! -f "${PROJECT_ROOT}/.github/workflows/reusable-quality.yml"
	assert_success
}

@test "reusable-coverage: coverage job has no pull-requests permission" {
	run awk '
		/^  coverage:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  coverage:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml"
	assert_success
}

@test "reusable-coverage: delegates PR comment to reusable-coverage-pr-comment" {
	run _orchestrator_delegates_comment \
		"${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml" \
		"reusable-coverage-pr-comment.yml"
	assert_success
}

@test "reusable-validate: validate job has no pull-requests permission" {
	run awk '
		/^  validate:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  validate:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-validate.yml"
	assert_success
}

@test "reusable-validate: delegates PR comment to reusable-artifact-pr-comment" {
	run _orchestrator_delegates_comment \
		"${PROJECT_ROOT}/.github/workflows/reusable-validate.yml" \
		"reusable-artifact-pr-comment.yml"
	assert_success
}

@test "reusable-link-check: link-check job has no pull-requests permission" {
	run awk '
		/^  link-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  link-check:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-link-check.yml"
	assert_success
}

@test "reusable-link-check: delegates PR comment to reusable-artifact-pr-comment" {
	run _orchestrator_delegates_comment \
		"${PROJECT_ROOT}/.github/workflows/reusable-link-check.yml" \
		"reusable-artifact-pr-comment.yml"
	assert_success
}

@test "reusable-rust-test: does not use reusable-artifact-pr-comment for PR comments" {
	run grep -q 'reusable-artifact-pr-comment.yml' \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml"
	assert_failure
}

@test "reusable-rust-test: delegates PR comment to reusable-test-pr-comment" {
	run _orchestrator_delegates_comment \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml" \
		"reusable-test-pr-comment.yml"
	assert_success
}

@test "reusable-test-node: coverage comment uses inline matrix job not reusable" {
	run awk '
		/^  coverage-pr-comment:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  coverage-pr-comment:/ { in_job = 0 }
		in_job && /^    uses: \.\/\.github\/workflows\// { found = 1; exit }
		END { exit found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"
	assert_success
}

@test "reusable-test-node: coverage comment job has strategy matrix" {
	run awk '
		/^  coverage-pr-comment:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  coverage-pr-comment:/ { in_job = 0 }
		in_job && /^    strategy:/ { found = 1; exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"
	assert_success
}

@test "reusable-test-python: still delegates test comment to reusable-test-pr-comment" {
	run _orchestrator_delegates_comment \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml" \
		"reusable-test-pr-comment.yml"
	assert_success
}

@test "reusable-quality-pr-comment: grants pull-requests write on comment job only" {
	run awk '
		/^  comment:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  comment:/ { in_job = 0 }
		in_job && /pull-requests: write/ { found = 1; exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-quality-pr-comment.yml"
	assert_success
}

@test "reusable-coverage-pr-comment: delegates body generation to script" {
	run awk '
		/Generate coverage comment body/ { in_step = 1 }
		in_step && /generate-coverage-pr-comment\.sh/ { found = 1; exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-coverage-pr-comment.yml"
	assert_success
}

@test "reusable-coverage-pr-comment: has no multiline inline run blocks" {
	run awk '
		/^        run: \|/ { found = 1; exit }
		END { exit found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-coverage-pr-comment.yml"
	assert_success
}
