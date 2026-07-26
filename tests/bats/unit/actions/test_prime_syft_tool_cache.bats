#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/prime-syft-tool-cache.sh (#697)

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/prime-syft-tool-cache.sh"

SYFT_TEST_VERSION="1.42.3"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export PROJECT_ROOT
	export SCRIPT

	MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
	SERVER_DIR="${BATS_TEST_TMPDIR}/server"
	CURL_CALLS="${BATS_TEST_TMPDIR}/curl_calls"
	CURL_FAILS="${BATS_TEST_TMPDIR}/curl_fails"
	mkdir -p "$MOCK_BIN" "$SERVER_DIR"
	: >"$CURL_CALLS"
	printf '0\n' >"$CURL_FAILS"

	export RUNNER_TOOL_CACHE="${BATS_TEST_TMPDIR}/tool-cache"
	mkdir -p "$RUNNER_TOOL_CACHE"

	# Match the os/arch the script derives from uname so the fixture asset
	# names line up with the URLs it builds.
	SYFT_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
	case "$(uname -m)" in
	x86_64 | amd64)
		SYFT_GOARCH="amd64"
		SYFT_NODE_ARCH="x64"
		;;
	aarch64 | arm64)
		SYFT_GOARCH="arm64"
		SYFT_NODE_ARCH="arm64"
		;;
	*)
		skip "unsupported test host architecture: $(uname -m)"
		;;
	esac
	ARCHIVE_NAME="syft_${SYFT_TEST_VERSION}_${SYFT_OS}_${SYFT_GOARCH}.tar.gz"
	CHECKSUMS_NAME="syft_${SYFT_TEST_VERSION}_checksums.txt"
	TOOL_DIR="${RUNNER_TOOL_CACHE}/syft/${SYFT_TEST_VERSION}/${SYFT_NODE_ARCH}"

	_install_mocks
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# Build a syft release tarball plus a matching checksums.txt in the fake
# release server directory. Pass "mismatch" to publish a checksum that does not
# describe the served archive (the tampered/corrupt-artifact case).
_publish_release() {
	local mode="${1:-valid}"
	local build="${BATS_TEST_TMPDIR}/build"

	rm -rf "$build"
	mkdir -p "$build"
	printf '#!/usr/bin/env bash\necho "syft %s"\n' "$SYFT_TEST_VERSION" >"${build}/syft"
	chmod +x "${build}/syft"
	tar -czf "${SERVER_DIR}/${ARCHIVE_NAME}" -C "$build" syft

	local sum
	if [[ "$mode" == "mismatch" ]]; then
		sum="0000000000000000000000000000000000000000000000000000000000000000"
	else
		sum="$(_sha256_of "${SERVER_DIR}/${ARCHIVE_NAME}")"
	fi
	printf '%s  %s\n' "$sum" "$ARCHIVE_NAME" >"${SERVER_DIR}/${CHECKSUMS_NAME}"
}

# curl stub that serves files out of SERVER_DIR, records every requested URL,
# and can be told to fail the first N requests with curl's HTTP-error exit
# code (22) - what `curl -f` returns for a 504.
_install_mocks() {
	cat >"${MOCK_BIN}/curl" <<EOF
#!/usr/bin/env bash
url=""
out=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	-o) out="\$2"; shift 2 ;;
	--output) out="\$2"; shift 2 ;;
	http*) url="\$1"; shift ;;
	*) shift ;;
	esac
done
echo "\$url" >>'${CURL_CALLS}'
remaining=\$(cat '${CURL_FAILS}')
if ((remaining > 0)); then
	printf '%s\n' "\$((remaining - 1))" >'${CURL_FAILS}'
	exit 22
fi
name="\${url##*/}"
if [[ -f '${SERVER_DIR}'/"\$name" ]]; then
	cp '${SERVER_DIR}'/"\$name" "\$out"
	exit 0
fi
exit 22
EOF
	chmod +x "${MOCK_BIN}/curl"

	# Keep the exponential backoff from actually sleeping.
	printf '#!/usr/bin/env bash\nexit 0\n' >"${MOCK_BIN}/sleep"
	chmod +x "${MOCK_BIN}/sleep"

	export PATH="${MOCK_BIN}:$PATH"
}

