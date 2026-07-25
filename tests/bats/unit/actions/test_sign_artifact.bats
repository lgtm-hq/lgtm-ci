#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for the transient-OIDC signing retry in
#          scripts/ci/actions/sign-artifact.sh (STEP=sign)

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/sign-artifact.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export STEP="sign"
	export SIGNATURES_DIR="${BATS_TEST_TMPDIR}/signatures"
	ARTIFACT_DIR="${BATS_TEST_TMPDIR}/dist"
	mkdir -p "$ARTIFACT_DIR"
	printf 'artifact one\n' >"${ARTIFACT_DIR}/one.tar.gz"
	export ARTIFACT_DIR
	export FILES="${ARTIFACT_DIR}/one.tar.gz"
	stub_sleep
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# Local helpers
# =============================================================================

# Replace sleep with a no-op that records its delays so backoff can be
# asserted without the suite actually waiting.
stub_sleep() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_sleep"
	: >"$calls_file"

	cat >"${mock_bin}/sleep" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${calls_file}'
exit 0
EOF
	chmod +x "${mock_bin}/sleep"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# Mock cosign sign-blob so the first N invocations fail with the given stderr
# output and every later invocation writes the requested signature and
# certificate files. Calls are recorded per invocation.
# Usage: mock_cosign_failing <fail_count> <failure_output>
mock_cosign_failing() {
	local fail_count="$1" fail_output="$2"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_cosign"
	local counter_file="${mock_bin}/.cosign_attempts"
	local output_file="${mock_bin}/.cosign_fail_output"
	: >"$calls_file"
	echo 0 >"$counter_file"
	printf '%s\n' "$fail_output" >"$output_file"

	cat >"${mock_bin}/cosign" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${calls_file}'
attempts=\$(cat '${counter_file}')
attempts=\$((attempts + 1))
echo "\$attempts" >'${counter_file}'
if [[ "\$attempts" -le ${fail_count} ]]; then
	cat '${output_file}' >&2
	exit 1
fi
sig_file=""
cert_file=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	--output-signature)
		sig_file="\$2"
		shift 2
		;;
	--output-certificate)
		cert_file="\$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
[[ -n "\$sig_file" ]] && echo "MEUCIQDfake-signature" >"\$sig_file"
[[ -n "\$cert_file" ]] && echo "-----BEGIN CERTIFICATE-----" >"\$cert_file"
echo "tlog entry created"
EOF
	chmod +x "${mock_bin}/cosign"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

cosign_call_count() {
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_cosign"
	[[ -f "$calls_file" ]] || {
		echo 0
		return 0
	}
	awk 'END { print NR }' "$calls_file"
}

sleep_call_count() {
	awk 'END { print NR }' "${BATS_TEST_TMPDIR}/mock_calls_sleep"
}

# =============================================================================
# Happy path and bounds validation
# =============================================================================

@test "sign-artifact: signs exactly once when the first attempt succeeds" {
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Successfully signed 1 file(s)"
	assert_equal "1" "$(cosign_call_count)"
	assert_equal "0" "$(sleep_call_count)"
}

@test "sign-artifact: rejects non-numeric COSIGN_SIGN_MAX_ATTEMPTS" {
	export COSIGN_SIGN_MAX_ATTEMPTS="three"
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be a non-negative integer"
	assert_equal "0" "$(cosign_call_count)"
}

@test "sign-artifact: rejects zero COSIGN_SIGN_MAX_ATTEMPTS" {
	export COSIGN_SIGN_MAX_ATTEMPTS="0"
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be at least 1"
	assert_equal "0" "$(cosign_call_count)"
}

@test "sign-artifact: rejects non-numeric COSIGN_SIGN_MAX_DELAY" {
	export COSIGN_SIGN_MAX_DELAY="-5"
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_DELAY must be a non-negative integer"
	assert_equal "0" "$(cosign_call_count)"
}

@test "sign-artifact: accepts zero-padded retry knobs" {
	export COSIGN_SIGN_MAX_ATTEMPTS="04"
	export COSIGN_SIGN_MAX_DELAY="08"
	mock_cosign_failing 3 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	refute_output --partial "value too great for base"
	assert_equal "4" "$(cosign_call_count)"
}

# =============================================================================
# Transient ambient-OIDC retry
# =============================================================================

