#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-node Vitest workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml"

@test "reusable-test-node: vitest job name uses job-name input" {
	run awk '
		/^  test-vitest:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-vitest:/ { in_job = 0 }
		in_job && /^    name: \$\{\{ inputs\.job-name \}\}$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node: does not define test-command input or custom job" {
	run grep -q '^      test-command:$' "$WORKFLOW"
	assert_failure
	run grep -q 'test-custom:' "$WORKFLOW"
	assert_failure
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

@test "reusable-test-node: stages node-coverage artifact preserving working-directory prefix" {
	run awk '
		/^  test-vitest:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-vitest:/ { in_job = 0 }
		in_job && /Stage coverage for test summary/ {
			in_step = 1
			script = 0
			env_wd = 0
			env_cov = 0
			env_coverage = 0
		}
		in_job && in_step && /stage-node-coverage-test-summary\.sh/ { script = 1 }
		in_job && in_step && /WORKING_DIRECTORY:/ { env_wd = 1 }
		in_job && in_step && /COVERAGE_SUMMARY_FILE:/ { env_cov = 1 }
		in_job && in_step && /COVERAGE: \$\{\{ inputs\.coverage \}\}/ { env_coverage = 1 }
		END { exit !(script && env_wd && env_cov && env_coverage) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node: node-coverage artifact upload uses staged directory" {
	run awk '
		/^  test-vitest:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-vitest:/ { in_job = 0 }
		in_job && /Upload coverage for test summary/ { in_upload = 1 }
		in_job && in_upload && /path: node-coverage-staged\// { dir = 1 }
		in_job && in_upload && /path: \$\{\{ inputs\.working-directory \}\}\/\$\{\{ inputs\.coverage-summary-file \}\}/ {
			single = 1
		}
		END { exit !(dir && !single) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node: publish-test-summary coverage-file matches node-coverage staged layout" {
	run awk '
		/^  test-vitest:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-vitest:/ { in_job = 0 }
		in_job && /Stage coverage for test summary/ {
			in_stage = 1
			script = 0
			env_wd = 0
			env_cov = 0
			env_coverage = 0
		}
		in_job && in_stage && /stage-node-coverage-test-summary\.sh/ { script = 1 }
		in_job && in_stage && /WORKING_DIRECTORY:/ { env_wd = 1 }
		in_job && in_stage && /COVERAGE_SUMMARY_FILE:/ { env_cov = 1 }
		in_job && in_stage && /COVERAGE: \$\{\{ inputs\.coverage \}\}/ { env_coverage = 1 }
		/^  publish-test-summary:/ { in_publish = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ {
			in_publish = 0
			in_cov = 0
		}
		in_publish && /coverage-file:/ { in_cov = 1 }
		in_publish && in_cov && /inputs\.working-directory/ && /inputs\.coverage-summary-file/ {
			publish = 1
		}
		END { exit !(script && env_wd && env_cov && env_coverage && publish) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-node: publish-test-summary rejects bare coverage-summary-file path" {
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