_curl_call_count() {
	grep -c . "$CURL_CALLS" || true
}

_run_script() {
	run env \
		PATH="$PATH" \
		RUNNER_TOOL_CACHE="$RUNNER_TOOL_CACHE" \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		SYFT_VERSION="$SYFT_TEST_VERSION" \
		SYFT_DOWNLOAD_BASE_URL="https://example.invalid/releases/download" \
		"$@" \
		bash "$SCRIPT"
}

# =============================================================================
# Happy path
# =============================================================================

@test "prime-syft-tool-cache: populates the tool cache and completion marker" {
	_publish_release valid

	_run_script
	assert_success
	[[ -x "${TOOL_DIR}/syft" ]]
	[[ -f "${TOOL_DIR}.complete" ]]
}

@test "prime-syft-tool-cache: emits the resolved syft-version output" {
	_publish_release valid

	_run_script
	assert_success
	assert_github_output "syft-version" "v${SYFT_TEST_VERSION}"
}

@test "prime-syft-tool-cache: skips the download when the cache is already primed" {
	_publish_release valid
	mkdir -p "$TOOL_DIR"
	printf 'cached\n' >"${TOOL_DIR}/syft"
	chmod +x "${TOOL_DIR}/syft"
	touch "${TOOL_DIR}.complete"

	_run_script
	assert_success
	assert_equal "$(_curl_call_count)" "0"
}

# The marker is written last precisely so an interrupted prime leaves an
# unusable entry. A binary without it must be re-downloaded, not trusted:
# @actions/tool-cache also ignores the entry, so trusting it would mean
# sbom-action downloading anyway with no retry.
@test "prime-syft-tool-cache: re-primes a tool dir with no completion marker" {
	_publish_release valid
	mkdir -p "$TOOL_DIR"
	printf 'half-written\n' >"${TOOL_DIR}/syft"
	chmod +x "${TOOL_DIR}/syft"

	_run_script
	assert_success
	[[ -f "${TOOL_DIR}.complete" ]]
	! grep -qF "half-written" "${TOOL_DIR}/syft"
	# archive + checksums: the stale entry was not reused.
	assert_equal "$(_curl_call_count)" "2"
}

# @actions/tool-cache keys on semver.clean(), which drops build metadata. The
# asset name keeps it, so the two must be derived separately or cache.find()
# looks in a directory we never wrote.
@test "prime-syft-tool-cache: strips build metadata from the cache path only" {
	local meta_version="${SYFT_TEST_VERSION}+ci.1"
	ARCHIVE_NAME="syft_${meta_version}_${SYFT_OS}_${SYFT_GOARCH}.tar.gz"
	CHECKSUMS_NAME="syft_${meta_version}_checksums.txt"
	_publish_release valid

	_run_script SYFT_VERSION="$meta_version"
	assert_success
	# Cache path: build metadata stripped.
	[[ -x "${RUNNER_TOOL_CACHE}/syft/${SYFT_TEST_VERSION}/${SYFT_NODE_ARCH}/syft" ]]
	[[ -f "${RUNNER_TOOL_CACHE}/syft/${SYFT_TEST_VERSION}/${SYFT_NODE_ARCH}.complete" ]]
	[[ ! -e "${RUNNER_TOOL_CACHE}/syft/${meta_version}" ]]
	# Asset URL and the version handed to sbom-action: metadata retained.
	assert_github_output "syft-version" "v${meta_version}"
	grep -qF "$ARCHIVE_NAME" "$CURL_CALLS"
}

# =============================================================================
# Transport-level failures: retried
# =============================================================================

@test "prime-syft-tool-cache: retries a transient 5xx and then succeeds" {
	_publish_release valid
	printf '2\n' >"$CURL_FAILS"

	_run_script
	assert_success
	[[ -x "${TOOL_DIR}/syft" ]]
	[[ -f "${TOOL_DIR}.complete" ]]
	# 2 failed archive attempts + 1 success + 1 checksums fetch
	assert_equal "$(_curl_call_count)" "4"
}

