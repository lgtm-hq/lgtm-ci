#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: rerun-on-infra-failure.sh never re-runs a superseded commit's run (#1706)
# Bats isolates each test environment, including exported configuration.
# shellcheck disable=SC2030,SC2031

load "../../../helpers/rerun_on_infra_failure"

NEW_HEAD="22b64afd0c1e2d3f4a5b6c7d8e9f00112233aabb"

@test "rerun-on-infra-failure: a run for a superseded pull request commit is not re-run" {
	_mock_gh "The runner has received a shutdown signal"
	_ref_tip 0 "$NEW_HEAD"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not re-running a superseded commit"
	assert_output --partial "::notice::Run ${RUN_ID} is for superseded commit ${RUN_HEAD_SHA:0:12}"
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Superseded:"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "is now at \`${NEW_HEAD}\`"
}

@test "rerun-on-infra-failure: a run for the current pull request head is re-run" {
	_mock_gh "The runner has received a shutdown signal"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "is for the current head of lgtm-hq/Rustume feat/x"
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: the tip is read from the head repository and an encoded ref" {
	# A pull request from a fork: its head is the fork's branch.
	_mock_gh "The runner has received a shutdown signal"
	_run_head 0 "$RUN_HEAD_SHA" pull_request "fix/a#b" "contributor/Rustume"
	run bash "$SCRIPT"
	assert_success
	run grep -F -- "-H Accept: application/vnd.github.sha repos/contributor/Rustume/commits/fix%2Fa%23b" "$HEAD_CALLS"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: a push run is compared with the branch tip" {
	_mock_gh "The runner has received a shutdown signal"
	_run_head 0 "$RUN_HEAD_SHA" push main "lgtm-hq/Rustume"
	_ref_tip 0 "$NEW_HEAD"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not re-running a superseded commit"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: pull_request_target runs are compared too" {
	_mock_gh "The runner has received a shutdown signal"
	_run_head 0 "$RUN_HEAD_SHA" pull_request_target feat/x "lgtm-hq/Rustume"
	_ref_tip 0 "$NEW_HEAD"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: events without a moving head are not compared" {
	local event
	for event in schedule workflow_dispatch merge_group; do
		_mock_gh "The runner has received a shutdown signal"
		_run_head 0 "$RUN_HEAD_SHA" "$event" main "lgtm-hq/Rustume"
		_ref_tip 0 "$NEW_HEAD"
		run bash "$SCRIPT"
		assert_success
		assert_output --partial "has no head to be superseded by"
		assert_equal "1" "$(_call_count "$RERUN_CALLS")"
		run grep -c "/commits/" "$HEAD_CALLS"
		assert_output "0"
	done
}

@test "rerun-on-infra-failure: a run head that cannot be read is not re-run" {
	_mock_gh "The runner has received a shutdown signal"
	_run_head 1 "" "" "" ""
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Could not tell whether run ${RUN_ID} is for the current head"
	[ ! -s "$RERUN_CALLS" ]
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive:"
}

@test "rerun-on-infra-failure: a ref tip that cannot be read is not re-run" {
	# A deleted branch, or a fork the token cannot read.
	_mock_gh "The runner has received a shutdown signal"
	_ref_tip 1 '{"message":"No commit found for SHA: feat/x"}'
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "exited 1; not re-running"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: a malformed head or tip is not re-run" {
	_mock_gh "The runner has received a shutdown signal"
	_run_head 0 "not-a-sha" pull_request feat/x "lgtm-hq/Rustume"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "does not name a commit, ref and repository"
	[ ! -s "$RERUN_CALLS" ]

	_mock_gh "The runner has received a shutdown signal"
	_run_head 0 "$RUN_HEAD_SHA" pull_request "" "lgtm-hq/Rustume"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "does not name a commit, ref and repository"
	[ ! -s "$RERUN_CALLS" ]

	local repo
	for repo in "../evil" "owner/.." "owner/."; do
		_mock_gh "The runner has received a shutdown signal"
		_run_head 0 "$RUN_HEAD_SHA" pull_request feat/x "$repo"
		run bash "$SCRIPT"
		assert_success
		[ ! -s "$RERUN_CALLS" ]
		assert_equal "0" "$(grep -c "/commits/" "$HEAD_CALLS")"
	done

	_mock_gh "The runner has received a shutdown signal"
	_ref_tip 0 "<html>rate limited</html>"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "is not a commit SHA"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: the head check also gates the runner-acquisition rule" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1" LOG_PROBE_MAX_JOBS="0"
	_failed_jobs 0 "$(printf '41\tbuild\t0')"
	_job_annotations 41 0 "The job repeatedly failed to be acquired (5 attempts)"
	_ref_tip 0 "$NEW_HEAD"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not re-running a superseded commit"
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: no head is read when no signature matched" {
	_mock_gh "assertion failed: expected 200 got 500"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No infra signature matched"
	assert_equal "0" "$(_call_count "$HEAD_CALLS")"
}
