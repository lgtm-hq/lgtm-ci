#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: rerun-on-infra-failure.sh never re-runs a superseded commit's run (#1706)
# Bats isolates each test environment, including exported configuration.
# shellcheck disable=SC2030,SC2031

load "../../../helpers/rerun_on_infra_failure"

NEW_HEAD="22b64afd0c1e2d3f4a5b6c7d8e9f00112233aabb"
SIGNATURE="The runner has received a shutdown signal"

# Re-run decision for one head-check fixture: run the script, then assert it
# re-ran ("rerun") or not ("no-rerun").
_expect() {
	run bash "$SCRIPT"
	assert_success
	if [[ "$1" == rerun ]]; then
		assert_equal "1" "$(_call_count "$RERUN_CALLS")"
	else
		assert_equal "0" "$(_call_count "$RERUN_CALLS")"
	fi
}

@test "rerun-on-infra-failure: a run for a superseded pull request commit is not re-run" {
	_mock_gh "$SIGNATURE"
	_ref_tip 0 "$NEW_HEAD"
	_expect no-rerun
	assert_output --partial "not re-running a superseded commit"
	assert_output --partial "::notice::Run ${RUN_ID} is for superseded commit ${RUN_HEAD_SHA:0:12}"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Superseded:"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "is now at \`${NEW_HEAD}\`"
}

@test "rerun-on-infra-failure: a run for the current pull request head is re-run" {
	_mock_gh "$SIGNATURE"
	_expect rerun
	assert_output --partial "is for the current commit of branch feat/x in lgtm-hq/Rustume"
	# A pull request's head is a branch by its event: no tag read.
	run grep -c "matching-refs" "$HEAD_CALLS"
	assert_output "0"
}

@test "rerun-on-infra-failure: the tip is read as a qualified branch in the head repository" {
	# A pull request from a fork: its head is the fork's branch.
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" pull_request "fix/a#b" "contributor/Rustume"
	_expect rerun
	run grep -F -- "-H Accept: application/vnd.github.sha repos/contributor/Rustume/commits/refs%2Fheads%2Ffix%2Fa%23b" "$HEAD_CALLS"
	assert_success
}

@test "rerun-on-infra-failure: a branch named like a commit is still read as a branch" {
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" pull_request deadbeef "lgtm-hq/Rustume"
	_ref_tip 1 '{"message":"No commit found for SHA: refs/heads/deadbeef"}'
	_expect no-rerun
	run grep -F -- "commits/refs%2Fheads%2Fdeadbeef" "$HEAD_CALLS"
	assert_success
	run grep -E -- "commits/deadbeef( |$)" "$HEAD_CALLS"
	assert_failure
}

@test "rerun-on-infra-failure: every branch-only event is compared with its branch tip" {
	local event
	for event in pull_request pull_request_target merge_group schedule; do
		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" main "lgtm-hq/Rustume"
		_ref_tip 0 "$NEW_HEAD"
		_expect no-rerun
		assert_output --partial "not re-running a superseded commit"

		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" main "lgtm-hq/Rustume"
		_expect rerun
	done
}

@test "rerun-on-infra-failure: push and workflow_dispatch runs on a branch are compared" {
	local event
	for event in push workflow_dispatch; do
		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" main "lgtm-hq/Rustume"
		_ref_tags 0 refs/tags/main-v1 refs/tags/mainline
		_ref_tip 0 "$NEW_HEAD"
		_expect no-rerun
		assert_output --partial "not re-running a superseded commit"
		run grep -F -- "repos/lgtm-hq/Rustume/git/matching-refs/tags/main" "$HEAD_CALLS"
		assert_success

		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" main "lgtm-hq/Rustume"
		_ref_tags 0 refs/tags/main-v1
		_expect rerun
	done
}

@test "rerun-on-infra-failure: a tag run is re-run while its tag names the run's commit" {
	local event
	for event in push workflow_dispatch; do
		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" v1.2.3 "lgtm-hq/Rustume"
		_ref_heads 0 refs/heads/v1.2.3-fix
		_ref_tags 0 refs/tags/v1.2.3 refs/tags/v1.2.30
		_expect rerun
		assert_output --partial "is for the current commit of tag v1.2.3"
		# The tag is read qualified, which peels an annotated tag to its commit.
		run grep -F -- "commits/refs%2Ftags%2Fv1.2.3" "$HEAD_CALLS"
		assert_success
		run grep -F -- "commits/refs%2Fheads%2F" "$HEAD_CALLS"
		assert_failure
	done
}

@test "rerun-on-infra-failure: an annotated tag counts by the commit it names" {
	# The stub answers what the commits endpoint answers for refs/tags/<name>:
	# the peeled commit (lgtm-ci's annotated v0.113.0 resolves to 06d61548, not
	# to its tag object b051cd24).
	_mock_gh "$SIGNATURE"
	_run_head 0 "06d61548ca355498a8f635db33a6f00df40d9088" push v0.113.0 "lgtm-hq/Rustume"
	_ref_heads 0
	_ref_tags 0 refs/tags/v0.113.0
	_ref_tip 0 "06d61548ca355498a8f635db33a6f00df40d9088"
	_expect rerun
	# A tag object SHA is never what the run ran on.
	_mock_gh "$SIGNATURE"
	_run_head 0 "06d61548ca355498a8f635db33a6f00df40d9088" push v0.113.0 "lgtm-hq/Rustume"
	_ref_heads 0
	_ref_tags 0 refs/tags/v0.113.0
	_ref_tip 0 "b051cd24defcc80c821a615d05d52d1be0e35fb9"
	_expect no-rerun
}

@test "rerun-on-infra-failure: a moved tag is not re-run" {
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push v1.2.3 "lgtm-hq/Rustume"
	_ref_heads 0
	_ref_tags 0 refs/tags/v1.2.3
	_ref_tip 0 "$NEW_HEAD"
	_expect no-rerun
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "tag \`v1.2.3\` (lgtm-hq/Rustume) is now at \`${NEW_HEAD}\`"
}

@test "rerun-on-infra-failure: a deleted tag, or no ref of that name at all, is not re-run" {
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push v1.2.3 "lgtm-hq/Rustume"
	_ref_heads 0 refs/heads/v1.2.3-fix
	_ref_tags 0 refs/tags/v1.2.30
	_expect no-rerun
	assert_output --partial "no branch or tag is named"
	assert_equal "0" "$(grep -c "/commits/" "$HEAD_CALLS")"
	# Listed a moment ago, gone when its commit is read.
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push v1.2.3 "lgtm-hq/Rustume"
	_ref_heads 0
	_ref_tags 0 refs/tags/v1.2.3
	_ref_tip 1 '{"message":"No commit found for SHA: refs/tags/v1.2.3"}'
	_expect no-rerun
	assert_output --partial "(deleted, unreadable or not a tag)"
}

@test "rerun-on-infra-failure: a branch and a tag with the same name are not re-run" {
	local event
	for event in push workflow_dispatch; do
		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" v4 "lgtm-hq/Rustume"
		_ref_heads 0 refs/heads/v4
		_ref_tags 0 refs/tags/v4
		_expect no-rerun
		assert_output --partial "a branch and a tag are both named"
		assert_equal "0" "$(grep -c "/commits/" "$HEAD_CALLS")"
	done
}

@test "rerun-on-infra-failure: a branches read that fails is not re-run" {
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push main "lgtm-hq/Rustume"
	_ref_heads 1
	_expect no-rerun
	assert_output --partial "reading the branches of lgtm-hq/Rustume failed"
}

@test "rerun-on-infra-failure: a deleted pull request branch is not re-run even when a tag has its name" {
	# Branch-only events read refs/heads/<name>; the tag is never read as it.
	local event
	for event in pull_request pull_request_target merge_group schedule; do
		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" v4 "lgtm-hq/Rustume"
		_ref_tags 0 refs/tags/v4
		_ref_tip 1 '{"message":"No commit found for SHA: refs/heads/v4"}'
		_expect no-rerun
		assert_output --partial "deleted, unreadable or not a branch"
		assert_equal "0" "$(grep -c "matching-refs" "$HEAD_CALLS")"
	done
	# A finished merge-queue entry: its queue branch is gone.
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" merge_group gh-readonly-queue/main/pr-7-abc "lgtm-hq/Rustume"
	_ref_tip 1 '{"message":"No commit found"}'
	_expect no-rerun
}

@test "rerun-on-infra-failure: a deleted pushed branch with a same-named tag counts as a tag run" {
	# Re-run only while the tag names the run's own commit: with no branch
	# there is no newer run in the branch's group to cancel.
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push v4 "lgtm-hq/Rustume"
	_ref_heads 0
	_ref_tags 0 refs/tags/v4
	_expect rerun
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push v4 "lgtm-hq/Rustume"
	_ref_heads 0
	_ref_tags 0 refs/tags/v4
	_ref_tip 0 "$NEW_HEAD"
	_expect no-rerun
}

@test "rerun-on-infra-failure: a tags read that fails is not re-run" {
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push main "lgtm-hq/Rustume"
	_ref_tags 1
	_expect no-rerun
	assert_output --partial "could not tell whether push run ${RUN_ID} ran on a branch or a tag"
}

@test "rerun-on-infra-failure: an empty, missing or unhandled event is not re-run" {
	local event
	for event in "" release workflow_run repository_dispatch "pull request" "PUSH"; do
		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" "$event" main "lgtm-hq/Rustume"
		_expect no-rerun
		assert_equal "0" "$(grep -c "/commits/" "$HEAD_CALLS")"
	done
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive:"
}

@test "rerun-on-infra-failure: an empty run payload is not re-run" {
	# `{}` from the API: every field empty.
	_mock_gh "$SIGNATURE"
	printf '\037\037\037\037' >"${PROBE_DIR}/run.head"
	_expect no-rerun
	assert_output --partial "does not name a commit, event, branch and repository"
	assert_equal "0" "$(grep -c "/commits/" "$HEAD_CALLS")"
}

@test "rerun-on-infra-failure: a run head that cannot be read is not re-run" {
	_mock_gh "$SIGNATURE"
	_run_head 1 "" "" "" ""
	_expect no-rerun
	assert_output --partial "Could not tell whether run ${RUN_ID} is for the current head"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "Inconclusive:"
}

@test "rerun-on-infra-failure: a ref tip that cannot be read is not re-run" {
	# A deleted branch, or a fork the token cannot read.
	_mock_gh "$SIGNATURE"
	_ref_tip 1 '{"message":"No commit found for SHA: refs/heads/feat/x"}'
	_expect no-rerun
	assert_output --partial "exited 1 (deleted, unreadable or not a branch)"
}

@test "rerun-on-infra-failure: a malformed head, repository or tip is not re-run" {
	_mock_gh "$SIGNATURE"
	_run_head 0 "not-a-sha" pull_request feat/x "lgtm-hq/Rustume"
	_expect no-rerun
	assert_output --partial "does not name a commit, event, branch and repository"

	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" pull_request "" "lgtm-hq/Rustume"
	_expect no-rerun

	local repo
	for repo in "../evil" "owner/.." "owner/." ""; do
		_mock_gh "$SIGNATURE"
		_run_head 0 "$RUN_HEAD_SHA" pull_request feat/x "$repo"
		_expect no-rerun
		assert_equal "0" "$(grep -c "/commits/" "$HEAD_CALLS")"
	done

	_mock_gh "$SIGNATURE"
	_ref_tip 0 "<html>rate limited</html>"
	_expect no-rerun
	assert_output --partial "does not resolve to a commit SHA"
}

@test "rerun-on-infra-failure: the head reads have their own short timeout" {
	export TIMEOUT_CALLS="${BATS_TEST_TMPDIR}/timeout_calls"
	: >"$TIMEOUT_CALLS"
	export GH_CMD_TIMEOUT="42" HEAD_CMD_TIMEOUT="7"
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" push main "lgtm-hq/Rustume"
	_expect rerun
	# Run, branches, tags and tip under HEAD_CMD_TIMEOUT; nothing under 42.
	run grep -c -- " 7 gh api" "$TIMEOUT_CALLS"
	assert_output "4"
	run grep -c -- "42 gh api .*head_sha\|42 gh api .*commits/\|42 gh api .*matching-refs" "$TIMEOUT_CALLS"
	assert_output "0"
}

@test "rerun-on-infra-failure: HEAD_CMD_TIMEOUT must be a positive integer" {
	local bad
	for bad in 0 soon -1; do
		export HEAD_CMD_TIMEOUT="$bad"
		_mock_gh "$SIGNATURE"
		run bash "$SCRIPT"
		assert_failure
		assert_output --partial "::error::HEAD_CMD_TIMEOUT must be a positive integer (got '${bad}')"
		[ ! -s "$RERUN_CALLS" ]
	done
}

@test "rerun-on-infra-failure: a branch name with backticks cannot break the summary" {
	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" pull_request 'a`b``c' "lgtm-hq/Rustume"
	_ref_tip 0 "$NEW_HEAD"
	_expect no-rerun
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" 'branch ```a`b``c``` (lgtm-hq/Rustume)'

	_mock_gh "$SIGNATURE"
	_run_head 0 "$RUN_HEAD_SHA" pull_request '`edge`' "lgtm-hq/Rustume"
	_ref_tip 0 "$NEW_HEAD"
	_expect no-rerun
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" 'branch `` `edge` `` (lgtm-hq/Rustume)'
}

@test "rerun-on-infra-failure: the head check also gates the runner-acquisition rule" {
	_mock_gh_attempts "0:"
	_mock_sleep
	export LOG_FETCH_ATTEMPTS="1" LOG_PROBE_MAX_JOBS="0"
	_failed_jobs 0 "$(printf '41\tbuild\t0')"
	_job_annotations 41 0 "The job repeatedly failed to be acquired (5 attempts)"
	_ref_tip 0 "$NEW_HEAD"
	_expect no-rerun
	assert_output --partial "not re-running a superseded commit"
}

@test "rerun-on-infra-failure: no head is read when no signature matched" {
	_mock_gh "assertion failed: expected 200 got 500"
	_expect no-rerun
	assert_output --partial "No infra signature matched"
	assert_equal "0" "$(_call_count "$HEAD_CALLS")"
}