@test "prime-syft-tool-cache: fails non-zero when the download never succeeds" {
	_publish_release valid
	printf '99\n' >"$CURL_FAILS"

	_run_script SYFT_DOWNLOAD_ATTEMPTS=3
	assert_failure
	assert_output --partial "Failed to download ${ARCHIVE_NAME} after 3 attempts"
	[[ ! -e "${TOOL_DIR}/syft" ]]
	[[ ! -e "${TOOL_DIR}.complete" ]]
	assert_equal "$(_curl_call_count)" "3"
}

@test "prime-syft-tool-cache: fails non-zero when the checksums file is unreachable" {
	_publish_release valid
	rm -f "${SERVER_DIR}/${CHECKSUMS_NAME}"

	_run_script SYFT_DOWNLOAD_ATTEMPTS=2
	assert_failure
	assert_output --partial "Failed to download Syft checksums after 2 attempts"
	[[ ! -e "${TOOL_DIR}.complete" ]]
}

# =============================================================================
# Integrity failures: fail closed, never retried
# =============================================================================

@test "prime-syft-tool-cache: checksum mismatch fails immediately with no retry" {
	_publish_release mismatch

	_run_script SYFT_DOWNLOAD_ATTEMPTS=3
	assert_failure
	assert_output --partial "checksum verification failed"
	# Exactly one archive fetch and one checksums fetch: a mismatch is a tamper
	# signal, so it must not be re-attempted.
	assert_equal "$(_curl_call_count)" "2"
	[[ ! -e "${TOOL_DIR}/syft" ]]
	[[ ! -e "${TOOL_DIR}.complete" ]]
}

@test "prime-syft-tool-cache: fails closed when no checksum covers the archive" {
	_publish_release valid
	printf 'deadbeef  some-other-file.tar.gz\n' >"${SERVER_DIR}/${CHECKSUMS_NAME}"

	_run_script
	assert_failure
	assert_output --partial "No checksum for ${ARCHIVE_NAME}"
	[[ ! -e "${TOOL_DIR}.complete" ]]
}

# =============================================================================
# Input validation
# =============================================================================

@test "prime-syft-tool-cache: rejects a non-semver SYFT_VERSION" {
	SYFT_TEST_VERSION="not-a-version"
	_run_script
	assert_failure
	assert_output --partial "Invalid Syft version"
	assert_equal "$(_curl_call_count)" "0"
}

@test "prime-syft-tool-cache: accepts a v-prefixed SYFT_VERSION" {
	_publish_release valid
	SYFT_TEST_VERSION="v${SYFT_TEST_VERSION}"

	_run_script
	assert_success
	assert_github_output "syft-version" "$SYFT_TEST_VERSION"
	[[ -f "${TOOL_DIR}.complete" ]]
}

@test "prime-syft-tool-cache: requires RUNNER_TOOL_CACHE" {
	_publish_release valid

	run env -u RUNNER_TOOL_CACHE \
		PATH="$PATH" \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		SYFT_VERSION="$SYFT_TEST_VERSION" \
		bash "$SCRIPT"
	assert_failure
	assert_output --partial "RUNNER_TOOL_CACHE is required"
}

# =============================================================================
# Renovate pin contract
# =============================================================================

@test "prime-syft-tool-cache: pinned syft version carries a renovate annotation" {
	run grep -B1 '^SYFT_PINNED_VERSION=' "$SCRIPT"
	assert_success
	assert_output --partial "# renovate: datasource=github-releases depName=anchore/syft"
}

# =============================================================================
# generate-sbom composite action wiring
# =============================================================================

@test "generate-sbom: primes the syft tool cache before invoking sbom-action" {
	run awk '
		/run: .*prime-syft-tool-cache\.sh/ && !prime { prime = NR }
		/uses: anchore\/sbom-action@/ && !sbom { sbom = NR }
		END { exit !(prime > 0 && sbom > 0 && prime < sbom) }
	' "${PROJECT_ROOT}/.github/actions/generate-sbom/action.yml"
	assert_success
}

@test "generate-sbom: pins sbom-action to the primed syft version" {
	run grep -F 'syft-version: ${{ steps.syft.outputs.syft-version }}' \
		"${PROJECT_ROOT}/.github/actions/generate-sbom/action.yml"
	assert_success
}
