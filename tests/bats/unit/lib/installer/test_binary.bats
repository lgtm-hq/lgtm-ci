#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/installer/binary.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export BIN_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN_DIR"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# Helper to create mock download that writes an archive
# =============================================================================

create_mock_download_binary() {
	local binary_name="${1:-mytool}"
	local binary_content="${2:-#!/bin/bash\necho mytool}"

	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"

	# Create a real tar.gz archive with an executable
	local archive_dir="${BATS_TEST_TMPDIR}/archive_content"
	mkdir -p "$archive_dir"
	printf '%b' "$binary_content" >"$archive_dir/$binary_name"
	chmod +x "$archive_dir/$binary_name"

	local archive_file="${BATS_TEST_TMPDIR}/archive.tar.gz"
	tar -czf "$archive_file" -C "$archive_dir" "$binary_name"

	# Mock curl to copy the archive
	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        --output) output_file="\$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "\$output_file" ]]; then
    cp "$archive_file" "\$output_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"
}

create_mock_checksum_file() {
	local archive_file="${BATS_TEST_TMPDIR}/archive.tar.gz"
	local checksum
	if command -v sha256sum &>/dev/null; then
		checksum=$(sha256sum "$archive_file" | awk '{print $1}')
	elif command -v shasum &>/dev/null; then
		checksum=$(shasum -a 256 "$archive_file" | awk '{print $1}')
	else
		skip "no sha256sum or shasum available"
	fi

	# Update mock to serve checksum file on second call
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"
	local call_count_file="${mock_bin}/.curl_call_count"
	echo "0" >"$call_count_file"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
call_count=\$(cat "$call_count_file")
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        --output) output_file="\$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "\$output_file" ]]; then
    if [[ \$call_count -eq 0 ]]; then
        # First call: serve archive
        cp "${BATS_TEST_TMPDIR}/archive.tar.gz" "\$output_file"
    else
        # Second call: serve checksum
        echo "$checksum  archive.tar.gz" > "\$output_file"
    fi
    echo \$((\$call_count + 1)) > "$call_count_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"
}

# Mock curl for install_anchore_tool flows:
# - records all invocations to $BATS_TEST_TMPDIR/mock_calls_curl
# - answers releases/latest resolution (-w '%{url_effective}') with .../tag/v9.9.9
# - writes the given installer script body to the -o output file otherwise
# Usage: create_anchore_curl_mock "installer script body"
create_anchore_curl_mock() {
	local installer_body="$1"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_curl"
	: >"$calls_file"

	local installer_file="${mock_bin}/.fake_installer"
	printf '%s\n' "$installer_body" >"$installer_file"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${calls_file}'
output_file=""
url=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        -w) shift 2;;
        http*) url="\$1"; shift;;
        *) shift;;
    esac
done
if [[ "\$url" == *"/releases/latest"* ]]; then
    # Simulate the redirect target reported via -w '%{url_effective}'
    printf '%s' "\${url%/latest}/tag/v9.9.9"
    exit 0
fi
if [[ -n "\$output_file" ]]; then
    cat '${installer_file}' >"\$output_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# =============================================================================
# installer_download_binary tests - basic functionality
# =============================================================================

@test "installer_download_binary: downloads and installs tar.gz archive" {
	require_bash4
	create_mock_download_binary "mytool" '#!/bin/bash\necho "mytool v1.0"'

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		export TOOL_NAME='mytool'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/mytool.tar.gz' '' 'tar.gz' 'mytool' 2>&1
	"
	assert_success
	assert_output --partial "installed to"

	# Verify binary exists and is executable
	[[ -x "$BIN_DIR/mytool" ]]
}

@test "installer_download_binary: uses TOOL_NAME as default binary name" {
	require_bash4
	create_mock_download_binary "defaulttool" '#!/bin/bash\necho "default"'

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		export TOOL_NAME='defaulttool'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' '' 'tar.gz' 2>&1
	"
	assert_success
	[[ -x "$BIN_DIR/defaulttool" ]]
}

@test "installer_download_binary: verifies checksum when URL provided" {
	require_bash4
	create_mock_download_binary "mytool" '#!/bin/bash\necho "tool"'
	create_mock_checksum_file

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		export VERBOSE=1
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' 'https://example.com/checksums.txt' 'tar.gz' 'mytool' 2>&1
	"
	assert_success
	assert_output --partial "Checksum verified"
}

