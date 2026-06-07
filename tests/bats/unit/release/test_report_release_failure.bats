#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/report-release-failure.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/report-release-failure.sh"

setup() {
	setup_temp_dir
	save_path
	export PROJECT_ROOT
	export SCRIPT
	export GH_TOKEN=test-token
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export GITHUB_RUN_ID=12345
	export GITHUB_SHA=abc123def456
	export GITHUB_REF_NAME=main
	export GITHUB_EVENT_NAME=push
	export GITHUB_WORKFLOW="Release Version PR"
	export GITHUB_ACTOR=test-actor
	export GITHUB_SERVER_URL=https://github.com
	export RELEASE_WORKFLOW_KEY=release-version-pr
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/step-summary.md"
	: >"$GITHUB_STEP_SUMMARY"
}

teardown() {
	restore_path
	teardown_temp_dir
}

@test "report-release-failure: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}

@test "report-release-failure: write_trigger_summary records push context" {
	run bash "$SCRIPT" write_trigger_summary
	assert_success
	[[ -f "$GITHUB_STEP_SUMMARY" ]]
	run grep -F "## Release Automation Context" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "release-version-pr" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "**Branch:** main" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "abc123def456" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "report-release-failure: write_trigger_summary records workflow_run upstream context" {
	export GITHUB_EVENT_NAME=workflow_run
	export UPSTREAM_WORKFLOW_NAME="CI"
	export UPSTREAM_RUN_ID=999
	export UPSTREAM_CONCLUSION=success
	export UPSTREAM_HEAD_BRANCH=main
	export UPSTREAM_HEAD_SHA=deadbeef

	run bash "$SCRIPT" write_trigger_summary
	assert_success
	run grep -F "### Upstream Workflow" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "**Workflow:** CI" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "**Run ID:** 999" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "report-release-failure: write_trigger_summary uses failure heading when primary job failed" {
	export PRIMARY_JOB_FAILED=true

	run bash "$SCRIPT" write_trigger_summary
	assert_success
	run grep -F "## Release Automation Failure" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "report-release-failure: notify_failure creates issue when none exists" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_gh'
case "\$*" in
	*repo*view*)
		echo "main"
		;;
	*issue*list*)
		echo ""
		;;
	*label*view*)
		exit 0
		;;
	*issue*create*)
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/42"
		exit 0
		;;
	*run*view*)
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

	run bash "$SCRIPT" notify_failure
	assert_success
	assert_output --partial "Created release failure issue"
	run grep -F 'release-automation-failure:release-version-pr:main' "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
}

@test "report-release-failure: notify_failure comments on existing issue" {
	mock_command_multi "gh" '
		*repo*view*) echo "main";;
		*issue*list*) echo "77";;
		*issue*comment*) echo "commented";;
		*run*view*) exit 0;;
		*) exit 1;;
	'

	run bash "$SCRIPT" notify_failure
	assert_success
	assert_output --partial "Updated release failure issue #77"
}

@test "report-release-failure: notify_failure skips non-target branch" {
	export GITHUB_REF_NAME=feature/test
	export FAILURE_TARGET_BRANCH=main

	run bash "$SCRIPT" notify_failure
	assert_success
	assert_output --partial "Release failure notification skipped for branch 'feature/test'"
}

@test "report-release-failure: notify_failure respects FAILURE_TARGET_BRANCH override" {
	export FAILURE_TARGET_BRANCH=develop
	export GITHUB_REF_NAME=develop

	mock_command_multi "gh" '
		*issue*list*) echo "";;
		*label*view*) exit 0;;
		*issue*create*) echo "https://github.com/lgtm-hq/lgtm-ci/issues/55";;
		*run*view*) exit 0;;
		*) exit 1;;
	'

	run bash "$SCRIPT" notify_failure
	assert_success
	assert_output --partial "Created release failure issue"
}

@test "report-release-failure: notify_failure skips missing labels" {
	mock_command_multi "gh" '
		*issue*list*) echo "";;
		*label*view*bug*) exit 0;;
		*label*view*) exit 1;;
		*issue*create*) echo "https://github.com/lgtm-hq/lgtm-ci/issues/88";;
		*run*view*) exit 0;;
		*) exit 1;;
	'

	run bash "$SCRIPT" notify_failure
	assert_success
	assert_output --partial "Skipping missing issue label"
	assert_output --partial "Created release failure issue"
}

@test "report-release-failure: notify_failure fails when issue search fails" {
	mock_command_multi "gh" '
		*issue*list*) echo "API rate limit exceeded" >&2; exit 1;;
		*run*view*) exit 0;;
		*) exit 1;;
	'

	run bash "$SCRIPT" notify_failure
	assert_failure
	assert_output --partial "Could not search for existing release failure issues"
}

@test "report-release-failure: notify_failure fails when GH_TOKEN is unset" {
	unset GH_TOKEN

	run bash "$SCRIPT" notify_failure
	assert_failure
	assert_output --partial "GH_TOKEN is required"
}
