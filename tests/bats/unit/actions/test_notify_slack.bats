#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/notify-slack.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/notify-slack.sh"
WEBHOOK="https://hooks.slack.com/services/T0/B0/xyz"

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

run_notify_slack() {
	run bash "${PROJECT_ROOT}/${SCRIPT}"
}

@test "notify-slack: fails without STATUS" {
	run env -u STATUS TITLE="t" WEBHOOK_URL="$WEBHOOK" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STATUS is required"
}

@test "notify-slack: fails without TITLE" {
	run env -u TITLE STATUS="success" WEBHOOK_URL="$WEBHOOK" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "TITLE is required"
}

@test "notify-slack: fails on invalid status" {
	STATUS="bogus" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_slack
	assert_failure
	assert_output --partial "invalid status 'bogus'"
}

@test "notify-slack: fails without WEBHOOK_URL when not dry-run" {
	STATUS="success" TITLE="t" run_notify_slack
	assert_failure
	assert_output --partial "WEBHOOK_URL is required"
}

@test "notify-slack: dry-run prints payload without curl" {
	mock_command_record "curl" "200"

	STATUS="failure" TITLE="Build Failed" DRY_RUN="true" run_notify_slack
	assert_success
	assert_output --partial "dry-run enabled"
	assert_output --partial '"attachments"'
	assert_file_contains "$GITHUB_OUTPUT" "delivered=false"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output ""
}

@test "notify-slack: dry-run payload is valid JSON with status color" {
	STATUS="failure" TITLE="Build Failed" DRY_RUN="true" run_notify_slack
	assert_success

	local payload
	payload="$(grep '^{' <<<"$output")"
	run jq -r '.attachments[0].color' <<<"$payload"
	assert_output "#cf222e"
}

@test "notify-slack: dry-run payload injects workflow context" {
	STATUS="success" TITLE="t" DRY_RUN="true" run_notify_slack
	assert_success

	local payload
	payload="$(grep '^{' <<<"$output")"
	run jq -r '.attachments[0].blocks[-1].elements[0].text' <<<"$payload"
	assert_output --partial "test-org/test-repo"
	assert_output --partial "https://github.com/test-org/test-repo/actions/runs/12345"
	assert_output --partial "test-user"
}

@test "notify-slack: dry-run payload renders fields" {
	STATUS="success" TITLE="t" DRY_RUN="true" \
		FIELDS=$'Environment=production\nVersion=1.2.3' run_notify_slack
	assert_success

	local payload
	payload="$(grep '^{' <<<"$output")"
	run jq -r '.attachments[0].blocks[1].fields | length' <<<"$payload"
	assert_output "2"
}

@test "notify-slack: fails on malformed FIELDS" {
	STATUS="success" TITLE="t" DRY_RUN="true" FIELDS="not-a-field" run_notify_slack
	assert_failure
	assert_output --partial "invalid fields line"
}

@test "notify-slack: delivers payload and sets delivered=true" {
	mock_command_record "curl" "200"

	STATUS="success" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_slack
	assert_success
	assert_output --partial "notification sent"
	assert_file_contains "$GITHUB_OUTPUT" "delivered=true"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "Content-Type: application/json"
	# The webhook URL travels via the stdin curl config (-K -), never argv.
	[[ "$output" != *"$WEBHOOK"* ]]
	[[ "$output" == *"-K -"* ]]
	[[ "$output" == *"--data-raw"* ]]
}

@test "notify-slack: fails and sets delivered=false on hard rejection" {
	mock_curl "404"

	STATUS="success" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_slack
	assert_failure
	assert_output --partial "delivery failed"
	assert_file_contains "$GITHUB_OUTPUT" "delivered=false"
}

@test "notify-slack: retries transient failures before succeeding" {
	mock_command "sleep" ""
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	echo 0 >"${mock_bin}/.curl_count"
	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
count=\$(cat '${mock_bin}/.curl_count')
count=\$((count + 1))
echo "\$count" >'${mock_bin}/.curl_count'
if [[ "\$count" -lt 3 ]]; then echo "500"; else echo "200"; fi
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"

	STATUS="success" TITLE="t" WEBHOOK_URL="$WEBHOOK" run_notify_slack
	assert_success
	assert_output --partial "transient HTTP 500 (attempt 1/3)"
	assert_output --partial "delivered (HTTP 200, attempt 3/3)"
	assert_file_contains "$GITHUB_OUTPUT" "delivered=true"
}