@test "installer_download_binary: fails on checksum mismatch" {
	require_bash4
	create_mock_download_binary "mytool" '#!/bin/bash\necho "tool"'

	# Mock curl to return wrong checksum
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"

	cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
call_count=$(cat "${0}_call_count" 2>/dev/null || echo 0)
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2;;
        --output) output_file="$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "$output_file" ]]; then
    if [[ $call_count -eq 0 ]]; then
        echo "archive content" > "$output_file"
    else
        echo "wrongchecksum  archive.tar.gz" > "$output_file"
    fi
    echo $((call_count + 1)) > "${0}_call_count"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' 'https://example.com/checksums.txt' 'tar.gz' 'mytool' 2>&1
	"
	assert_failure
	assert_output --partial "Checksum verification failed"
}

@test "installer_download_binary: skips checksum with ALLOW_UNVERIFIED=1" {
	require_bash4
	create_mock_download_binary "mytool" '#!/bin/bash\necho "tool"'

	# Mock curl to fail on checksum download
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	local call_count_file="${mock_bin}/.curl_call_count"
	echo "0" >"$call_count_file"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
call_count=\$(cat "$call_count_file")
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        --output) output_file="\$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "\$output_file" ]]; then
    if [[ \$call_count -eq 0 ]]; then
        cp "${BATS_TEST_TMPDIR}/archive.tar.gz" "\$output_file"
        echo 1 > "$call_count_file"
        exit 0
    else
        exit 1  # Fail checksum download
    fi
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		export ALLOW_UNVERIFIED=1
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' 'https://example.com/checksums.txt' 'tar.gz' 'mytool' 2>&1
	"
	assert_success
	assert_output --partial "skipping verification"
}

# =============================================================================
# installer_download_binary tests - archive types
# =============================================================================

@test "installer_download_binary: handles binary type (raw binary)" {
	require_bash4
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"

	# Create mock that writes a raw binary
	cat >"${mock_bin}/curl" <<'EOF'
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
    printf '#!/bin/bash\necho "raw binary"' > "$output_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/mytool' '' 'binary' 'mytool' 2>&1
	"
	assert_success
	[[ -x "$BIN_DIR/mytool" ]]
}

@test "installer_download_binary: handles zip archives" {
	require_bash4
	# Skip if zip/unzip not available
	command -v zip >/dev/null 2>&1 || skip "zip command not available"
	command -v unzip >/dev/null 2>&1 || skip "unzip command not available"

	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"

	# Create a real zip archive
	local archive_dir="${BATS_TEST_TMPDIR}/archive_content"
	mkdir -p "$archive_dir"
	printf '#!/bin/bash\necho "zip binary"' >"$archive_dir/ziptool"
	chmod +x "$archive_dir/ziptool"

	local archive_file="${BATS_TEST_TMPDIR}/archive.zip"
	(cd "$archive_dir" && zip -q "$archive_file" ziptool)

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        --output) output_file="\$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "\$output_file" ]]; then
    cp "$archive_file" "\$output_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.zip' '' 'zip' 'ziptool' 2>&1
	"
	assert_success
	[[ -x "$BIN_DIR/ziptool" ]]
}

@test "installer_download_binary: fails on unknown archive type" {
	require_bash4
	mock_curl_download "content"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.unknown' '' 'rar' 'mytool' 2>&1
	"
	assert_failure
	assert_output --partial "Unknown archive type"
}

# =============================================================================
# installer_download_binary tests - error handling
# =============================================================================

@test "installer_download_binary: fails on download error" {
	mock_command "curl" "" 1

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' '' 'tar.gz' 'mytool' 2>&1
	"
	assert_failure
}

@test "installer_download_binary: fails on extraction error" {
	require_bash4
	# Create mock that writes invalid archive content
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "$output_file" ]]; then
    echo "not a valid archive" > "$output_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' '' 'tar.gz' 'mytool' 2>&1
	"
	assert_failure
	assert_output --partial "extraction failed"
}

@test "installer_download_binary: cleans up temp directory on failure" {
	require_bash4
	mock_command "curl" "" 1

	# Count temp dirs before
	local tmpdir_before
	tmpdir_before=$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name "lgtm-binary.*" -type d 2>/dev/null | wc -l || echo "0")

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		export TMPDIR='$BATS_TEST_TMPDIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' '' 'tar.gz' 'mytool' 2>&1
	"
	assert_failure

	# Count temp dirs after
	local tmpdir_after
	tmpdir_after=$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name "lgtm-binary.*" -type d 2>/dev/null | wc -l || echo "0")

	# Should have cleaned up (no increase in temp dirs)
	[[ "$tmpdir_after" -le "$tmpdir_before" ]]
}

