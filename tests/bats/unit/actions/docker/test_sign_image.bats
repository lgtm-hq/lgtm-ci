#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/sign-image.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/sign-image.sh"
VALID_DIGEST="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export DIGEST="$VALID_DIGEST"
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

# Mock cosign so the first N invocations fail with the given stderr output and
# every later invocation succeeds. Calls are recorded per invocation.
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
# Happy path and input validation
# =============================================================================

@test "sign-image.sh: signs image digest with cosign" {
	mock_command_record "cosign"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Signed image: ghcr.io/org/repo@${VALID_DIGEST}"
	run grep -Fx "sign --yes ghcr.io/org/repo@${VALID_DIGEST}" "${BATS_TEST_TMPDIR}/mock_calls_cosign"
	assert_success
}

@test "sign-image.sh: signs exactly once when the first attempt succeeds" {
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(cosign_call_count)"
	assert_equal "0" "$(sleep_call_count)"
}

@test "sign-image.sh: rejects invalid digest" {
	export DIGEST="not-a-digest"
	mock_command_record "cosign"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST is not a valid sha256 digest"
}

@test "sign-image.sh: fails when cosign is missing" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local bash_path cmd
	mkdir -p "$mock_bin"
	bash_path="$(command -v bash)"
	# Minimal PATH with coreutils but no cosign (may live under /usr/bin on some runners).
	for cmd in dirname uname tr; do
		ln -sf "$(command -v "$cmd")" "${mock_bin}/${cmd}"
	done
	run env PATH="${mock_bin}" "$bash_path" "$SCRIPT"
	assert_failure
	assert_output --partial "cosign not found"
}

@test "sign-image.sh: requires DIGEST" {
	unset DIGEST || true
	mock_command_record "cosign"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIGEST is required"
}

@test "sign-image.sh: rejects non-numeric COSIGN_SIGN_MAX_ATTEMPTS" {
	export COSIGN_SIGN_MAX_ATTEMPTS="three"
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be a non-negative integer"
	assert_equal "0" "$(cosign_call_count)"
}

@test "sign-image.sh: rejects zero COSIGN_SIGN_MAX_ATTEMPTS" {
	export COSIGN_SIGN_MAX_ATTEMPTS="0"
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be at least 1"
	assert_equal "0" "$(cosign_call_count)"
}

@test "sign-image.sh: rejects non-numeric COSIGN_SIGN_MAX_DELAY" {
	export COSIGN_SIGN_MAX_DELAY="-5"
	mock_cosign_failing 0 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_DELAY must be a non-negative integer"
	assert_equal "0" "$(cosign_call_count)"
}

# =============================================================================
# Transient ambient-OIDC retry
# =============================================================================

@test "sign-image.sh: retries transient ambient OIDC failure and succeeds" {
	mock_cosign_failing 1 "Error: signing [ghcr.io/org/repo]: getting signer: getting key from Fulcio: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Transient OIDC failure signing ghcr.io/org/repo@${VALID_DIGEST}"
	assert_output --partial "Signed image: ghcr.io/org/repo@${VALID_DIGEST}"
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-image.sh: retries 'retrieving ID token' failures" {
	mock_cosign_failing 1 "Error: retrieving ID token: unexpected EOF"

	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-image.sh: retries 'reading ID token' failures" {
	mock_cosign_failing 1 "Error: reading ID token: context deadline exceeded"

	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-image.sh: marker matching is case-insensitive" {
	mock_cosign_failing 1 "Error: FETCHING Ambient OIDC Credentials: none available"

	run bash "$SCRIPT"
	assert_success
	assert_equal "2" "$(cosign_call_count)"
}

@test "sign-image.sh: fails after exhausting attempts on persistent OIDC flake" {
	export COSIGN_SIGN_MAX_ATTEMPTS="2"
	mock_cosign_failing 99 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "after 2 attempt(s)"
	assert_output --partial "ghcr.io/org/repo@${VALID_DIGEST}"
	assert_equal "2" "$(cosign_call_count)"
	refute_output --partial "Signed image:"
}

@test "sign-image.sh: honours COSIGN_SIGN_MAX_ATTEMPTS above the default" {
	export COSIGN_SIGN_MAX_ATTEMPTS="4"
	mock_cosign_failing 3 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	assert_equal "4" "$(cosign_call_count)"
}

@test "sign-image.sh: caps backoff at COSIGN_SIGN_MAX_DELAY" {
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

@test "sign-image.sh: keeps cosign output in the job log" {
	mock_cosign_failing 1 "Error: fetching ambient OIDC credentials: no credentials found"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Error: fetching ambient OIDC credentials: no credentials found"
}

# =============================================================================
# Non-transient failures stay fatal
# =============================================================================

@test "sign-image.sh: does not retry a registry failure" {
	mock_cosign_failing 1 "Error: signing [ghcr.io/org/repo]: accessing entity: manifest unknown"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_output --partial "manifest unknown"
	assert_equal "1" "$(cosign_call_count)"
	assert_equal "0" "$(sleep_call_count)"
}

@test "sign-image.sh: does not retry a policy rejection" {
	mock_cosign_failing 1 "Error: signature rejected by policy: identity not allowed"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(cosign_call_count)"
}

@test "sign-image.sh: matches markers as fixed strings, not regexes" {
	# 'reading ID.token' only matches 'reading ID token' if the marker is
	# treated as a regex; with fixed-string matching this stays fatal.
	mock_cosign_failing 1 "Error: reading ID.token: bogus"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(cosign_call_count)"
}

@test "sign-image.sh: does not retry a failure with no output" {
	mock_cosign_failing 1 ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(cosign_call_count)"
}
