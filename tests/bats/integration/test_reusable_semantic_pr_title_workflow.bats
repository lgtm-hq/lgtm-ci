#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-semantic-pr-title workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-semantic-pr-title.yml"
SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/prepare-semantic-pr-lists.sh"

@test "reusable-semantic-pr-title: passes types via prepare step output" {
	run grep -E '^[[:space:]]+types: \$\{\{ steps\.prepare\.outputs\.types \}\}$' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: does not pass raw types input to action" {
	run grep -E '^[[:space:]]+types: \$\{\{ inputs\.types \}\}$' "$WORKFLOW"
	assert_failure
}

@test "reusable-semantic-pr-title: prepare step runs tooling script" {
	run grep -F 'bash .lgtm-ci-tooling/scripts/ci/actions/prepare-semantic-pr-lists.sh' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: checks out lgtm-ci tooling scripts" {
	run grep -F 'path: .lgtm-ci-tooling' "$WORKFLOW"
	assert_success
	run grep -F 'sparse-checkout: |' "$WORKFLOW"
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

@test "prepare-semantic-pr-lists: default types are newline-delimited" {
	run grep -F "default_types=\$'feat\\nfix\\n" "$SCRIPT"
	assert_success
}

@test "prepare-semantic-pr-lists: normalizes comma-separated lists" {
	run grep -F 'value="${value//,/$'\''\n'\''}"' "$SCRIPT"
	assert_success
	run grep -F 'set_github_output_multiline' "$SCRIPT"
	assert_success
}

@test "prepare-semantic-pr-lists: writes scopes only when non-empty" {
	run awk '
		/set_github_output_multiline scopes/ { found = 1 }
		END { exit !found }
	' "$SCRIPT"
	assert_success
	run grep -F 'if [[ -n "${scopes//[[:space:]]/}" ]]; then' "$SCRIPT"
	assert_success
}