# =============================================================================
# install_anchore_tool tests
# =============================================================================

@test "install_anchore_tool: rejects unknown tool" {
	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "unknown-tool" 2>&1
	'
	assert_failure
	assert_output --partial "Unknown Anchore tool"
	assert_output --partial "supported: syft, grype"
}

@test "install_anchore_tool: accepts syft" {
	# Mock syft as already installed
	mock_command "syft" "Application: syft\nVersion: 1.0.0" 0

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "latest" 2>&1
	'
	assert_success
	assert_output --partial "syft already installed"
}

@test "install_anchore_tool: accepts grype" {
	# Mock grype as already installed
	mock_command "grype" "Application: grype\nVersion: 1.0.0" 0

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "grype" "latest" 2>&1
	'
	assert_success
	assert_output --partial "grype already installed"
}

@test "install_anchore_tool: skips install when already installed with matching version" {
	mock_command "syft" "Application: syft\nVersion: 0.90.0" 0

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "0.90.0" 2>&1
	'
	assert_success
	assert_output --partial "already installed"
}

@test "install_anchore_tool: reinstalls when version mismatch using pinned installer" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local flag_file="${BATS_TEST_TMPDIR}/installed_flag"

	# syft reports the old version until the fake installer runs
	cat >"${mock_bin}/syft" <<EOF
#!/usr/bin/env bash
if [[ -f "$flag_file" ]]; then
    echo "Application: syft"
    echo "Version: 0.90.0"
else
    echo "Application: syft"
    echo "Version: 0.80.0"
fi
exit 0
EOF
	chmod +x "${mock_bin}/syft"

	create_anchore_curl_mock "#!/usr/bin/env bash
touch '$flag_file'
"

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "0.90.0" 2>&1
	'
	assert_success
	# Should attempt reinstall due to version mismatch
	assert_output --partial "version mismatch"

	# Verify the downloaded (not piped) installer actually ran
	[[ -f "$flag_file" ]]

	# Verify the installer was fetched from the tag-pinned URL
	run cat "$BATS_TEST_TMPDIR/mock_calls_curl"
	assert_output --partial "raw.githubusercontent.com/anchore/syft/v0.90.0/install.sh"
	refute_output --partial "/main/install.sh"
}

@test "install_anchore_tool: requests tag-pinned installer URL for explicit version" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"

	# Remove any existing syft mock so it's "not installed"
	rm -f "${mock_bin}/syft"

	create_anchore_curl_mock "#!/usr/bin/env bash
cat >'${mock_bin}/syft' <<'INNER'
#!/usr/bin/env bash
echo \"Application: syft\"
echo \"Version: 1.2.3\"
INNER
chmod +x '${mock_bin}/syft'
"

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "1.2.3" 2>&1
	'
	assert_success

	run cat "$BATS_TEST_TMPDIR/mock_calls_curl"
	assert_output --partial "raw.githubusercontent.com/anchore/syft/v1.2.3/install.sh"
	refute_output --partial "/main/install.sh"
}

@test "install_anchore_tool: resolves latest to a pinned tag before install" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"

	# Ensure grype is "not installed"
	rm -f "${mock_bin}/grype"
	command -v grype >/dev/null 2>&1 && skip "grype installed on host"

	create_anchore_curl_mock "#!/usr/bin/env bash
cat >'${mock_bin}/grype' <<'INNER'
#!/usr/bin/env bash
echo \"Application: grype\"
echo \"Version: 9.9.9\"
INNER
chmod +x '${mock_bin}/grype'
"

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "grype" "latest" 2>&1
	'
	assert_success

	run cat "$BATS_TEST_TMPDIR/mock_calls_curl"
	assert_output --partial "github.com/anchore/grype/releases/latest"
	assert_output --partial "raw.githubusercontent.com/anchore/grype/v9.9.9/install.sh"
	refute_output --partial "/main/install.sh"
}

@test "install_anchore_tool: fails when latest release cannot be resolved" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	rm -f "${mock_bin}/syft"
	command -v syft >/dev/null 2>&1 && skip "syft installed on host"

	# curl fails for every request
	mock_command "curl" "" 22

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "latest" 2>&1
	'
	assert_failure
	assert_output --partial "Failed to resolve latest release"
}

@test "binary.sh: does not pipe remote content to a shell" {
	run grep -nE '^[^#]*curl[^|#]*\|[[:space:]]*(ba)?sh' "$LIB_DIR/installer/binary.sh"
	assert_failure
}

