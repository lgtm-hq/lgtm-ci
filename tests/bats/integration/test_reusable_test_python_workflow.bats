#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-python workflow coverage merge

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml"

@test "reusable-test-python: aggregate job merges per-version coverage artifacts" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /uses: actions\/upload-artifact\/merge@/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge uses python-coverage pattern" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /pattern: python-coverage-\*/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge produces python-coverage artifact" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /name: python-coverage$/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge gated on upload-coverage and coverage" {
	run awk '
		/Merge per-version coverage artifacts/ { getline; if ($0 ~ /inputs\.upload-coverage && inputs\.coverage/) found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge omits delete-merged so sources expire via retention-days" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /delete-merged:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: aggregate job grants actions write for artifact merge" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /actions: write/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge continues on error when no artifacts exist" {
	run awk '
		/Merge per-version coverage artifacts/ { in_step = 1 }
		in_step && /continue-on-error: true/ { found = 1; exit }
		in_step && /^      - name:/ && !/Merge per-version coverage artifacts/ { exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: publish-test-summary maps pytest formats to comment semantics" {
	run awk '
		/^  publish-test-summary:/ { in_publish = 1; in_cov = 0; passthrough = 0; semantic = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ { in_publish = 0 }
		in_publish && /coverage-format:/ { in_cov = 1 }
		in_publish && in_cov && /coverage-py/ { semantic = 1 }
		in_publish && in_cov && /cobertura/ { semantic = 1 }
		in_publish && in_cov && /coverage-format: \$\{\{ inputs\.coverage-format \}\}/ { passthrough = 1 }
		END { exit !(semantic && !passthrough) }
	' "$WORKFLOW"
	assert_success
}
