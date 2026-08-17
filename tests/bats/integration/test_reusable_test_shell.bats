#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-shell coverage-run timeout (#556)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-shell.yml"

@test "reusable-test-shell: coverage-run step has timeout-minutes below job default" {
	run awk '
		/^      - name: Run BATS tests with coverage/ { in_step = 1 }
		in_step && /^      - name:/ && !/^      - name: Run BATS tests with coverage/ { in_step = 0 }
		in_step && /^        id: coverage-run/ { saw_id = 1 }
		in_step && /^        timeout-minutes: 45/ { saw_timeout = 1 }
		END { exit !(saw_id && saw_timeout) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: job timeout-minutes defaults to 60" {
	run awk '/^      timeout-minutes:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: 60'
}

@test "reusable-test-shell: coverage-shards defaults to 1" {
	run awk '
		/^      coverage-shards:$/ { in_input = 1 }
		in_input && /^        default: 1$/ { found = 1 }
		in_input && /^      [a-z].*:$/ && !/^      coverage-shards:$/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: aggregate job name equals inputs.job-name" {
	run awk '
		/^  aggregate:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_job = 0 }
		in_job && $0 == "    name: ${{ inputs.job-name }}" { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: shard artifact names include comment-marker" {
	run grep -F 'name: shell-test-results-${{ inputs.comment-marker }}-shard-${{ matrix.shard }}' "$WORKFLOW"
	assert_success
	run grep -F 'name: shell-coverage-${{ inputs.comment-marker }}-shard-${{ matrix.shard }}' "$WORKFLOW"
	assert_success
	run grep -F 'pattern: shell-test-results-${{ inputs.comment-marker }}-shard-*' "$WORKFLOW"
	assert_success
	run grep -F 'pattern: shell-coverage-${{ inputs.comment-marker }}-shard-*' "$WORKFLOW"
	assert_success
	# Default single-job path keeps unsuffixed names.
	run grep -E '^          name: shell-test-results$' "$WORKFLOW"
	assert_success
	run grep -E '^          name: shell-coverage$' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: publish-test-summary needs test and aggregate" {
	run awk '
		/^  publish-test-summary:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ { in_job = 0 }
		in_job && /needs: \[test, aggregate\]/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: shard coverage-run timeout-minutes is 20" {
	run awk '
		/^  test-sharded:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test-sharded:/ { in_job = 0 }
		in_job && /^      - name: Run BATS tests with coverage/ { in_step = 1 }
		in_job && in_step && /^      - name:/ && !/^      - name: Run BATS tests with coverage/ {
			in_step = 0
		}
		in_step && /^        timeout-minutes: 20/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: aggregate uploads merged coverage as shell-coverage" {
	run awk '
		/^  aggregate:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_job = 0 }
		in_job && /^      - name: Upload merged coverage report/ { in_step = 1 }
		in_job && in_step && /^      - name:/ && !/^      - name: Upload merged coverage report/ {
			in_step = 0
		}
		in_step && /name: shell-coverage$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-shell: ci.yml opts in with coverage-shards 4" {
	run awk '
		/^  shell-tests:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  shell-tests:/ { in_job = 0 }
		in_job && /coverage-shards: 4/ { found = 1 }
		END { exit !found }
	' "${PROJECT_ROOT}/.github/workflows/ci.yml"
	assert_success
}