@test "sign-artifact: retries transient ambient OIDC failure and succeeds" {
	mock_cosign_failing 1 "Error: signing blob: getting signer: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Transient OIDC failure signing ${ARTIFACT_DIR}/one.tar.gz"
	assert_output --partial "Successfully signed 1 file(s)"
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-artifact: retries 'retrieving ID token' failures" {
	mock_cosign_failing 1 "Error: retrieving ID token: unexpected EOF"

	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-artifact: retries 'reading ID token' failures" {
	mock_cosign_failing 1 "Error: reading ID token: context deadline exceeded"

	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-artifact: marker matching is case-insensitive" {
	mock_cosign_failing 1 "Error: FETCHING Ambient OIDC Credentials: none available"

	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-artifact: fails after exhausting attempts on persistent OIDC flake" {
	export COSIGN_SIGN_MAX_ATTEMPTS="2"
	mock_cosign_failing 99 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "cosign sign-blob failed for ${ARTIFACT_DIR}/one.tar.gz after 2 attempt(s)"
	assert_equal "2" "$(cosign_call_count)"
	refute_output --partial "Successfully signed"
}

@test "sign-artifact: caps backoff at COSIGN_SIGN_MAX_DELAY" {
	export COSIGN_SIGN_MAX_ATTEMPTS="4"
	export COSIGN_SIGN_MAX_DELAY="1"
	mock_cosign_failing 3 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_sleep"
	assert_output "1
1
1"
}

@test "sign-artifact: keeps cosign output in the job log" {
	mock_cosign_failing 1 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Error: fetching ambient OIDC credentials: no credentials found"
}

# Retry is scoped to each blob, so a flake on the first file must not cause the
# already-signed files to be signed again.
@test "sign-artifact: retries per blob rather than per batch" {
	printf 'artifact two\n' >"${ARTIFACT_DIR}/two.tar.gz"
	export FILES="${ARTIFACT_DIR}/one.tar.gz ${ARTIFACT_DIR}/two.tar.gz"
	mock_cosign_failing 1 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Successfully signed 2 file(s)"
	# one.tar.gz: fail then succeed (2 calls); two.tar.gz: succeed (1 call)
	assert_equal "3" "$(cosign_call_count)"
	assert_equal "1" "$(sleep_call_count)"
}

# A fatal failure on one blob aborts the whole batch rather than carrying on to
# the remaining files, so a broken signing setup cannot half-sign a release.
@test "sign-artifact: a fatal failure on the first blob aborts the batch" {
	printf 'artifact two\n' >"${ARTIFACT_DIR}/two.tar.gz"
	export FILES="${ARTIFACT_DIR}/one.tar.gz ${ARTIFACT_DIR}/two.tar.gz"
	mock_cosign_failing 99 "Error: signature rejected by policy: identity not allowed"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	# Exactly one attempt total: the first blob is fatal, the second is never tried.
	assert_equal "1" "$(cosign_call_count)"
	assert_equal "0" "$(sleep_call_count)"
	refute_output --partial "Successfully signed"
	# No signature was produced for the second blob.
	run bash -c 'set -- "${SIGNATURES_DIR}"/*two.tar.gz.sig; [[ -f "$1" ]]'
	assert_failure
}

# =============================================================================
# Non-transient failures stay fatal
# =============================================================================

@test "sign-artifact: does not retry an upload failure" {
	mock_cosign_failing 1 "Error: uploading to rekor: 502 Bad Gateway"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_output --partial "502 Bad Gateway"
	assert_equal "1" "$(cosign_call_count)"
	assert_equal "0" "$(sleep_call_count)"
}

@test "sign-artifact: does not retry a policy rejection" {
	mock_cosign_failing 1 "Error: signature rejected by policy: identity not allowed"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(cosign_call_count)"
}

@test "sign-artifact: matches markers as fixed strings, not regexes" {
	# 'reading ID.token' only matches 'reading ID token' if the marker is
	# treated as a regex; with fixed-string matching this stays fatal.
	mock_cosign_failing 1 "Error: reading ID.token: bogus"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(cosign_call_count)"
}

@test "sign-artifact: does not retry a failure with no output" {
	mock_cosign_failing 1 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(cosign_call_count)"
}
