#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/notify/payload.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export LIB_DIR
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_slack_payload() {
	run bash -c 'source "$LIB_DIR/notify.sh" && notify_slack_payload "$@"' _ "$@"
}

run_discord_payload() {
	run bash -c 'source "$LIB_DIR/notify.sh" && notify_discord_payload "$@"' _ "$@"
}

# =============================================================================
# Slack payloads
# =============================================================================

@test "notify_slack_payload: success payload uses green attachment color" {
	run_slack_payload "success" "Build Passed" "" "[]"
	assert_success

	run jq -r '.attachments[0].color' <<<"$output"
	assert_output "#2da44e"
}

@test "notify_slack_payload: failure payload uses red attachment color" {
	run_slack_payload "failure" "Build Failed" "" "[]"
	assert_success

	run jq -r '.attachments[0].color' <<<"$output"
	assert_output "#cf222e"
}

@test "notify_slack_payload: cancelled payload uses yellow attachment color" {
	run_slack_payload "cancelled" "Build Cancelled" "" "[]"
	assert_success

	run jq -r '.attachments[0].color' <<<"$output"
	assert_output "#d4a72c"
}

@test "notify_slack_payload: header block carries emoji-prefixed title" {
	run_slack_payload "failure" "Build Failed" "" "[]"
	assert_success

	run jq -r '.attachments[0].blocks[0].text.text' <<<"$output"
	assert_output "❌ Build Failed"
}

@test "notify_slack_payload: message becomes a mrkdwn section" {
	run_slack_payload "success" "Title" "It worked" "[]"
	assert_success

	run jq -r '.attachments[0].blocks[1].text.text' <<<"$output"
	assert_output "It worked"
}

@test "notify_slack_payload: omits message section when message is empty" {
	run_slack_payload "success" "Title" "" "[]"
	assert_success

	run jq -r '[.attachments[0].blocks[].type] | join(",")' <<<"$output"
	assert_output "header,context"
}

@test "notify_slack_payload: renders fields as section fields" {
	run_slack_payload "success" "Title" "" \
		'[{"name":"Environment","value":"production"}]'
	assert_success

	run jq -r '.attachments[0].blocks[1].fields[0].text' <<<"$output"
	assert_output "*Environment*
production"
}

@test "notify_slack_payload: context block injects repo, run URL, ref, actor" {
	run_slack_payload "success" "Title" "" "[]"
	assert_success

	run jq -r '.attachments[0].blocks[-1].elements[0].text' <<<"$output"
	assert_output --partial "test-org/test-repo"
	assert_output --partial "https://github.com/test-org/test-repo/actions/runs/12345"
	assert_output --partial "main"
	assert_output --partial "test-user"
}

@test "notify_slack_payload: rejects invalid status" {
	run_slack_payload "bogus" "Title" "" "[]"
	assert_failure
	assert_output --partial "invalid status"
}

# =============================================================================
# Discord payloads
# =============================================================================

@test "notify_discord_payload: success payload uses decimal embed color" {
	run_discord_payload "success" "Deployed" "" "[]"
	assert_success

	run jq -r '.embeds[0].color' <<<"$output"
	assert_output "2991182"
}

@test "notify_discord_payload: failure payload uses decimal embed color" {
	run_discord_payload "failure" "Deploy Failed" "" "[]"
	assert_success

	run jq -r '.embeds[0].color' <<<"$output"
	assert_output "13574702"
}

@test "notify_discord_payload: embed title carries emoji and links to run" {
	run_discord_payload "success" "Deployed" "" "[]"
	assert_success

	run jq -r '.embeds[0].title, .embeds[0].url' <<<"$output"
	assert_line --index 0 "✅ Deployed"
	assert_line --index 1 "https://github.com/test-org/test-repo/actions/runs/12345"
}

@test "notify_discord_payload: message becomes the embed description" {
	run_discord_payload "success" "Deployed" "All green" "[]"
	assert_success

	run jq -r '.embeds[0].description' <<<"$output"
	assert_output "All green"
}

@test "notify_discord_payload: omits description when message is empty" {
	run_discord_payload "success" "Deployed" "" "[]"
	assert_success

	run jq -r '.embeds[0] | has("description")' <<<"$output"
	assert_output "false"
}

@test "notify_discord_payload: injects context fields after custom fields" {
	run_discord_payload "success" "Deployed" "" \
		'[{"name":"Environment","value":"production"}]'
	assert_success
	local payload="$output"

	run jq -r '[.embeds[0].fields[].name] | join(",")' <<<"$payload"
	assert_output "Environment,Repository,Ref,Actor"

	run jq -r '.embeds[0].fields[1].value' <<<"$payload"
	assert_output "test-org/test-repo"
}

@test "notify_discord_payload: rejects invalid status" {
	run_discord_payload "bogus" "Title" "" "[]"
	assert_failure
	assert_output --partial "invalid status"
}
