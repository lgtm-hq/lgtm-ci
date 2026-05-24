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
