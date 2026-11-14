#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/network/download.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

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

# =============================================================================
# download_with_retries tests
# =============================================================================

@test "download_with_retries: succeeds with mock curl" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download "test content"
	local outfile="${BATS_TEST_TMPDIR}/downloaded.txt"
	run bash -c "source \"\$LIB_DIR/network/download.sh\" && download_with_retries \"http://example.com/file\" \"$outfile\""
	assert_success
	[[ -f "$outfile" ]]
	# Verify the mock payload was written correctly
	run cat "$outfile"
	assert_output "test content"
}

@test "download_with_retries: fails on a non-retryable curl error" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	# Create a failing curl mock
	mock_command "curl" "" 1
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_retries "http://example.com/fail" "/tmp/out" 2>&1'
	assert_failure
}

# =============================================================================
# download_with_retries: retry classification and backoff (#1570)
# =============================================================================

# Scripted curl stub. Each argument drives one call:
#   <curl_exit>|<http_code>[|<header line>[;;<header line>...]]
# The stub writes "HTTP/2 <http_code>" plus the header lines to the
# --dump-header file (when the first header line itself starts with "HTTP/",
# the lines are written verbatim instead, to script several response blocks),
# prints the status as --write-out would, writes a body to -o on success, and
# records each call's --max-time in $CURL_CALLS. Calls past the end of the
# script reuse the last line. A recording `sleep` stub appends each wait to
# $SLEEP_CALLS, so the tests never sleep for real. Both stubs advance the fake
# clock in $CLOCK_FILE (curl by $CURL_ELAPSED seconds, at most its --max-time;
# sleep by its argument). _run_download points the library's clock at it.
_install_scripted_curl() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	export CURL_SCRIPT="${BATS_TEST_TMPDIR}/curl_script"
	export CURL_CALLS="${BATS_TEST_TMPDIR}/curl_calls"
	export SLEEP_CALLS="${BATS_TEST_TMPDIR}/sleep_calls"
	export CLOCK_FILE="${BATS_TEST_TMPDIR}/clock"
	echo 0 >"$CLOCK_FILE"
	: >"$CURL_CALLS"
	: >"$SLEEP_CALLS"
	printf '%s\n' "$@" >"$CURL_SCRIPT"
	cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
out="" hdr="" maxtime=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	--dump-header) hdr="$2"; shift 2 ;;
	--max-time) maxtime="$2"; shift 2 ;;
	*) shift ;;
	esac