@test "install_anchore_tool: defaults to latest version" {
	mock_command "syft" "Application: syft\nVersion: 1.0.0" 0

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" 2>&1
	'
	assert_success
	# With latest, should accept any installed version
	assert_output --partial "already installed"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "binary.sh: exports installer_download_binary function" {
	run bash -c 'source "$LIB_DIR/installer/binary.sh" && declare -F installer_download_binary'
	assert_success
}

@test "binary.sh: exports install_anchore_tool function" {
	run bash -c 'source "$LIB_DIR/installer/binary.sh" && declare -F install_anchore_tool'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "binary.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		source "$LIB_DIR/installer/binary.sh"
		source "$LIB_DIR/installer/binary.sh"
		declare -F installer_download_binary >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "binary.sh: sets _LGTM_CI_INSTALLER_BINARY_LOADED guard" {
	run bash -c 'source "$LIB_DIR/installer/binary.sh" && echo "${_LGTM_CI_INSTALLER_BINARY_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Fallback function tests
# =============================================================================

@test "binary.sh: provides fallback download function when network/download.sh unavailable" {
	run bash -c '
		mkdir -p "$BATS_TEST_TMPDIR/isolated/installer"
		cp "$LIB_DIR/installer/binary.sh" "$BATS_TEST_TMPDIR/isolated/installer/"
		cd "$BATS_TEST_TMPDIR/isolated"
		source installer/binary.sh
		declare -F download_with_retries >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "binary.sh: provides fallback verify_checksum when network/checksum.sh unavailable" {
	run bash -c '
		mkdir -p "$BATS_TEST_TMPDIR/isolated/installer"
		cp "$LIB_DIR/installer/binary.sh" "$BATS_TEST_TMPDIR/isolated/installer/"
		cd "$BATS_TEST_TMPDIR/isolated"
		source installer/binary.sh
		declare -F verify_checksum >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "binary.sh: provides fallback log functions when log.sh unavailable" {
	run bash -c '
		mkdir -p "$BATS_TEST_TMPDIR/isolated/installer"
		cp "$LIB_DIR/installer/binary.sh" "$BATS_TEST_TMPDIR/isolated/installer/"
		cd "$BATS_TEST_TMPDIR/isolated"
		source installer/binary.sh
		declare -F log_verbose >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Integration tests
# =============================================================================

@test "binary.sh: sources log.sh when available" {
	run bash -c 'source "$LIB_DIR/installer/binary.sh" && declare -F log_info'
	assert_success
}

@test "binary.sh: sources fs.sh when available" {
	run bash -c 'source "$LIB_DIR/installer/binary.sh" && declare -F ensure_directory'
	assert_success
}

# =============================================================================
# installer_download_binary tests - extraction and checksum edge cases
# =============================================================================

# Mock curl that serves arbitrary content for every -o download
create_mock_curl_serving() {
	local first_content="$1"
	local second_content="${2-}"

	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"
	local call_count_file="${mock_bin}/.curl_call_count"
	echo "0" >"$call_count_file"
	printf '%s' "$first_content" >"${mock_bin}/.first_payload"
	printf '%s' "$second_content" >"${mock_bin}/.second_payload"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
call_count=\$(cat "$call_count_file")
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        --output) output_file="\$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "\$output_file" ]]; then
    if [[ \$call_count -eq 0 ]]; then
        cat "${mock_bin}/.first_payload" > "\$output_file"
    else
        cat "${mock_bin}/.second_payload" > "\$output_file"
    fi
    echo \$((\$call_count + 1)) > "$call_count_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"
}

@test "installer_download_binary: fails on tar.xz extraction error" {
	require_bash4
	create_mock_curl_serving "not a tar.xz archive"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.xz' '' 'tar.xz' 'mytool' 2>&1
	"
	assert_failure
	assert_output --partial "tar.xz extraction failed"
}

@test "installer_download_binary: fails on zip extraction error" {
	require_bash4
	create_mock_curl_serving "not a zip archive"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.zip' '' 'zip' 'mytool' 2>&1
	"
	assert_failure
	assert_output --partial "zip extraction failed"
}

@test "installer_download_binary: fails when checksum file cannot be parsed" {
	require_bash4
	create_mock_download_binary "mytool" '#!/bin/bash\necho "tool"'
	create_mock_curl_serving "archive content" ""

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' 'https://example.com/checksums.txt' 'tar.gz' 'mytool' 2>&1
	"
	assert_failure
	assert_output --partial "Could not parse checksum"
}

@test "installer_download_binary: unparseable checksum passes with ALLOW_UNVERIFIED=1" {
	require_bash4
	local archive_dir="${BATS_TEST_TMPDIR}/xdir"
	mkdir -p "$archive_dir"
	printf '#!/bin/bash\necho tool\n' >"$archive_dir/mytool"
	chmod +x "$archive_dir/mytool"
	tar -czf "${BATS_TEST_TMPDIR}/good.tar.gz" -C "$archive_dir" mytool
	create_mock_curl_serving "placeholder" ""
	# Binary-safe payload: overwrite first payload with the real archive bytes
	cp "${BATS_TEST_TMPDIR}/good.tar.gz" "${BATS_TEST_TMPDIR}/mock_bin/.first_payload"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		export ALLOW_UNVERIFIED=1
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' 'https://example.com/checksums.txt' 'tar.gz' 'mytool' 2>&1
	"
	assert_success
	assert_output --partial "Could not parse checksum, skipping verification"
}

@test "installer_download_binary: fails when checksum download fails without ALLOW_UNVERIFIED" {
	require_bash4

	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"
	local call_count_file="${mock_bin}/.curl_call_count"
	echo "0" >"$call_count_file"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
call_count=\$(cat "$call_count_file")
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        *) shift;;
    esac
done
echo \$((\$call_count + 1)) > "$call_count_file"
if [[ \$call_count -eq 0 ]]; then
    [[ -n "\$output_file" ]] && echo "archive content" > "\$output_file"
    exit 0
fi
exit 22
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' 'https://example.com/checksums.txt' 'tar.gz' 'mytool' 2>&1
	"
	assert_failure
	assert_output --partial "Could not download checksum"
}

@test "installer_download_binary: fails when binary missing from archive" {
	require_bash4
	create_mock_download_binary "othertool" '#!/bin/bash\necho other'

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/tool.tar.gz' '' 'tar.gz' 'missingtool' 2>&1
	"
	assert_failure
}

@test "installer_download_binary: falls back to mkdir when mktemp fails" {
	require_bash4
	create_mock_download_binary "mytool" '#!/bin/bash\necho "mytool"'

	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	cat >"${mock_bin}/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "${mock_bin}/mktemp"

	run bash -c "
		export BIN_DIR='$BIN_DIR'
		source \"\$LIB_DIR/installer/binary.sh\"
		installer_download_binary 'https://example.com/mytool.tar.gz' '' 'tar.gz' 'mytool' 2>&1
	"
	assert_success
	assert_output --partial "installed to"
	[[ -x "$BIN_DIR/mytool" ]]
}

# =============================================================================
# install_anchore_tool tests - failure paths
# =============================================================================

@test "install_anchore_tool: fails when latest resolves to a non-version URL" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	rm -f "${mock_bin}/syft"
	command -v syft >/dev/null 2>&1 && skip "syft installed on host"

	mkdir -p "$mock_bin"
	cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        http*) url="$1"; shift;;
        *) shift;;
    esac
done
if [[ "$url" == *"/releases/latest"* ]]; then
    printf '%s' "${url%/latest}"
    exit 0
fi
exit 22
EOF
	chmod +x "${mock_bin}/curl"
	[[ ":$PATH:" != *":${mock_bin}:"* ]] && export PATH="${mock_bin}:$PATH"

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "latest" 2>&1
	'
	assert_failure
	assert_output --partial "Could not determine latest version"
}

@test "install_anchore_tool: fails when installer script exits non-zero" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	rm -f "${mock_bin}/syft"
	command -v syft >/dev/null 2>&1 && skip "syft installed on host"

	create_anchore_curl_mock '#!/usr/bin/env bash
exit 1'

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "v1.2.3" 2>&1
	'
	assert_failure
	assert_output --partial "Failed to install syft"
}

