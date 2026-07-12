#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/check-version-pr-merge-queue.sh (#528)

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export GH_TOKEN="fake-token"
	export REPO="lgtm-hq/lgtm-ci"
	export GITHUB_REPOSITORY="lgtm-hq/lgtm-ci"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

run_mq_check() {
	run bash -c "
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export GH_TOKEN='${GH_TOKEN}'
		export REPO='${REPO}'
		export PR_NUMBER='${PR_NUMBER:-}'
		export BRANCH='${BRANCH:-}'
		export PATH='$PATH'
		'$PROJECT_ROOT/scripts/ci/release/check-version-pr-merge-queue.sh' 2>&1
	"
}

@test "check-version-pr-merge-queue: queued PR emits skip signal" {
	export PR_NUMBER="42"
	mock_command_multi "gh" '
		*graphql*) printf "%s\n" "{\"data\":{\"repository\":{\"pullRequest\":{\"number\":42,\"mergeQueueEntry\":{\"position\":1,\"state\":\"QUEUED\"}}}}}";;
		*) exit 1;;
	'

	run_mq_check
	assert_success
	assert_line --partial "queued=true"
	assert_line --partial "skip-branch-update=true"
	assert_line --partial "reason=queued"
	assert_line --partial "pr-number=42"
}

@test "check-version-pr-merge-queue: not-queued PR proceeds" {
	export PR_NUMBER="42"
	mock_command_multi "gh" '
		*graphql*) printf "%s\n" "{\"data\":{\"repository\":{\"pullRequest\":{\"number\":42,\"mergeQueueEntry\":null}}}}";;
		*) exit 1;;
	'

	run_mq_check
	assert_success
	assert_line --partial "queued=false"
	assert_line --partial "skip-branch-update=false"
	assert_line --partial "reason=not-queued"
}

@test "check-version-pr-merge-queue: API error skips update" {
	export PR_NUMBER="42"
	mock_command_multi "gh" '
		*graphql*) exit 1;;
		*) exit 1;;
	'

	run_mq_check
	assert_success
	assert_line --partial "queued=unknown"
	assert_line --partial "skip-branch-update=true"
	assert_line --partial "reason=api-error"
}

@test "check-version-pr-merge-queue: no PR found proceeds" {
	unset PR_NUMBER || true
	export BRANCH="release/v1.2.3"
	mock_command_multi "gh" '
		*pr*list*) printf "%s\n" "";;
		*) exit 1;;
	'

	run_mq_check
	assert_success
	assert_line --partial "queued=false"
	assert_line --partial "skip-branch-update=false"
	assert_line --partial "reason=no-pr"
}
