#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/sign-sbom-release-assets.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/sign-sbom-release-assets.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export PROJECT_ROOT
	export SCRIPT
	export SBOM_DIR="${BATS_TEST_TMPDIR}/sbom"
	mkdir -p "$SBOM_DIR"
	printf '{"bomFormat":"CycloneDX"}\n' >"${SBOM_DIR}/sbom.cyclonedx.json"
	printf '{"spdxVersion":"SPDX-2.3"}\n' >"${SBOM_DIR}/sbom.spdx.json"
	_stub_sleep
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_mock_cosign_bundle() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/cosign" <<'MOCK'
#!/usr/bin/env bash
bundle=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--bundle=*)
		bundle="${1#--bundle=}"
		shift
		;;
	--bundle)
		bundle="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
if [[ -n "$bundle" ]]; then
	echo '{"payload":"fake"}' >"$bundle"
fi
exit 0
MOCK
	chmod +x "${mock_bin}/cosign"
	export PATH="${mock_bin}:$PATH"
}

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

# Mock cosign so the first N invocations fail with the given stderr output and
# every later invocation writes the requested bundle. Calls are recorded.
# Usage: _mock_cosign_failing <fail_count> <failure_output>
_mock_cosign_failing() {
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
bundle=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	--bundle=*)
		bundle="\${1#--bundle=}"
		shift
		;;
	--bundle)
		bundle="\$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
[[ -n "\$bundle" ]] && echo '{"payload":"fake"}' >"\$bundle"
echo "tlog entry created"
EOF
	chmod +x "${mock_bin}/cosign"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

_cosign_call_count() {
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_cosign"
	[[ -f "$calls_file" ]] || {
		echo 0
		return 0
	}
	awk 'END { print NR }' "$calls_file"
}

_sleep_call_count() {
	awk 'END { print NR }' "${BATS_TEST_TMPDIR}/mock_calls_sleep"
}

@test "sign-sbom-release-assets: skips when sign is false" {
	run env SIGN=false bash "$SCRIPT"
	assert_success
	assert_output --partial "Skipping SBOM signing"
	[[ ! -f "${SBOM_DIR}/sbom.cyclonedx.json.bundle" ]]
}

@test "sign-sbom-release-assets: skips when sign is off" {
	run env SIGN=off bash "$SCRIPT"
	assert_success
	assert_output --partial "Skipping SBOM signing"
}

@test "sign-sbom-release-assets: signs sbom files when sign is true" {
	_mock_cosign_bundle
	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_output --partial "Successfully signed 2 SBOM file(s)"
	[[ -f "${SBOM_DIR}/sbom.cyclonedx.json.bundle" ]]
	[[ -f "${SBOM_DIR}/sbom.spdx.json.bundle" ]]
}

@test "sign-sbom-release-assets: fails when SBOM_DIR missing" {
	run env SBOM_DIR="${BATS_TEST_TMPDIR}/missing" SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::SBOM directory not found"
}

