#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/notify/deliver.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

WEBHOOK="https://hooks.example.com/services/T0/B0/xyz"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

run_deliver() {
	run bash -c \
		'source "$LIB_DIR/log.sh" && source "$LIB_DIR/notify/deliver.sh" && notify_deliver "$@"' \
		_ "$@"
}

# Create a curl mock that emits HTTP codes from a sequence, one per call.
# Usage: mock_curl_sequence "500" "500" "200"
mock_curl_sequence() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local seq_file="${mock_bin}/.curl_sequence"
	printf '%s\n' "$@" >"$seq_file"

	local count_file="${mock_bin}/.curl_count"
	echo 0 >"$count_file"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
count=\$(cat '${count_file}')
count=\$((count + 1))
echo "\$count" >'${count_file}'
sed -n "\${count}p" '${seq_file}'
EOF
	chmod +x "${mock_bin}/curl"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

curl_call_count() {
	cat "${BATS_TEST_TMPDIR}/bin/.curl_count"
}

# Create a curl mock whose first call returns 429 with the given response
# headers and body (written to the -D/-o files), and whose later calls
# return final_code.
# Usage: mock_curl_429 <headers-content> <body-content> [final-code]
mock_curl_429() {
	local headers_content="$1"
	local body_content="$2"
	local final_code="${3:-200}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	printf '%s\n' "$headers_content" >"${mock_bin}/.retry_headers"
	printf '%s' "$body_content" >"${mock_bin}/.retry_body"
	echo 0 >"${mock_bin}/.curl_count"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
count=\$(cat '${mock_bin}/.curl_count')
count=\$((count + 1))
echo "\$count" >'${mock_bin}/.curl_count'
headers_file="" body_file=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	-D) headers_file="\$2"; shift 2 ;;
	-o) body_file="\$2"; shift 2 ;;
	*) shift ;;
	esac
done
if [[ "\$count" -eq 1 ]]; then
	[[ -n "\$headers_file" ]] && cat '${mock_bin}/.retry_headers' >"\$headers_file"
	[[ -n "\$body_file" ]] && cat '${mock_bin}/.retry_body' >"\$body_file"
	echo "429"
else
	echo "${final_code}"
fi
EOF
	chmod +x "${mock_bin}/curl"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

sleep_calls() {
	cat "${BATS_TEST_TMPDIR}/mock_calls_sleep"
}

@test "notify_deliver: succeeds on HTTP 200" {
	mock_curl "200"

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "delivered (HTTP 200"
}

@test "notify_deliver: rejects non-https webhook URL" {
	mock_curl "200"

	run_deliver "http://hooks.example.com/x" '{"text":"hi"}'
	assert_failure
	assert_output --partial "must use https://"
}

@test "notify_deliver: rejects empty payload" {
	run_deliver "$WEBHOOK" ""
	assert_failure
	assert_output --partial "payload must not be empty"
}

@test "notify_deliver: retries on 500 then succeeds" {
	mock_curl_sequence "500" "500" "200"
	mock_command "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "transient HTTP 500 (attempt 1/3)"
	assert_output --partial "transient HTTP 500 (attempt 2/3)"
	assert_output --partial "delivered (HTTP 200, attempt 3/3)"

	run curl_call_count
	assert_output "3"
}

@test "notify_deliver: retries on 429 rate limit" {
	mock_curl_sequence "429" "200"
	mock_command "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "transient HTTP 429"

	run curl_call_count
	assert_output "2"
}

@test "notify_deliver: retries on curl transport errors" {
	mock_curl "" 28
	mock_command "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_failure
	assert_output --partial "transport error (curl exit 28, attempt 1/3)"
	assert_output --partial "delivery failed after 3 attempts"
}

@test "notify_deliver: fails fast on non-transient 4xx" {
	mock_curl_sequence "400" "200"
	mock_command "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_failure
	assert_output --partial "webhook rejected the request (HTTP 400)"

	run curl_call_count
	assert_output "1"
}

@test "notify_deliver: gives up after max attempts" {
	mock_curl "503"
	mock_command "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_failure
	assert_output --partial "delivery failed after 3 attempts"
}

@test "notify_deliver: does not pass the webhook URL as a curl argument" {
	mock_command_record "curl" "200"

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success

	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	[[ "$output" != *"$WEBHOOK"* ]]
	[[ "$output" == *"-K -"* ]]
	[[ "$output" == *"--data-raw"* ]]
}

@test "notify_deliver: honors Retry-After header on 429" {
	mock_curl_429 $'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r' ""
	mock_command_record "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "retrying in 7s"

	run sleep_calls
	assert_output "7"
}

@test "notify_deliver: honors Discord retry_after body on 429" {
	mock_curl_429 $'HTTP/1.1 429 Too Many Requests\r' '{"retry_after": 2.5}' "204"
	mock_command_record "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "retrying in 3s"

	run sleep_calls
	assert_output "3"
}

@test "notify_deliver: caps Retry-After at NOTIFY_RETRY_MAX_DELAY" {
	mock_curl_429 $'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 120\r' ""
	mock_command_record "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "retrying in 30s"

	run sleep_calls
	assert_output "30"
}

@test "notify_deliver: falls back to linear backoff on 429 without hints" {
	mock_curl_sequence "429" "200"
	mock_command_record "sleep" ""

	run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "retrying in 2s"

	run sleep_calls
	assert_output "2"
}

@test "notify_deliver: honors NOTIFY_MAX_ATTEMPTS override" {
	mock_curl_sequence "500" "500" "500" "500" "200"
	mock_command "sleep" ""

	NOTIFY_MAX_ATTEMPTS=5 run_deliver "$WEBHOOK" '{"text":"hi"}'
	assert_success
	assert_output --partial "delivered (HTTP 200, attempt 5/5)"
}