@test "install_anchore_tool: fails when tool missing after installer succeeds" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	rm -f "${mock_bin}/syft"
	command -v syft >/dev/null 2>&1 && skip "syft installed on host"

	create_anchore_curl_mock '#!/usr/bin/env bash
exit 0'

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "v1.2.3" 2>&1
	'
	assert_failure
	assert_output --partial "not found in PATH"
}

# =============================================================================
# _lgtm_ci_installer_build_curl_args (hardened fallback curl args)
# =============================================================================

@test "installer curl args: baseline includes TLS floor and https-only" {
	run bash -c 'source "$LIB_DIR/installer/binary.sh" &&
		_lgtm_ci_installer_build_curl_args 120 &&
		printf "%s\n" "${_LGTM_CI_INSTALLER_CURL_ARGS[@]}"'
	assert_success
	assert_output --partial -- "--tlsv1.2"
	assert_output --partial "=https"
	assert_output --partial "120"
}

@test "installer curl args: appends --cacert when LGTM_CI_CA_BUNDLE is readable" {
	local bundle="${BATS_TEST_TMPDIR}/ca.pem"
	echo "cert" >"$bundle"
	run bash -c 'export LGTM_CI_CA_BUNDLE="'"$BATS_TEST_TMPDIR"'/ca.pem"
		source "$LIB_DIR/installer/binary.sh" &&
		_lgtm_ci_installer_build_curl_args &&
		printf "%s\n" "${_LGTM_CI_INSTALLER_CURL_ARGS[@]}"'
	assert_success
	assert_output --partial -- "--cacert"
}

