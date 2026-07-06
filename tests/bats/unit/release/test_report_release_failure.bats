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
	assert_output --partial "Created release failure issue: https://github.com/lgtm-hq/lgtm-ci/issues/42"
	run grep -F 'in:title' "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
	run grep -F 'release-automation-failure:release-version-pr:main' "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
}

@test "report-release-failure: notify_failure deduplicates by issue title" {
	mock_command_multi "gh" '
		*repo*view*) echo "main";;
		*in:title*) echo "77";;
		*issue*comment*) echo "commented";;
		*run*view*) exit 0;;
		*) exit 1;;
	'

	run bash "$SCRIPT" notify_failure
	assert_success
	assert_output --partial "Updated release failure issue #77"
}

@test "report-release-failure: notify_failure includes visible tracking key in issue body" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
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
		while [[ \$# -gt 0 ]]; do
			if [[ "\$1" == "--body-file" && -n "\${2:-}" ]]; then
				cp "\$2" '${BATS_TEST_TMPDIR}/issue-body.md'
			fi
			shift
		done
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
	[[ -f "${BATS_TEST_TMPDIR}/issue-body.md" ]]
	run grep -F "**Tracking key:** \`release-automation-failure:release-version-pr:main\`" \
		"${BATS_TEST_TMPDIR}/issue-body.md"
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

@test "report-release-failure: notify_failure ignores gh stderr warnings on issue search" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	*repo*view*)
		echo "main"
		;;
	*issue*list*)
		echo "Warning: rate limit approaching" >&2
		echo "77"
		exit 0
		;;
	*issue*comment*)
		echo "commented"
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
	assert_output --partial "Updated release failure issue #77"
	refute_output --partial "Warning:"
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
	assert_output --partial "Created release failure issue: https://github.com/lgtm-hq/lgtm-ci/issues/55"
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
	assert_output --partial "Created release failure issue: https://github.com/lgtm-hq/lgtm-ci/issues/88"
}

@test "report-release-failure: notify_failure falls back when title search fails" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	*repo*view*)
		echo "main"
		;;
	*in:title*)
		echo "title search rejected" >&2
		exit 1
		;;
	*issue*list*)
		echo "88"
		exit 0
		;;
	*issue*comment*)
		echo "commented"
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
	assert_output --partial "Title search unavailable; falling back to tracking key"
	assert_output --partial "Updated release failure issue #88"
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

@test "report-release-failure: WORKFLOW_KEY takes precedence over RELEASE_WORKFLOW_KEY" {
	export WORKFLOW_KEY=docker-publish

	run bash "$SCRIPT" write_trigger_summary
	assert_success
	run grep -F "docker-publish" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "report-release-failure: WORKFLOW_KEY alone satisfies the key requirement" {
	unset RELEASE_WORKFLOW_KEY
	export WORKFLOW_KEY=pages-deploy

	run bash "$SCRIPT" write_trigger_summary
	assert_success
	run grep -F "pages-deploy" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "report-release-failure: reports missing WORKFLOW_KEY and RELEASE_WORKFLOW_KEY" {
	unset RELEASE_WORKFLOW_KEY

	# The :? expansion fires inside command substitutions, so the message is
	# surfaced in output (matching the script's historical behavior).
	run bash "$SCRIPT" write_trigger_summary
	assert_output --partial "WORKFLOW_KEY (or RELEASE_WORKFLOW_KEY) is required"
}

@test "report-release-failure: FAILURE_HEADING_LABEL customizes summary heading" {
	export FAILURE_HEADING_LABEL="Main Workflow"
	export PRIMARY_JOB_FAILED=true

	run bash "$SCRIPT" write_trigger_summary
	assert_success
	run grep -F "## Main Workflow Failure" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "report-release-failure: custom marker and title prefixes namespace the issue" {
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
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/43"
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
	export WORKFLOW_KEY=docker-publish
	export FAILURE_MARKER_PREFIX=main-workflow-failure
	export FAILURE_TITLE_PREFIX="fix(ci): main workflow failed:"

	run bash "$SCRIPT" notify_failure
	assert_success
	run grep -F 'main-workflow-failure:docker-publish:main' \
		"${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
	run grep -F 'fix(ci): main workflow failed: main (docker-publish)' \
		"${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
}

@test "report-release-failure: FAILURE_SUMMARY_TEXT overrides the issue summary" {
	mock_command_multi "gh" '
		*repo*view*) echo "main";;
		*issue*list*) echo "";;
		*label*view*) exit 0;;
		*issue*create*) echo "https://github.com/lgtm-hq/lgtm-ci/issues/44"; exit 0;;
		*run*view*) exit 0;;
		*) exit 1;;
	'
	export FAILURE_SUMMARY_TEXT="Custom failure summary sentence."

	run bash "$SCRIPT" notify_failure
	assert_success
}
