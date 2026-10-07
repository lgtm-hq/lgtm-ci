#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-rust-build workflow concurrency
#          (#1076): the group is namespaced by callee and caller workflow so
#          two callers on one ref never cancel each other (#108 history).

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-rust-build.yml"

# The rendered concurrency.group expression of the build job, folded to one line.
_group() {
	awk '
		/^    concurrency:$/ { show = 1; next }
		show && /^      group:/ { grab = 1; next }
		grab && /^        / { printf "%s", $0; next }
		grab { exit }
	' "$WORKFLOW" | tr -s ' '
}

@test "reusable-test-rust-build: concurrency group starts with a stable callee prefix" {
	run _group
	assert_success
	assert_output --regexp '^ ?lgtm-ci-rust-build-'
}

@test "reusable-test-rust-build: concurrency group includes caller repository, workflow and ref" {
	run _group
	assert_success
	assert_output --partial '${{ github.repository }}'
	assert_output --partial '${{ github.workflow }}'
	assert_output --partial '${{ github.ref }}'
}

@test "reusable-test-rust-build: concurrency group is never a bare ref expression" {
	run grep -E 'group: *rust-build-\$\{\{ github\.ref(_name)? \}\} *$' "$WORKFLOW"
	assert_failure
	run _group
	refute_output --regexp '^ ?\$\{\{ github\.ref'
}

@test "reusable-test-rust-build: concurrency group never uses github.job" {
	# Comments may name it; expressions may not.
	run bash -c "grep -vE '^[[:space:]]*#' '$WORKFLOW' | grep -F 'github.job'"
	assert_failure
}

@test "reusable-test-rust-build: concurrency-scope input is optional and ends the group" {
	run awk '/^      concurrency-scope:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'required: false'
	assert_output --partial 'type: string'
	assert_output --partial 'default: ""'
	run _group
	assert_output --regexp "\\$\\{\\{ inputs\\.concurrency-scope \\|\\| 'default' \\}\\}$"
}

@test "reusable-rust-build wrapper: exposes and forwards concurrency-scope" {
	local wrapper="${PROJECT_ROOT}/.github/workflows/reusable-rust-build.yml"
	run awk '/^      concurrency-scope:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' "$wrapper"
	assert_success
	assert_output --partial 'default: ""'
	run grep -F 'concurrency-scope: ${{ inputs.concurrency-scope }}' "$wrapper"
	assert_success
}

@test "reusable-test-rust-build: cancel-in-progress stays enabled for the build job" {
	run awk '/^    concurrency:$/{show=1;next} show&&/^    [a-z]/ {exit} show{print}' "$WORKFLOW"
	assert_success
	assert_output --partial 'cancel-in-progress: true'
}