@test "installer curl args: fails closed when LGTM_CI_CA_BUNDLE is unreadable" {
	run bash -c 'export LGTM_CI_CA_BUNDLE="'"$BATS_TEST_TMPDIR"'/missing.pem"
		source "$LIB_DIR/installer/binary.sh" &&
		_lgtm_ci_installer_build_curl_args'
	assert_failure
	assert_output --partial "CA bundle not readable"
}

@test "installer curl args: appends --pinnedpubkey when LGTM_CI_PINNED_PUBKEY set" {
	run bash -c 'export LGTM_CI_PINNED_PUBKEY="sha256//AAAA"
		source "$LIB_DIR/installer/binary.sh" &&
		_lgtm_ci_installer_build_curl_args &&
		printf "%s\n" "${_LGTM_CI_INSTALLER_CURL_ARGS[@]}"'
	assert_success
	assert_output --partial -- "--pinnedpubkey"
	assert_output --partial "sha256//AAAA"
}

# =============================================================================
# Fallback downloaders (no network/ modules present)
# =============================================================================

# Copy binary.sh into an isolated lib tree without network/ so the minimal
# fallback implementations are defined instead of network/download.sh.
_setup_isolated_binary_lib() {
	local iso="${BATS_TEST_TMPDIR}/isolated-lib"
	mkdir -p "$iso/installer"
	cp "$LIB_DIR/log.sh" "$iso/log.sh"
	cp "$LIB_DIR/fs.sh" "$iso/fs.sh"
	cp "$LIB_DIR/installer/binary.sh" "$iso/installer/binary.sh"
	echo "$iso"
}

@test "fallback download_with_retries: uses hardened curl args" {
	local iso
	iso="$(_setup_isolated_binary_lib)"
	mock_command_record "curl" ""
	run bash -c 'source "$1/installer/binary.sh" &&
		download_with_retries "https://example.com/f" "$2/out.txt" 1' _ "$iso" "$BATS_TEST_TMPDIR"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial -- "--tlsv1.2"
	assert_output --partial "https://example.com/f"
}

@test "fallback download_with_retries: passes pinned pubkey from env" {
	local iso
	iso="$(_setup_isolated_binary_lib)"
	mock_command_record "curl" ""
	run bash -c 'export LGTM_CI_PINNED_PUBKEY="sha256//BBBB"
		source "$1/installer/binary.sh" &&
		download_with_retries "https://example.com/f" "$2/out.txt" 1' _ "$iso" "$BATS_TEST_TMPDIR"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial -- "--pinnedpubkey sha256//BBBB"
}

@test "fallback download_with_retries: fails after exhausting attempts" {
	local iso
	iso="$(_setup_isolated_binary_lib)"
	mock_command "curl" "" 1
	run bash -c 'source "$1/installer/binary.sh" &&
		download_with_retries "https://example.com/f" "$2/out.txt" 2' _ "$iso" "$BATS_TEST_TMPDIR"
	assert_failure
}

@test "fallback download_and_run_installer: downloads and executes script" {
	local iso
	iso="$(_setup_isolated_binary_lib)"
	local mock_bin="${BATS_TEST_TMPDIR}/fbbin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/curl" <<'CURL'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	*) shift ;;
	esac
done
printf '#!/usr/bin/env bash\necho installer-ran\n' >"$out"
CURL
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"
	run bash -c 'source "$1/installer/binary.sh" &&
		download_and_run_installer "https://example.com/install.sh"' _ "$iso"
	assert_success
	assert_output --partial "installer-ran"
}