@test "sign-sbom-release-assets: fails when no sbom files present" {
	rm -f "${SBOM_DIR}"/*
	_mock_cosign_bundle
	run env SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::No SBOM files found to sign"
}

# =============================================================================
# Retry bounds validation
# =============================================================================

@test "sign-sbom-release-assets: signs exactly once per file on first success" {
	_mock_cosign_failing 0 ""

	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_output --partial "Successfully signed 2 SBOM file(s)"
	assert_equal "2" "$(_cosign_call_count)"
	assert_equal "0" "$(_sleep_call_count)"
}

@test "sign-sbom-release-assets: rejects non-numeric COSIGN_SIGN_MAX_ATTEMPTS" {
	_mock_cosign_failing 0 ""

	run env SIGN=true COSIGN_SIGN_MAX_ATTEMPTS=three bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be a non-negative integer"
	assert_equal "0" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: rejects zero COSIGN_SIGN_MAX_ATTEMPTS" {
	_mock_cosign_failing 0 ""

	run env SIGN=true COSIGN_SIGN_MAX_ATTEMPTS=0 bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_ATTEMPTS must be at least 1"
	assert_equal "0" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: rejects non-numeric COSIGN_SIGN_MAX_DELAY" {
	_mock_cosign_failing 0 ""

	run env SIGN=true COSIGN_SIGN_MAX_DELAY=-5 bash "$SCRIPT"
	assert_failure
	assert_output --partial "COSIGN_SIGN_MAX_DELAY must be a non-negative integer"
	assert_equal "0" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: accepts zero-padded retry knobs" {
	_mock_cosign_failing 3 "Error: fetching ambient OIDC credentials: no credentials found"

	run env SIGN=true COSIGN_SIGN_MAX_ATTEMPTS=04 COSIGN_SIGN_MAX_DELAY=08 bash "$SCRIPT"
	assert_success
	refute_output --partial "value too great for base"
	assert_equal "5" "$(_cosign_call_count)"
}

# =============================================================================
# Transient ambient-OIDC retry
# =============================================================================

@test "sign-sbom-release-assets: retries transient ambient OIDC failure" {
	_mock_cosign_failing 1 "Error: signing blob: getting signer: fetching ambient OIDC credentials: no credentials found"

	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_output --partial "Transient OIDC failure signing ${SBOM_DIR}/sbom.cyclonedx.json"
	assert_output --partial "Successfully signed 2 SBOM file(s)"
	# First file: fail then succeed (2 calls); second file: succeed (1 call).
	# Retry is per SBOM, so the first file is not signed a third time.
	assert_equal "3" "$(_cosign_call_count)"
	assert_equal "1" "$(_sleep_call_count)"
}

@test "sign-sbom-release-assets: retries 'retrieving ID token' failures" {
	_mock_cosign_failing 1 "Error: retrieving ID token: unexpected EOF"

	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_equal "3" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: retries 'reading ID token' failures" {
	_mock_cosign_failing 1 "Error: reading ID token: context deadline exceeded"

	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_equal "3" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: marker matching is case-insensitive" {
	_mock_cosign_failing 1 "Error: FETCHING Ambient OIDC Credentials: none available"

	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_equal "3" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: fails after exhausting attempts on persistent flake" {
	_mock_cosign_failing 99 "Error: fetching ambient OIDC credentials: no credentials found"

	run env SIGN=true COSIGN_SIGN_MAX_ATTEMPTS=2 bash "$SCRIPT"
	assert_failure
	assert_output --partial "cosign sign-blob failed for ${SBOM_DIR}/sbom.cyclonedx.json after 2 attempt(s)"
	assert_equal "2" "$(_cosign_call_count)"
	refute_output --partial "Successfully signed"
}

@test "sign-sbom-release-assets: caps backoff at COSIGN_SIGN_MAX_DELAY" {
	_mock_cosign_failing 3 "Error: fetching ambient OIDC credentials: no credentials found"

	run env SIGN=true COSIGN_SIGN_MAX_ATTEMPTS=4 COSIGN_SIGN_MAX_DELAY=1 bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_sleep"
	assert_output "1
1
1"
}

@test "sign-sbom-release-assets: keeps cosign output in the job log" {
	_mock_cosign_failing 1 "Error: fetching ambient OIDC credentials: no credentials found"

	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_output --partial "Error: fetching ambient OIDC credentials: no credentials found"
}

# =============================================================================
# Non-transient failures stay fatal
# =============================================================================

@test "sign-sbom-release-assets: does not retry an upload failure" {
	_mock_cosign_failing 1 "Error: uploading to rekor: 502 Bad Gateway"

	run env SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_output --partial "502 Bad Gateway"
	assert_equal "1" "$(_cosign_call_count)"
	assert_equal "0" "$(_sleep_call_count)"
}

@test "sign-sbom-release-assets: does not retry a policy rejection" {
	_mock_cosign_failing 1 "Error: signature rejected by policy: identity not allowed"

	run env SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: matches markers as fixed strings, not regexes" {
	# 'reading ID.token' only matches 'reading ID token' if the marker is
	# treated as a regex; with fixed-string matching this stays fatal.
	_mock_cosign_failing 1 "Error: reading ID.token: bogus"

	run env SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(_cosign_call_count)"
}

@test "sign-sbom-release-assets: does not retry a failure with no output" {
	_mock_cosign_failing 1 ""

	run env SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a transient OIDC token fetch, not retrying"
	assert_equal "1" "$(_cosign_call_count)"
}
