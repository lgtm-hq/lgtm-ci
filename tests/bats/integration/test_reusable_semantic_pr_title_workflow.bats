#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-semantic-pr-title workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-semantic-pr-title.yml"
SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/prepare-semantic-pr-lists.sh"

@test "reusable-semantic-pr-title: passes types via prepare step output" {
	local expected='          types: ${{ steps.prepare.outputs.types }}'

	run grep -E '^[[:space:]]+types: \$\{\{ steps\.prepare\.outputs\.types \}\}$' \
		"$WORKFLOW"
	assert_success
	assert_equal "$expected" "$output"
}

@test "reusable-semantic-pr-title: does not pass raw types input to action" {
	run grep -E '^[[:space:]]+types: \$\{\{ inputs\.types \}\}$' "$WORKFLOW"
	assert_failure
}

@test "reusable-semantic-pr-title: passes scopes via prepare step output" {
	local expected='          scopes: ${{ steps.prepare.outputs.scopes }}'

	run grep -E '^[[:space:]]+scopes: \$\{\{ steps\.prepare\.outputs\.scopes \}\}$' \
		"$WORKFLOW"
	assert_success
	assert_equal "$expected" "$output"
}

@test "reusable-semantic-pr-title: does not pass raw scopes input to action" {
	run grep -E '^[[:space:]]+scopes: \$\{\{ inputs\.scopes \}\}$' "$WORKFLOW"
	assert_failure
}

@test "reusable-semantic-pr-title: prepare step runs tooling script" {
	local expected='        run: bash .lgtm-ci-tooling/scripts/ci/actions/prepare-semantic-pr-lists.sh'

	run grep -F 'bash .lgtm-ci-tooling/scripts/ci/actions/prepare-semantic-pr-lists.sh' \
		"$WORKFLOW"
	assert_success
	assert_equal "$expected" "$output"
}

@test "reusable-semantic-pr-title: checks out lgtm-ci tooling path" {
	local expected='          path: .lgtm-ci-tooling'

	run grep -F 'path: .lgtm-ci-tooling' "$WORKFLOW"
	assert_success
	assert_equal "$expected" "$output"
}

@test "reusable-semantic-pr-title: checks out tooling scripts via sparse-checkout" {
	local expected_key='          sparse-checkout: |'
	local expected_entry='            scripts/ci/'

	run grep -F 'sparse-checkout: |' "$WORKFLOW"
	assert_success
	assert_equal "$expected_key" "$output"

	run grep -E '^            scripts/ci/$' "$WORKFLOW"
	assert_success
	assert_equal "$expected_entry" "$output"
}

@test "reusable-semantic-pr-title: checks out post-pr-comment via sparse-checkout" {
	run grep -F '.github/actions/post-pr-comment' "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: types input default is empty" {
	run awk '/^      types:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: ""'
}

@test "reusable-semantic-pr-title: post-failure-comment defaults to true" {
	run awk '/^      post-failure-comment:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: true'
}

@test "reusable-semantic-pr-title: comment-marker defaults to semantic-pr-title" {
	run awk '/^      comment-marker:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "semantic-pr-title"'
}

@test "reusable-semantic-pr-title: max-length defaults to zero" {
	run awk '/^      max-length:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "0"'
}

@test "reusable-semantic-pr-title: validate step uses semantic id for error_message" {
	run grep -F 'id: semantic' "$WORKFLOW"
	assert_success

	run grep -F 'steps.semantic.outputs.error_message' "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: posts failure comment via post-pr-comment" {
	run grep -F 'Post semantic PR title failure comment' "$WORKFLOW"
	assert_success

	run grep -F './.lgtm-ci-tooling/.github/actions/post-pr-comment' "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: post step gates on formatted comment body" {
	run grep -F 'steps.failure-comment.outcome == '"'"'success'"'"'' "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: fail step uses always when validation fails" {
	run awk '
		/Fail on invalid PR title/ { show = 1 }
		show && /always\(\)/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: clears failure comment on success" {
	run grep -F 'Clear semantic PR title failure comment' "$WORKFLOW"
	assert_success

	run awk '
		/Clear semantic PR title failure comment/ { show = 1 }
		show && /delete-on-empty/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-semantic-pr-title: job grants pull-requests write" {
	local expected='      pull-requests: write'

	run grep -E '^[[:space:]]+pull-requests: write$' "$WORKFLOW"
	assert_success
	assert_equal "$expected" "$output"
}

@test "reusable-semantic-pr-title: composite action removed" {
	[[ ! -f "${PROJECT_ROOT}/.github/actions/semantic-pr-title/action.yml" ]]
}

@test "reusable-semantic-pr-title: in-house validator script removed" {
	[[ ! -f "${PROJECT_ROOT}/scripts/ci/actions/semantic-pr-title.sh" ]]
}

@test "prepare-semantic-pr-lists: default types are newline-delimited" {
	local expected=$'default_types=$\'feat\\nfix\\ndocs\\nstyle\\nrefactor\\nperf\\ntest\\nbuild\\nci\\nchore\\nrevert\''

	run grep -F "default_types=\$'feat\\nfix\\n" "$SCRIPT"
	assert_success
	assert_equal "$expected" "$output"
}

@test "prepare-semantic-pr-lists: normalizes comma-separated lists" {
	local expected='		value="${value//,/$'\''\n'\''}"'

	run grep -F 'value="${value//,/$'\''\n'\''}"' "$SCRIPT"
	assert_success
	assert_equal "$expected" "$output"
}

@test "prepare-semantic-pr-lists: uses shared multiline output helper" {
	local expected='set_github_output_multiline types "$types"'

	run grep -F 'set_github_output_multiline types "$types"' "$SCRIPT"
	assert_success
	assert_equal "$expected" "$output"
}

@test "prepare-semantic-pr-lists: writes scopes only when non-empty" {
	run awk '
		/set_github_output_multiline scopes/ { found = 1 }
		END { exit !found }
	' "$SCRIPT"
	assert_success

	local expected='if [[ -n "${scopes//[[:space:]]/}" ]]; then'

	run grep -F 'if [[ -n "${scopes//[[:space:]]/}" ]]; then' "$SCRIPT"
	assert_success
	assert_equal "$expected" "$output"
}
