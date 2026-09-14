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
	# The classifier's bounded log fetch retries empty fetches until
	# LOG_FETCH_DEADLINE; keep unit tests to a single attempt.
	export GH_CMD_TIMEOUT=5
	export LOG_FETCH_DEADLINE=1
	export LOG_FETCH_RETRY_DELAY=0
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

@test "report-release-failure: fails without WORKFLOW_KEY or RELEASE_WORKFLOW_KEY" {
	unset RELEASE_WORKFLOW_KEY

	run bash "$SCRIPT" write_trigger_summary
	assert_failure
	assert_output --partial "WORKFLOW_KEY (or RELEASE_WORKFLOW_KEY) is required"
}

@test "report-release-failure: notify_failure fails without a workflow key" {
	unset RELEASE_WORKFLOW_KEY
	mock_command_multi "gh" '
		*) exit 1;;
	'

	run bash "$SCRIPT" notify_failure
	assert_failure
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
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/44"
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
	export FAILURE_SUMMARY_TEXT="Custom failure summary sentence."

	run bash "$SCRIPT" notify_failure
	assert_success
	[[ -f "${BATS_TEST_TMPDIR}/issue-body.md" ]]
	run grep -F "Custom failure summary sentence." "${BATS_TEST_TMPDIR}/issue-body.md"
	assert_success
}

# =============================================================================
# Release mode (#964): tag publishes deduplicate by tag, bypass the branch
# gate, render the channel table, and pair file-on-failure with
# close-on-success under the same key.
# =============================================================================

@test "report-release-failure: notify_release_failure bypasses the branch gate and creates the tag issue" {
	export WORKFLOW_KEY=publish-python-release
	export RELEASE_TAG=v1.2.3
	# A tag ref: the branch gate of notify_failure would skip this run entirely.
	export GITHUB_REF_NAME=v1.2.3
	export GITHUB_RUN_ATTEMPT=2
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_gh'
case "\$*" in
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
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/64"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
	export CHANNELS_JSON='[{"name":"pypi","result":"success","probe":"published"},{"name":"npm","result":"failure","url":"https://github.com/lgtm-hq/lgtm-ci/actions/runs/9/job/8"}]'

	run bash "$SCRIPT" notify_release_failure
	assert_success
	assert_output --partial "Created release failure issue: https://github.com/lgtm-hq/lgtm-ci/issues/64"
	run grep -F 'release-failure:publish-python-release:v1.2.3' "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
	run grep -F 'fix(release): tag publish failed: v1.2.3 (publish-python-release)' \
		"${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
	[[ -f "${BATS_TEST_TMPDIR}/issue-body.md" ]]
	run grep -F '**Tracking key:** `release-failure:publish-python-release:v1.2.3`' \
		"${BATS_TEST_TMPDIR}/issue-body.md"
	assert_success
	run grep -F '**Tag:** v1.2.3' "${BATS_TEST_TMPDIR}/issue-body.md"
	assert_success
	run grep -F '| pypi | success | [run](https://github.com/lgtm-hq/lgtm-ci/actions/runs/12345) | published |' "${BATS_TEST_TMPDIR}/issue-body.md"
	assert_success
	run grep -F '| npm | failure | [job](https://github.com/lgtm-hq/lgtm-ci/actions/runs/9/job/8) | — |' \
		"${BATS_TEST_TMPDIR}/issue-body.md"
	assert_success
}

@test "report-release-failure: notify_release_failure accepts toJson(needs) object shape" {
	export WORKFLOW_KEY=publish-python-release
	export RELEASE_TAG=v1.2.3
	export GITHUB_REF_NAME=v1.2.3
	mock_command_multi "gh" '
		*issue*list*) echo "";;
		*label*view*) exit 0;;
		*issue*create*)
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == "--body-file" && -n "${2:-}" ]]; then
					cp "$2" "'"${BATS_TEST_TMPDIR}"'/issue-body.md"
				fi
				shift
			done
			echo "https://github.com/lgtm-hq/lgtm-ci/issues/65";;
		*) exit 1;;
	'
	export CHANNELS_JSON='{"pypi":{"result":"success"},"npm":{"result":"failure"}}'

	run bash "$SCRIPT" notify_release_failure
	assert_success
	run grep -F '| pypi | success | [run](https://github.com/lgtm-hq/lgtm-ci/actions/runs/12345) | — |' "${BATS_TEST_TMPDIR}/issue-body.md"
	assert_success
	run grep -F '| npm | failure | [run](https://github.com/lgtm-hq/lgtm-ci/actions/runs/12345) | — |' "${BATS_TEST_TMPDIR}/issue-body.md"
	assert_success
}

@test "report-release-failure: notify_release_failure comments on the existing tag issue" {
	export WORKFLOW_KEY=publish-python-release
	export RELEASE_TAG=v1.2.3
	export GITHUB_REF_NAME=v1.2.3
	mock_command_multi "gh" '
		*issue*list*) echo "77";;
		*issue*comment*) echo "commented";;
		*) exit 1;;
	'

	run bash "$SCRIPT" notify_release_failure
	assert_success
	assert_output --partial "Updated release failure issue #77"
}

