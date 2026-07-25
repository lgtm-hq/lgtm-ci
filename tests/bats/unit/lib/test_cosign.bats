#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/cosign.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
	_stub_sleep
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# Local helpers
# =============================================================================

# Replace sleep with a no-op that records its delays so backoff can be
# asserted without the suite actually waiting.
_stub_sleep() {
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

# Create a fake signing command that fails its first N invocations with the
# given stderr output and succeeds afterwards, recording every call.
# Usage: _make_signer <fail_count> <failure_output>
_make_signer() {
	local fail_count="$1" fail_output="$2"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_signer"
	local counter_file="${mock_bin}/.signer_attempts"
	local output_file="${mock_bin}/.signer_fail_output"
	: >"$calls_file"
	echo 0 >"$counter_file"
	printf '%s\n' "$fail_output" >"$output_file"

	cat >"${mock_bin}/fake-signer" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${calls_file}'
attempts=\$(cat '${counter_file}')
attempts=\$((attempts + 1))
echo "\$attempts" >'${counter_file}'
if [[ "\$attempts" -le ${fail_count} ]]; then
	cat '${output_file}' >&2
	exit 7
fi
echo "signed"
EOF
	chmod +x "${mock_bin}/fake-signer"
}

_signer_call_count() {
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_signer"
	[[ -f "$calls_file" ]] || {
		echo 0
		return 0
	}
	awk 'END { print NR }' "$calls_file"
}

# =============================================================================
# Library contract
# =============================================================================

@test "cosign.sh: exports its public functions" {
	source "$LIB_DIR/cosign.sh"
	assert_function_exported "cosign_transient_oidc_marker"
	assert_function_exported "cosign_validate_retry_bounds"
	assert_function_exported "cosign_sign_with_retry"
}

@test "cosign.sh: is safe to source twice" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && source "$LIB_DIR/cosign.sh" && echo ok'
	assert_success
	assert_output "ok"
}

@test "cosign.sh: marker list is readonly" {
	source "$LIB_DIR/cosign.sh"
	assert_readonly_var "COSIGN_OIDC_TRANSIENT_MARKERS"
}

# =============================================================================
# cosign_transient_oidc_marker
# =============================================================================

@test "cosign_transient_oidc_marker: matches ambient OIDC credentials" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_transient_oidc_marker "Error: getting signer: fetching ambient OIDC credentials: none"'
	assert_success
	assert_output "fetching ambient OIDC credentials"
}

@test "cosign_transient_oidc_marker: matches retrieving ID token" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_transient_oidc_marker "Error: retrieving ID token: EOF"'
	assert_success
	assert_output "retrieving ID token"
}

@test "cosign_transient_oidc_marker: matches reading ID token" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_transient_oidc_marker "Error: reading ID token: timeout"'
	assert_success
	assert_output "reading ID token"
}

@test "cosign_transient_oidc_marker: is case-insensitive" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_transient_oidc_marker "READING id TOKEN: nope"'
	assert_success
	assert_output "reading ID token"
}

@test "cosign_transient_oidc_marker: treats markers as fixed strings" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_transient_oidc_marker "Error: reading ID.token: bogus"'
	assert_failure
	refute_output
}

@test "cosign_transient_oidc_marker: rejects unrelated failures" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_transient_oidc_marker "Error: manifest unknown"'
	assert_failure
}

@test "cosign_transient_oidc_marker: rejects empty output" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_transient_oidc_marker ""'
	assert_failure
}

# =============================================================================
# cosign_validate_retry_bounds
# =============================================================================

@test "cosign_validate_retry_bounds: applies defaults when unset" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_validate_retry_bounds && echo "$COSIGN_SIGN_MAX_ATTEMPTS $COSIGN_SIGN_MAX_DELAY"'
	assert_success
	assert_output "3 30"
}

@test "cosign_validate_retry_bounds: normalises zero-padded values to base 10" {
	run env COSIGN_SIGN_MAX_ATTEMPTS=04 COSIGN_SIGN_MAX_DELAY=08 \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_validate_retry_bounds && echo "$COSIGN_SIGN_MAX_ATTEMPTS $COSIGN_SIGN_MAX_DELAY"'
	assert_success
	assert_output "4 8"
}

