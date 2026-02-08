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

@test "install_anchore_tool: reinstalls when version mismatch" {
	# Mock existing syft with different version
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	# First call returns wrong version, subsequent calls after "install" return correct
	local call_count_file="${mock_bin}/.syft_calls"
	echo "0" >"$call_count_file"

	cat >"${mock_bin}/syft" <<EOF
#!/usr/bin/env bash
count=\$(cat "$call_count_file")
if [[ \$count -eq 0 ]]; then
    echo "Application: syft"
    echo "Version: 0.80.0"
else
    echo "Application: syft"
    echo "Version: 0.90.0"
fi
exit 0
EOF
	chmod +x "${mock_bin}/syft"

	# Mock curl for installer script
	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
# Return a mock installer script that just updates the syft mock
echo '#!/bin/bash'
echo "echo \"1\" > \"$call_count_file\""
EOF
	chmod +x "${mock_bin}/curl"

	# Mock sh to "run" the installer
	cat >"${mock_bin}/sh" <<EOF
#!/usr/bin/env bash
echo "1" > "$call_count_file"
exit 0
EOF
	chmod +x "${mock_bin}/sh"

	export PATH="${mock_bin}:$PATH"

	run bash -c '
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "0.90.0" 2>&1
	'
	assert_success
	# Should attempt reinstall due to version mismatch
	assert_output --partial "version mismatch"

	# Verify the mock installer ran (sh wrote "1" to call_count_file)
	[[ -f "${BATS_TEST_TMPDIR}/bin/.syft_calls" ]]
	[[ "$(cat "${BATS_TEST_TMPDIR}/bin/.syft_calls")" == "1" ]]
}

@test "install_anchore_tool: uses correct installer URL for syft" {
	# Track curl calls to verify URL
	mock_command_record "curl" '#!/bin/bash\necho installed' 0
	local mock_bin="${BATS_TEST_TMPDIR}/bin"

	# Mock sh to simulate installer creating the syft binary
	cat >"${mock_bin}/sh" <<MOCK
#!/usr/bin/env bash
cat >"${mock_bin}/syft" <<'INNER'
#!/usr/bin/env bash
echo "Application: syft"
echo "Version: latest"
INNER
chmod +x "${mock_bin}/syft"
MOCK
	chmod +x "${mock_bin}/sh"

	# Remove any existing syft mock so it's "not installed"
	rm -f "${mock_bin}/syft"

	run bash -c '
		export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
		source "$LIB_DIR/installer/binary.sh"
		install_anchore_tool "syft" "latest" 2>&1
	'
	assert_success

	# Verify curl was called with anchore/syft URL
	run cat "$BATS_TEST_TMPDIR/mock_calls_curl"
	assert_output --partial "anchore"
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
