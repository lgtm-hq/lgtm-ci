#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/notify-discord.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/notify-discord.sh"
WEBHOOK="https://discord.com/api/webhooks/123/token"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
}

teardown() {
	teardown_github_env
	restore_path
	teardown_temp_dir
}

run_notify_discord() {
	run bash "${PROJECT_ROOT}/${SCRIPT}"
}

@test "notify-discord: fails without STATUS" {
	run env -u STATUS TITLE="t" WEBHOOK_URL="$WEBHOOK" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STATUS is required"
}

@test "notify-discord: fails without TITLE" {
	run env -u TITLE STATUS="success" WEBHOOK_URL="$WEBHOOK" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "TITLE is required"
}

@test "notify-discord: fails on invalid status" {
	STATUS="bogus" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_discord
	assert_failure
	assert_output --partial "invalid status 'bogus'"
}

@test "notify-discord: fails without WEBHOOK_URL when not dry-run" {
	STATUS="success" TITLE="t" run_notify_discord
	assert_failure
	assert_output --partial "WEBHOOK_URL is required"
}

@test "notify-discord: dry-run prints payload without curl" {
	mock_command_record "curl" "204"

	STATUS="success" TITLE="Deployed" DRY_RUN="true" run_notify_discord
	assert_success
	assert_output --partial "dry-run enabled"
	assert_output --partial '"embeds"'
	assert_file_contains "$GITHUB_OUTPUT" "delivered=false"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output ""
}

@test "notify-discord: dry-run payload uses status color and context" {
	STATUS="failure" TITLE="Deploy Failed" MESSAGE="broke" DRY_RUN="true" \
		run_notify_discord
	assert_success

	local payload
	payload="$(grep '^{' <<<"$output")"
	run jq -r '.embeds[0].color, .embeds[0].description, .embeds[0].url' <<<"$payload"
	assert_line --index 0 "13574702"
	assert_line --index 1 "broke"
	assert_line --index 2 "https://github.com/test-org/test-repo/actions/runs/12345"
}

@test "notify-discord: dry-run payload renders fields before context fields" {
	STATUS="success" TITLE="t" DRY_RUN="true" \
		FIELDS=$'Environment: production' run_notify_discord
	assert_success

	local payload
	payload="$(grep '^{' <<<"$output")"
	run jq -r '[.embeds[0].fields[].name] | join(",")' <<<"$payload"
	assert_output "Environment,Repository,Ref,Actor"
}

@test "notify-discord: fails on malformed FIELDS" {
	STATUS="success" TITLE="t" DRY_RUN="true" FIELDS="oops" run_notify_discord
	assert_failure
	assert_output --partial "invalid fields line"
}

@test "notify-discord: delivers payload and sets delivered=true" {
	mock_command_record "curl" "204"

	STATUS="success" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_discord
	assert_success
	assert_output --partial "notification sent"
	assert_file_contains "$GITHUB_OUTPUT" "delivered=true"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "Content-Type: application/json"
	# The webhook URL travels via the stdin curl config (-K -), never argv.
	[[ "$output" != *"$WEBHOOK"* ]]
	[[ "$output" == *"-K -"* ]]
}

@test "notify-discord: fails and sets delivered=false on hard rejection" {
	mock_curl "401"

	STATUS="success" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_discord
	assert_failure
	assert_output --partial "delivery failed"
	assert_file_contains "$GITHUB_OUTPUT" "delivered=false"
}

@test "notify-discord: retries transient failures before succeeding" {
	mock_command "sleep" ""
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	echo 0 >"${mock_bin}/.curl_count"
	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
count=\$(cat '${mock_bin}/.curl_count')
count=\$((count + 1))
echo "\$count" >'${mock_bin}/.curl_count'
if [[ "\$count" -lt 2 ]]; then echo "429"; else echo "204"; fi
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"

	STATUS="success" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_discord
	assert_success
	assert_output --partial "transient HTTP 429 (attempt 1/3)"
	assert_output --partial "delivered (HTTP 204, attempt 2/3)"
	assert_file_contains "$GITHUB_OUTPUT" "delivered=true"
}