@test "report-release-failure: notify_release_failure requires RELEASE_TAG" {
	export WORKFLOW_KEY=publish-python-release
	unset RELEASE_TAG

	run bash "$SCRIPT" notify_release_failure
	assert_failure
	assert_output --partial "RELEASE_TAG is required"
}

@test "report-release-failure: close_release_failure comments and closes the tag issue" {
	export WORKFLOW_KEY=publish-python-release
	export RELEASE_TAG=v1.2.3
	export GITHUB_REF_NAME=v1.2.3
	mock_command_multi "gh" '
		*issue*list*) echo "77";;
		*issue*close*) echo "closed";;
		*) exit 1;;
	'

	run bash "$SCRIPT" close_release_failure
	assert_success
	assert_output --partial "Closed release failure issue #77"
}

@test "report-release-failure: close_release_failure is a no-op without an open issue" {
	export WORKFLOW_KEY=publish-python-release
	export RELEASE_TAG=v1.2.3
	export GITHUB_REF_NAME=v1.2.3
	mock_command_multi "gh" '
		*issue*list*) echo "";;
		*) exit 1;;
	'

	run bash "$SCRIPT" close_release_failure
	assert_success
	assert_output --partial "No open release-failure issue for tag 'v1.2.3'"
}

@test "report-release-failure: close_release_failure survives a search API failure" {
	export WORKFLOW_KEY=publish-python-release
	export RELEASE_TAG=v1.2.3
	export GITHUB_REF_NAME=v1.2.3
	mock_command_multi "gh" '
		*issue*list*) echo "API rate limit exceeded" >&2; exit 1;;
		*) exit 1;;
	'

	# The close job runs on a green publish run; a search hiccup must not redden it.
	run bash "$SCRIPT" close_release_failure
	assert_success
	assert_output --partial "leaving it open"
}

@test "report-release-failure: classify returns success when every channel succeeded" {
	export CHANNELS_JSON='[{"name":"pypi","result":"success"},{"name":"github-release","result":"success"}]'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	mock_command_multi "gh" '*) exit 1;;'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "success"
}

@test "report-release-failure: classify treats skipped channels as succeeded" {
	export CHANNELS_JSON='{"pypi":{"result":"success"},"sbom":{"result":"skipped"}}'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	mock_command_multi "gh" '*) exit 1;;'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "success"
}

@test "report-release-failure: classify never calls an empty channel list a success" {
	export CHANNELS_JSON='[]'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	mock_command_multi "gh" '*) exit 1;;'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "failure"
}

@test "report-release-failure: classify files when the channels payload is invalid JSON" {
	export CHANNELS_JSON='not-json-at-all'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	mock_command_multi "gh" '*) exit 1;;'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "failure"
}

@test "report-release-failure: classify files once the attempt exceeds max-reruns" {
	export CHANNELS_JSON='{"npm":{"result":"failure"}}'
	export RUN_ATTEMPT=2
	export MAX_RERUNS=1
	# Even a matching signature must not suppress the final attempt's report.
	mock_command_multi "gh" '
		*--log-failed*) echo "The runner has received a shutdown signal";;
		*) exit 1;;
	'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "failure"
}

@test "report-release-failure: classify stays quiet while an infra rerun may be in flight" {
	export CHANNELS_JSON='{"npm":{"result":"failure"}}'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	mock_command_multi "gh" '
		*--log-failed*) echo "error: lost communication with the server";;
		*) exit 1;;
	'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "rerunning"
}

@test "report-release-failure: classify writes the verdict to GITHUB_OUTPUT" {
	export CHANNELS_JSON='{"npm":{"result":"failure"}}'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	local output_file="${BATS_TEST_TMPDIR}/github-output"
	export GITHUB_OUTPUT="$output_file"
	mock_command_multi "gh" '
		*--log-failed*) echo "error: lost communication with the server";;
		*) exit 1;;
	'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	run grep -F "verdict=rerunning" "$output_file"
	assert_success
}

@test "report-release-failure: classify files when the failure does not match an infra signature" {
	export CHANNELS_JSON='{"npm":{"result":"failure"}}'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	mock_command_multi "gh" '
		*--log-failed*) echo "403 Forbidden: npm publish rejected the token";;
		*) exit 1;;
	'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "failure"
}

@test "report-release-failure: classify files when the failed-job logs are unavailable" {
	# Inconclusive is not quiet: a visible duplicate costs less than silence.
	export CHANNELS_JSON='{"npm":{"result":"failure"}}'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	mock_command_multi "gh" '
		*--log-failed*) exit 1;;
		*) exit 1;;
	'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "failure"
}

@test "report-release-failure: classify honors INFRA_SIGNATURES extensions" {
	export CHANNELS_JSON='{"npm":{"result":"failure"}}'
	export RUN_ATTEMPT=1
	export MAX_RERUNS=1
	export INFRA_SIGNATURES=$'my-custom-registry-flake'
	mock_command_multi "gh" '
		*--log-failed*) echo "upstream error: my-custom-registry-flake retry me";;
		*) exit 1;;
	'

	run bash -c "bash \"$SCRIPT\" classify_release_failure 2>/dev/null"
	assert_success
	assert_output "rerunning"
}