@test "cosign_validate_retry_bounds: allows zero delay" {
	run env COSIGN_SIGN_MAX_DELAY=0 \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_validate_retry_bounds && echo "$COSIGN_SIGN_MAX_DELAY"'
	assert_success
	assert_output "0"
}

@test "cosign_validate_retry_bounds: rejects non-numeric attempts" {
	run env COSIGN_SIGN_MAX_ATTEMPTS=three \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_validate_retry_bounds'
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be a non-negative integer"
}

@test "cosign_validate_retry_bounds: rejects zero attempts" {
	run env COSIGN_SIGN_MAX_ATTEMPTS=0 \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_validate_retry_bounds'
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be at least 1"
}

@test "cosign_validate_retry_bounds: rejects negative delay" {
	run env COSIGN_SIGN_MAX_DELAY=-1 \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_validate_retry_bounds'
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_DELAY must be a non-negative integer"
}

# =============================================================================
# cosign_sign_with_retry
# =============================================================================

@test "cosign_sign_with_retry: runs the command once on success" {
	_make_signer 0 ""

	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign-blob" "blob.txt" fake-signer sign-blob blob.txt'
	assert_success
	assert_output --partial "signed"
	assert_equal "1" "$(_signer_call_count)"
	run grep -Fx "sign-blob blob.txt" "${BATS_TEST_TMPDIR}/mock_calls_signer"
	assert_success
}

@test "cosign_sign_with_retry: retries a transient OIDC failure then succeeds" {
	_make_signer 1 "Error: fetching ambient OIDC credentials: none"

	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign-blob" "blob.txt" fake-signer blob.txt'
	assert_success
	assert_output --partial "Transient OIDC failure signing blob.txt (attempt 1/3"
	assert_equal "2" "$(_signer_call_count)"
}

@test "cosign_sign_with_retry: stops after COSIGN_SIGN_MAX_ATTEMPTS" {
	_make_signer 99 "Error: fetching ambient OIDC credentials: none"

	run env COSIGN_SIGN_MAX_ATTEMPTS=2 \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign-blob" "blob.txt" fake-signer blob.txt'
	assert_failure
	assert_output --partial "cosign sign-blob failed for blob.txt after 2 attempt(s)"
	assert_output --partial "matched 'fetching ambient OIDC credentials'"
	assert_equal "2" "$(_signer_call_count)"
}

@test "cosign_sign_with_retry: keeps a non-transient failure fatal on attempt 1" {
	_make_signer 99 "Error: signature rejected by policy"

	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign" "img@sha256:abc" fake-signer img'
	assert_failure
	assert_output --partial "cosign sign failed for img@sha256:abc on attempt 1 (exit 7)"
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(_signer_call_count)"
}

@test "cosign_sign_with_retry: echoes command output instead of swallowing it" {
	_make_signer 1 "Error: fetching ambient OIDC credentials: none"

	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign-blob" "blob.txt" fake-signer blob.txt'
	assert_success
	assert_output --partial "Error: fetching ambient OIDC credentials: none"
}

@test "cosign_sign_with_retry: backs off exponentially up to the cap" {
	_make_signer 3 "Error: fetching ambient OIDC credentials: none"

	run env COSIGN_SIGN_MAX_ATTEMPTS=4 COSIGN_SIGN_MAX_DELAY=2 \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign-blob" "blob.txt" fake-signer blob.txt'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_sleep"
	assert_output "1
2
2"
}

@test "cosign_sign_with_retry: honours a zero delay cap" {
	_make_signer 1 "Error: fetching ambient OIDC credentials: none"

	run env COSIGN_SIGN_MAX_DELAY=0 \
		bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign-blob" "blob.txt" fake-signer blob.txt'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_sleep"
	assert_output "0"
}

@test "cosign_sign_with_retry: fails loudly when given no command" {
	run bash -c 'source "$LIB_DIR/cosign.sh" && cosign_sign_with_retry "cosign sign-blob" "blob.txt"'
	assert_failure
	assert_output --partial "no command given"
}
