#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/lib/github/tracking_issue.sh (#1548)
#
# The open/update/close paths run end to end in
# tests/bats/integration/test_results_hosts_drift.bats and
# test_egress_dns_check.bats; these cover the guards.

load "../../../../helpers/common"
load "../../../../helpers/gh_issue_stub"

setup() {
	export LIB="${PROJECT_ROOT}/scripts/ci/lib/github/tracking_issue.sh"
	export GH_TOKEN=test-token
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	install_gh_issue_stub
}

@test "tracking_issue.sh: sets _LGTM_CI_GITHUB_TRACKING_ISSUE_LOADED guard" {
	run bash -c 'source "$LIB" && source "$LIB" && echo "${_LGTM_CI_GITHUB_TRACKING_ISSUE_LOADED}"'
	assert_success
	assert_output "1"
}

@test "tracking_issue_find: refuses a missing or malformed marker before listing" {
	local marker
	for marker in "" 'no comment' '<!-- a" or "b -->' '<!-- x --> <!-- y -->'; do
		run env TRACKING_ISSUE_MARKER="$marker" bash -c 'source "$LIB" && tracking_issue_find'
		assert_failure 2
		assert_output --partial "TRACKING_ISSUE_MARKER is missing or malformed"
	done
	run grep -c . "$GH_CALLS"
	assert_output "0"
}

@test "tracking_issue_find: prints the lowest bot-opened match, nothing without one" {
	export TRACKING_ISSUE_MARKER="<!-- lgtm-ci:unit -->"
	run bash -c 'source "$LIB" && tracking_issue_find'
	assert_success
	assert_output ""
	add_issue 9 "github-actions[bot]" Bot "<!-- lgtm-ci:unit -->"
	add_issue 4 "github-actions[bot]" Bot "<!-- lgtm-ci:unit -->"
	add_issue 2 someone User "<!-- lgtm-ci:unit -->"
	run bash -c 'source "$LIB" && tracking_issue_find'
	assert_success
	assert_output "4"
}

@test "tracking_issue_run_url: links the run, or says local" {
	run bash -c 'source "$LIB" && GITHUB_RUN_ID=7 tracking_issue_run_url'
	assert_output "https://github.com/lgtm-hq/lgtm-ci/actions/runs/7"
	run bash -c 'unset GITHUB_RUN_ID; source "$LIB" && tracking_issue_run_url'
	assert_output "(local run)"
}

@test "tracking_issue_upsert: a missing title or name exits 2, never 1" {
	local body="${BATS_TEST_TMPDIR}/body.md"
	echo "body" >"$body"
	run bash -c "set -euo pipefail; source '${PROJECT_ROOT}/scripts/ci/lib/github/tracking_issue.sh'; TRACKING_ISSUE_MARKER='<!-- lgtm-ci:test -->'; tracking_issue_upsert '$body' subject"
	assert_failure 2
	assert_output --partial "TRACKING_ISSUE_TITLE and TRACKING_ISSUE_NAME are required"
}
