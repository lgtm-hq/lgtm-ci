#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for split publish-summary/report reusables (#231, #281)

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

_orchestrator_delegates_publish() {
	local workflow="$1"
	local publish_reusable="$2"
	run awk -v reusable="$publish_reusable" '
		/^  publish(-[a-z0-9-]+)?:/ { in_publish = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish(-[a-z0-9-]+)?:/ {
			in_publish = 0
		}
		in_publish && $0 ~ "uses: \\./\\.github/workflows/" reusable {
			found = 1
			exit
		}
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

@test "ci.yml: calls reusable-publish-quality-summary directly" {
	run awk '
		/^  publish-quality-summary:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-quality-summary:/ { in_job = 0 }
		in_job && /uses: \.\/\.github\/workflows\/reusable-publish-quality-summary\.yml/ { found = 1; exit }
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

@test "reusable-coverage: delegates test summary to reusable-publish-test-summary" {
	run _orchestrator_delegates_publish \
		"${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml" \
		"reusable-publish-test-summary.yml"
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

@test "reusable-validate: delegates report publish to reusable-publish-artifact-report" {
	run _orchestrator_delegates_publish \
		"${PROJECT_ROOT}/.github/workflows/reusable-validate.yml" \
		"reusable-publish-artifact-report.yml"
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

@test "reusable-link-check: delegates report publish to reusable-publish-artifact-report" {
	run _orchestrator_delegates_publish \
		"${PROJECT_ROOT}/.github/workflows/reusable-link-check.yml" \
		"reusable-publish-artifact-report.yml"
	assert_success
}

@test "reusable-rust-test: does not use reusable-publish-artifact-report for PR summaries and reports" {
	run grep -q 'reusable-publish-artifact-report.yml' \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml"
	assert_failure
}

@test "reusable-rust-test: delegates test summary to reusable-publish-test-summary" {
	run _orchestrator_delegates_publish \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml" \
		"reusable-publish-test-summary.yml"
	assert_success
}

@test "reusable-test-node: coverage summary uses inline matrix job not nested reusable" {
	run awk '
		/^  publish-test-summary-coverage:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary-coverage:/ { in_job = 0 }
		in_job && /^    uses: \.\/\.github\/workflows\// { found = 1; exit }
		END { exit found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"
	assert_success
}

@test "reusable-test-node: coverage summary job has strategy matrix" {
	run awk '
		/^  publish-test-summary-coverage:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary-coverage:/ { in_job = 0 }
		in_job && /^    strategy:/ { found = 1; exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"
	assert_success
}

@test "reusable-test-python: delegates test summary to reusable-publish-test-summary" {
	run _orchestrator_delegates_publish \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml" \
		"reusable-publish-test-summary.yml"
	assert_success
}

@test "reusable-test-node: does not reference removed coverage-pr-comment input" {
	run grep -q 'coverage-pr-comment' \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"
	assert_failure
}

@test "reusable-publish-quality-summary: grants pull-requests write on publish job only" {
	run awk '
		/^  publish-quality-summary:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-quality-summary:/ { in_job = 0 }
		in_job && /pull-requests: write/ { found = 1; exit }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/reusable-publish-quality-summary.yml"
	assert_success
}

@test "reusable-publish-test-summary: uses generate-test-summary or coverage composite" {
	run test -f "${PROJECT_ROOT}/.github/workflows/reusable-publish-test-summary.yml"
	assert_success
	run grep -q 'generate-test-summary\.sh' \
		"${PROJECT_ROOT}/.github/workflows/reusable-publish-test-summary.yml"
	assert_success
	run grep -q 'generate-coverage-comment' \
		"${PROJECT_ROOT}/.github/workflows/reusable-publish-test-summary.yml"
	assert_success
}

@test "reusable-publish-test-summary: tolerates missing coverage artifact" {
	run grep -q 'id: download-coverage' \
		"${PROJECT_ROOT}/.github/workflows/reusable-publish-test-summary.yml"
	assert_success
	run grep -q 'continue-on-error: true' \
		"${PROJECT_ROOT}/.github/workflows/reusable-publish-test-summary.yml"
	assert_success
	run grep -q 'steps.download-coverage.conclusion' \
		"${PROJECT_ROOT}/.github/workflows/reusable-publish-test-summary.yml"
	assert_success
}
