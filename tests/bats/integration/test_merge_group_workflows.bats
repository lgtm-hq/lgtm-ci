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

@test "reusable-semantic-pr-title: skips merge_group events" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-semantic-pr-title.yml"

	run grep -E "if: github.event_name != 'merge_group'" "$workflow"
	assert_success
}
