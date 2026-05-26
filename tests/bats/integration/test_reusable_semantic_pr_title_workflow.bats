#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-semantic-pr-title workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-semantic-pr-title.yml"

@test "reusable-semantic-pr-title: passes types via prepare step output" {
	run grep -E '^[[:space:]]+types: \$\{\{ steps\.prepare\.outputs\.types \}\}$' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: does not pass raw types input to action" {
	run grep -E '^[[:space:]]+types: \$\{\{ inputs\.types \}\}$' "$WORKFLOW"
	assert_failure
}

@test "reusable-semantic-pr-title: prepare step normalizes comma-separated lists" {
	run grep -F 'value="${value//,/$'\''\n'\''}"' "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: default types are newline-delimited" {
	run grep -F "default_types=\$'feat\\nfix\\n" "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: types input default is empty" {
	run awk '/^      types:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: ""'
}

@test "reusable-semantic-pr-title: job grants pull-requests read" {
	run grep -E '^[[:space:]]+pull-requests: read$' "$WORKFLOW"
	assert_success
}
