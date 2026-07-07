#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for merge_group behavior in reusable workflows

load "../../helpers/common"

@test "reusable-dependency-review: runs on pull_request and merge_group" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-dependency-review.yml"

	run awk '
		/^[[:space:]]*if:/ {
			if ($0 ~ /github\.event_name/ && $0 ~ /pull_request/ && $0 ~ /merge_group/) {
				found = 1
				exit
			}
		}
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-semantic-pr-title: no-ops merge_group at step level" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-semantic-pr-title.yml"

	run grep -cE "if: github.event_name != 'merge_group'" "$workflow"
	assert_success
	[[ "$output" -ge 5 ]]
}

@test "reusable-semantic-pr-title: job itself must not skip on merge_group" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-semantic-pr-title.yml"

	# A skipped job with a dynamic name reports its check as
	# "inputs.job-name", so the required context never arrives and merge
	# queue entries time out. The skip must live on the steps, not the job.
	run awk '
		/^  semantic-title:/ { in_job = 1; next }
		in_job && /^    steps:/ { exit }
		in_job && /if: github.event_name != ..merge_group./ { bad = 1; exit }
		END { exit bad }
	' "$workflow"
	assert_success
}