done
echo "call max-time=${maxtime}" >>"$CURL_CALLS"
n=$(wc -l <"$CURL_CALLS")
line=$(sed -n "${n}p" "$CURL_SCRIPT")
[[ -n "$line" ]] || line=$(tail -n 1 "$CURL_SCRIPT")
IFS='|' read -r rc code headers <<<"$line"
if [[ -n "$hdr" ]]; then
	if [[ "$headers" != HTTP/* ]]; then
		printf 'HTTP/2 %s\r\n' "$code" >"$hdr"
	else
		: >"$hdr"
	fi
	if [[ -n "$headers" ]]; then
		printf '%s\r\n' "${headers//;;/$'\n'}" | sed 's/\r*$/\r/' >>"$hdr"
	fi
fi
# Like real curl, never run past --max-time.
spent="${CURL_ELAPSED:-0}"
if [[ -n "$maxtime" ]] && ((spent > maxtime)); then
	spent="$maxtime"
fi
echo $(($(cat "$CLOCK_FILE") + spent)) >"$CLOCK_FILE"
if [[ "$rc" == "0" ]]; then
	echo "payload" >"$out"
else
	echo "curl: (${rc}) stub failure" >&2
fi
printf '%s' "$code"
exit "$rc"
EOF
	chmod +x "${mock_bin}/curl"
	cat >"${mock_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$SLEEP_CALLS"
echo $(($(cat "$CLOCK_FILE") + $1)) >"$CLOCK_FILE"
EOF
	chmod +x "${mock_bin}/sleep"
	export PATH="${mock_bin}:$PATH"
}

_run_download() {
	run bash -c 'source "$LIB_DIR/network/download.sh" &&
		_lgtm_ci_download_now() { cat "$CLOCK_FILE"; } &&
		download_with_retries "https://example.com/f" "$BATS_TEST_TMPDIR/out" "$@" 2>&1' \
		_ "$@"
}

_curl_call_count() {
	wc -l <"$CURL_CALLS" | tr -d ' '
}

_sleeps() {
	tr '\n' ' ' <"$SLEEP_CALLS" | sed 's/ $//'
}

@test "download_with_retries: recovers after a 429" {
	require_bash4
	_install_scripted_curl "22|429" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
	assert_equal "$(_sleeps)" "2"
	run cat "${BATS_TEST_TMPDIR}/out"
	assert_output "payload"
}

@test "download_with_retries: 429 on every attempt fails after 5 with growing waits" {
	require_bash4
	_install_scripted_curl "22|429"
	_run_download
	assert_failure
	assert_output --partial "HTTP 429, curl exit 22"
	assert_output --partial "after 5 attempts"
	assert_equal "$(_curl_call_count)" "5"
	assert_equal "$(_sleeps)" "2 4 8 16"
}

@test "download_with_retries: retries 5xx and 408" {
	require_bash4
	_install_scripted_curl "22|503" "22|408" "22|502" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "4"
	assert_equal "$(_sleeps)" "2 4 8"
}

@test "download_with_retries: 404 fails on the first attempt" {
	require_bash4
	_install_scripted_curl "22|404"
	_run_download
	assert_failure
	assert_output --partial "HTTP 404, curl exit 22"
	assert_output --partial "not retryable"
	assert_equal "$(_curl_call_count)" "1"
	assert_equal "$(_sleeps)" ""
}

@test "download_with_retries: plain 403 is not retried" {
	require_bash4
	_install_scripted_curl "22|403"
	_run_download
	assert_failure
	assert_equal "$(_curl_call_count)" "1"
}

@test "download_with_retries: 403 with exhausted rate limit is retried" {
	require_bash4
	_install_scripted_curl "22|403|x-ratelimit-remaining: 0" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
}

@test "download_with_retries: honours Retry-After seconds" {
	require_bash4
	_install_scripted_curl "22|429|Retry-After: 7" "0|200"
	_run_download
	assert_success
	assert_equal "$(_sleeps)" "7"
}

@test "download_with_retries: caps Retry-After at 30s and total sleep at 60s" {
	require_bash4
	_install_scripted_curl "22|429|retry-after: 120"
	_run_download
	assert_failure
	# 30 + 30 spends the 60s budget; the third failure gives up
	assert_equal "$(_sleeps)" "30 30"
	assert_equal "$(_curl_call_count)" "3"
	assert_output --partial "retry budget spent after 3 attempts"
	assert_output --partial "HTTP 429"
}

@test "download_with_retries: ignores an HTTP-date Retry-After" {
	require_bash4
	_install_scripted_curl "22|503|Retry-After: Wed, 21 Oct 2026 07:28:00 GMT" "0|200"
	_run_download
	assert_success
	assert_equal "$(_sleeps)" "2"
}

@test "download_with_retries: retries curl transport errors" {
	require_bash4
	_install_scripted_curl "6|000" "7|000" "28|000" "56|000" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "5"
	assert_equal "$(_sleeps)" "2 4 8 16"
}

@test "download_with_retries: pin mismatch is not retried" {
	require_bash4
	_install_scripted_curl "90|000"
	_run_download
	assert_failure
	assert_output --partial "HTTP 000, curl exit 90"
	assert_equal "$(_curl_call_count)" "1"
}

@test "download_with_retries: TLS certificate failure is not retried" {
	require_bash4
	_install_scripted_curl "60|000"
	_run_download
	assert_failure
	assert_equal "$(_curl_call_count)" "1"
}

@test "download_with_retries: curl exit 22 with no status is retried" {
	require_bash4
	_install_scripted_curl "22|" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
}

@test "download_with_retries: respects the max-attempts argument" {
	require_bash4
	_install_scripted_curl "22|500"
	_run_download 2
	assert_failure
	assert_output --partial "after 2 attempts"
	assert_equal "$(_curl_call_count)" "2"
	assert_equal "$(_sleeps)" "2"
}

@test "download_with_retries: a single attempt never sleeps" {
	require_bash4
	_install_scripted_curl "22|429"
	_run_download 1
	assert_failure
	assert_equal "$(_curl_call_count)" "1"
	assert_equal "$(_sleeps)" ""
}

@test "download_with_retries: backoff base is configurable" {
	require_bash4
	_install_scripted_curl "22|500"
	LGTM_CI_DOWNLOAD_BACKOFF_BASE=0 _run_download 3
	assert_failure
	assert_equal "$(_curl_call_count)" "3"
	assert_equal "$(_sleeps)" ""
}

@test "download_with_retries: removes its header temp file" {
	require_bash4
	_install_scripted_curl "22|429" "0|200"
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	_run_download
	assert_success
	run find "$TMPDIR" -name 'lgtm-dl-headers.*'
	assert_output ""
}

# --- Finding 1: a body failure after a 2xx status is still a transport error

@test "download_with_retries: retries a partial transfer after HTTP 200" {
	require_bash4
	_install_scripted_curl "18|200" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
	assert_equal "$(_sleeps)" "2"
}

@test "download_with_retries: retries a body timeout after HTTP 200" {
	require_bash4
	_install_scripted_curl "28|200" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
}

@test "download_with_retries: retries a reset body after HTTP 200" {
	require_bash4
	_install_scripted_curl "56|200" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
}

@test "download_with_retries: retries a transport error after a redirect status" {
	require_bash4
	_install_scripted_curl "56|302" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
}

@test "download_with_retries: an HTTP 404 still decides by status" {
	require_bash4
	_install_scripted_curl "22|404"
	_run_download
	assert_failure
	assert_output --partial "not retryable"
	assert_equal "$(_curl_call_count)" "1"
}

# --- Finding 2: more transient curl exits

@test "download_with_retries: retries curl exits 8, 16, 55 and 92" {
	require_bash4
	_install_scripted_curl "8|000" "16|000" "55|000" "92|200" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "5"
	assert_equal "$(_sleeps)" "2 4 8 16"
}

# --- Finding 3: only the final response's headers count

@test "download_with_retries: ignores rate-limit hints on a redirect hop" {
	require_bash4
	local hop="HTTP/1.1 302 Found;;Retry-After: 17;;x-ratelimit-remaining: 0"
	hop+=";;Location: https://cdn.example.com/f;;"
	_install_scripted_curl "22|403|${hop};;HTTP/2 403;;content-type: text/plain"
	_run_download
	assert_failure
	assert_output --partial "HTTP 403, curl exit 22"
	assert_output --partial "not retryable"
	assert_equal "$(_curl_call_count)" "1"
	assert_equal "$(_sleeps)" ""
}

@test "download_with_retries: a hop's Retry-After is ignored when no final response came" {
	require_bash4
	# 302 with a hint, then the redirect target fails to resolve (curl 6): the
	# last header block is the hop, so its hint must not steer the retry.
	local hop="HTTP/1.1 302 Found;;Retry-After: 40;;Location: https://cdn.example.com/f"
	_install_scripted_curl "6|302|${hop}"
	_run_download
	assert_failure
	assert_output --partial "after 5 attempts"
	assert_equal "$(_curl_call_count)" "5"
	assert_equal "$(_sleeps)" "2 4 8 16"
}

@test "download_with_retries: a rate-limited 403 with a large header block is retried under pipefail" {
	require_bash4
	# grep -q would exit at the first match; with ~140 KB of headers behind it
	# the producer dies of SIGPIPE and pipefail turned the match into 141.
	local pad="" i
	for ((i = 0; i < 700; i++)); do
		pad+=";;x-pad-${i}: $(printf 'a%.0s' {1..190})"
	done
	_install_scripted_curl "22|403|HTTP/2 403;;Retry-After: 1${pad}" "0|200"
	run bash -c 'set -o pipefail; source "$LIB_DIR/network/download.sh" &&
		_lgtm_ci_download_now() { cat "$CLOCK_FILE"; } &&
		download_with_retries "https://example.com/f" "$BATS_TEST_TMPDIR/out" 2>&1'
	assert_success
	assert_equal "$(_curl_call_count)" "2"
	assert_equal "$(_sleeps)" "1"
}

@test "download_with_retries: the default clock is the system clock, not SECONDS" {
	run bash -c 'source "$LIB_DIR/network/download.sh" &&
		unset SECONDS; SECONDS=garbage; _lgtm_ci_download_now'
	assert_success
	[[ "$output" =~ ^[0-9]{10,}$ ]]
}

@test "download_with_retries: max-attempts 0 still makes one attempt" {
	require_bash4
	_install_scripted_curl "0|200"
	_run_download 0
	assert_success
	assert_equal "$(_curl_call_count)" "1"
}

@test "download_with_retries: honours Retry-After on the final response" {
	require_bash4
	# Proxy CONNECT, a redirect carrying its own hint, a 100, then the final 429
	local blocks="HTTP/1.1 200 Connection established;;"
	blocks+=";;HTTP/1.1 302 Found;;Retry-After: 17;;"
	blocks+=";;HTTP/2 100;;"
	blocks+=";;HTTP/2 429;;RETRY-AFTER: 5"
	_install_scripted_curl "22|429|${blocks}" "0|200"
	_run_download
	assert_success
	assert_equal "$(_sleeps)" "5"
}

@test "download_with_retries: 403 rate limit on the final response is retried" {
	require_bash4
	local hop="HTTP/1.1 301 Moved;;Location: https://x.example.com/f;;"
	_install_scripted_curl "22|403|${hop};;HTTP/2 403;;X-RateLimit-Remaining: 0" "0|200"
	_run_download
	assert_success
	assert_equal "$(_curl_call_count)" "2"
}

# --- Finding 4: a huge Retry-After must not break arithmetic

@test "download_with_retries: a 40-digit Retry-After waits the cap and continues" {
	require_bash4
	_install_scripted_curl \
		"22|429|Retry-After: 1234567890123456789012345678901234567890" "0|200"
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	_run_download
	assert_success
	refute_output --partial "syntax error"
	assert_equal "$(_sleeps)" "30"
	assert_equal "$(_curl_call_count)" "2"
	run find "$TMPDIR" -name 'lgtm-dl-headers.*'
	assert_output ""
}

@test "download_with_retries: a huge Retry-After on every attempt ends with a diagnostic" {
	require_bash4
	_install_scripted_curl "22|503|Retry-After: 9999999999999999999999999999999999999999"
	_run_download
	assert_failure
	assert_equal "$(_sleeps)" "30 30"
	assert_output --partial "retry budget spent after 3 attempts"
}

# --- Finding 5: overall time budget

@test "download_with_retries: each attempt gets --max-time of at most 300s" {
	require_bash4
	_install_scripted_curl "22|500" "0|200"
	_run_download
	assert_success
	run cat "$CURL_CALLS"
	assert_output "call max-time=300
call max-time=300"
}

@test "download_with_retries: --max-time shrinks to the time left" {
	require_bash4
	# Each failed attempt burns 300s of the 900s budget.
	_install_scripted_curl "28|000"
	CURL_ELAPSED=300 _run_download
	assert_failure
	# 300 + 2 + 300 + 4 = 606s used before the third attempt -> 294s left
	assert_output --partial "900s time budget spent after 3 attempts"
	run cat "$CURL_CALLS"
	assert_output "call max-time=300
call max-time=300
call max-time=294"
	run cat "$CLOCK_FILE"
	assert_output "900"
}

@test "download_with_retries: skips a wait that does not fit the time budget" {
	require_bash4
	_install_scripted_curl "22|429|Retry-After: 20"
	CURL_ELAPSED=85 LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT=100 _run_download
	assert_failure
	# The first attempt uses 85s; a 20s wait cannot fit in the 15s left
	assert_equal "$(_curl_call_count)" "1"
	assert_equal "$(_sleeps)" ""
	assert_output --partial "a 20s wait does not fit the 15s left of the"
	assert_output --partial "100s time budget after 1 attempts"
}

@test "download_with_retries: gives up when the time budget is spent" {
	require_bash4
	_install_scripted_curl "28|000"
	CURL_ELAPSED=10 LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT=12 \
		LGTM_CI_DOWNLOAD_BACKOFF_BASE=0 _run_download
	assert_failure
	# 10s per attempt, no waits: attempt 2 gets the 2s left, then nothing
	run cat "$CURL_CALLS"
	assert_output "call max-time=12
call max-time=2"
}

@test "download_with_retries: reports the spent time budget" {
	require_bash4
	_install_scripted_curl "28|000"
	CURL_ELAPSED=10 LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT=12 \
		LGTM_CI_DOWNLOAD_BACKOFF_BASE=0 _run_download
	assert_failure
	assert_output --partial "HTTP 000, curl exit 28"
	assert_output --partial "12s time budget spent after 2 attempts"
}

# --- Finding 6: tunables must be whole numbers

@test "download_with_retries: a fractional backoff base falls back to the default" {
	require_bash4
	_install_scripted_curl "22|500" "0|200"
	LGTM_CI_DOWNLOAD_BACKOFF_BASE=0.5 _run_download
	assert_success
	assert_output --partial "Ignoring invalid LGTM_CI_DOWNLOAD_BACKOFF_BASE='0.5'"
	refute_output --partial "syntax error"
	assert_equal "$(_sleeps)" "2"
}

@test "download_with_retries: invalid caps and timeout fall back to defaults" {
	require_bash4
	_install_scripted_curl "22|429|Retry-After: 45" "0|200"
	LGTM_CI_DOWNLOAD_MAX_WAIT=abc LGTM_CI_DOWNLOAD_MAX_SLEEP=-1 \
		LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT=1e9 _run_download
	assert_success
	assert_output --partial "LGTM_CI_DOWNLOAD_MAX_WAIT='abc'"
	assert_output --partial "LGTM_CI_DOWNLOAD_MAX_SLEEP='-1'"
	assert_output --partial "LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT='1e9'"
	assert_equal "$(_sleeps)" "30"
}

@test "download_with_retries: an invalid max-attempts argument falls back to 5" {
	require_bash4
	_install_scripted_curl "22|500"
	_run_download "three"
	assert_failure
	assert_output --partial "Ignoring invalid max_attempts='three'"
	assert_equal "$(_curl_call_count)" "5"
}

@test "download_with_retries: enforces HTTPS-only and TLS 1.2 floor" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--proto =https"
	assert_output --partial "--tlsv1.2"
}

@test "download_with_retries: passes pinned pubkey from env" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && LGTM_CI_PINNED_PUBKEY="sha256//AAAA" download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey sha256//AAAA"
}

@test "download_with_retries: no pinning args by default" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	refute_output --partial "--pinnedpubkey"
	refute_output --partial "--cacert"
}

@test "download_with_retries: passes custom CA bundle from env" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	local bundle="${BATS_TEST_TMPDIR}/ca.pem"
	echo "fake-ca" >"$bundle"
	run bash -c "source \"\$LIB_DIR/network/download.sh\" && LGTM_CI_CA_BUNDLE=\"$bundle\" download_with_retries \"https://example.com/file\" \"\$BATS_TEST_TMPDIR/out\""
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--cacert ${bundle}"
}

@test "download_with_retries: fails closed on unreadable CA bundle" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && LGTM_CI_CA_BUNDLE="/nonexistent/ca.pem" download_with_retries "https://example.com/file" "$BATS_TEST_TMPDIR/out" 2>&1'
	assert_failure
	assert_output --partial "CA bundle not readable"
	# curl must never be invoked
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output ""
}

# =============================================================================
# download_with_pinning tests
# =============================================================================

@test "download_with_pinning: succeeds with explicit hash pin" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "pinned content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out" "sha256//BBBB"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey sha256//BBBB"
	run cat "${BATS_TEST_TMPDIR}/out"
	assert_output "pinned content"
}

@test "download_with_pinning: accepts pin from LGTM_CI_PINNED_PUBKEY env" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && LGTM_CI_PINNED_PUBKEY="sha256//CCCC" download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey sha256//CCCC"
}

@test "download_with_pinning: fails closed without a pin" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out" 2>&1'
	assert_failure
	assert_output --partial "refusing unpinned download"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output ""
}

@test "download_with_pinning: fails closed on unreadable pin key file" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_with_pinning "https://example.com/file" "$BATS_TEST_TMPDIR/out" "/nonexistent/pin.pem" 2>&1'
	assert_failure
	assert_output --partial "pinned key file not readable"
}

@test "download_with_pinning: accepts pin key file path and CA bundle" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download_record "content"
	local pin="${BATS_TEST_TMPDIR}/pin.pem"
	local bundle="${BATS_TEST_TMPDIR}/ca.pem"
	echo "fake-key" >"$pin"
	echo "fake-ca" >"$bundle"
	run bash -c "source \"\$LIB_DIR/network/download.sh\" && download_with_pinning \"https://example.com/file\" \"\$BATS_TEST_TMPDIR/out\" \"$pin\" \"$bundle\""
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--pinnedpubkey ${pin}"
	assert_output --partial "--cacert ${bundle}"
}

# =============================================================================
# download_and_run_installer tests
# =============================================================================

# Helper: create a mock curl that writes an installer script to -o target
# Usage: mock_curl_installer_script "echo 'hello world'"
mock_curl_installer_script() {
	local script_body="$1"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	# Write the desired script body to a payload file
	local payload="${mock_bin}/.installer_payload"
	printf '#!/usr/bin/env bash\n%s\n' "$script_body" >"$payload"

	cat >"${mock_bin}/curl" <<'CURL'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2;;
        --output) output_file="$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "$output_file" ]]; then
    cp "PAYLOAD_PLACEHOLDER" "$output_file"
fi
exit 0
CURL
	# Patch the placeholder with the real payload path
	sed -i.bak "s|PAYLOAD_PLACEHOLDER|${payload}|" "${mock_bin}/curl"
	rm -f "${mock_bin}/curl.bak"
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"
}

@test "download_and_run_installer: downloads and executes script" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_installer_script 'echo "installer ran"'

	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "http://example.com/install.sh"'
	assert_success
	assert_output --partial "installer ran"
}

@test "download_and_run_installer: passes arguments to script" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_installer_script 'echo "args: $@"'

	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "http://example.com/install.sh" arg1 arg2'
	assert_success
	assert_output --partial "args: arg1 arg2"
}

@test "download_and_run_installer: fails when curl fails" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_command "curl" "" 1
	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "http://example.com/fail.sh" 2>&1'
	assert_failure
	assert_output --partial "Failed to download"
}

@test "download_and_run_installer: enforces HTTPS-only and TLS 1.2 floor" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_installer_script 'echo "installer ran"'
	# Wrap the mock curl to record args (mock_curl_installer_script does not)
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mv "${mock_bin}/curl" "${mock_bin}/curl.real"
	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_curl'
exec '${mock_bin}/curl.real' "\$@"
EOF
	chmod +x "${mock_bin}/curl"

	run bash -c 'source "$LIB_DIR/network/download.sh" && download_and_run_installer "https://example.com/install.sh"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "--proto =https"
	assert_output --partial "--tlsv1.2"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "download.sh: exports download_with_retries function" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	mock_curl_download "content"
	run bash -c 'source "$LIB_DIR/network/download.sh" && bash -c "download_with_retries http://example.com /dev/null"'
	assert_success
}

@test "download.sh: declares download_with_pinning function" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/network/download.sh" && declare -f download_with_pinning >/dev/null && echo "declared"'
	assert_success
	assert_output "declared"
}

@test "download.sh: declares download_and_run_installer function" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/network/download.sh" && declare -f download_and_run_installer >/dev/null && echo "declared"'
	assert_success
	assert_output "declared"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "download.sh: can be sourced multiple times without error" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c '
		source "$LIB_DIR/network/download.sh"
		source "$LIB_DIR/network/download.sh"
		source "$LIB_DIR/network/download.sh"
		declare -f download_with_retries >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "download.sh: sets _LGTM_CI_NETWORK_DOWNLOAD_LOADED guard" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	run bash -c 'source "$LIB_DIR/network/download.sh" && echo "${_LGTM_CI_NETWORK_DOWNLOAD_LOADED}"'
	assert_success
	assert_output "1"
}
