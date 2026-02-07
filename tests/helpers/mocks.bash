#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Command mocking framework for BATS tests
#
# Usage: In your .bats file:
#   load "../helpers/mocks"

# =============================================================================
# Mock command framework
# =============================================================================

# Create a mock executable that outputs specified content
# Usage: mock_command "curl" "expected output" [exit_code]
# The mock is created in BATS_TEST_TMPDIR/bin and added to PATH
mock_command() {
	local cmd_name="$1"
	local output="${2:-}"
	local exit_code="${3:-0}"

	# Ensure mock bin directory exists
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	# Write output to a separate file to avoid escaping issues
	local output_file="${mock_bin}/.${cmd_name}_output"
	printf '%s\n' "$output" >"$output_file"

	# Create mock script that reads from the output file
	cat >"${mock_bin}/${cmd_name}" <<EOF
#!/usr/bin/env bash
cat '${output_file}'
exit $exit_code
EOF
	chmod +x "${mock_bin}/${cmd_name}"

	# Add to PATH if not already there
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# Create a mock that records its calls
# Usage: mock_command_record "git"
# Check calls with: cat "$BATS_TEST_TMPDIR/mock_calls_git"
mock_command_record() {
	local cmd_name="$1"
	local output="${2:-}"
	local exit_code="${3:-0}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_${cmd_name}"
	: >"$calls_file"

	# Write output to a separate file to avoid escaping issues
	local output_file="${mock_bin}/.${cmd_name}_output"
	printf '%s\n' "$output" >"$output_file"

	cat >"${mock_bin}/${cmd_name}" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${calls_file}'
cat '${output_file}'
exit $exit_code
EOF
	chmod +x "${mock_bin}/${cmd_name}"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# Create a mock that behaves differently based on arguments
# Usage: mock_command_multi "git" '
#   rev-parse --abbrev-ref HEAD) echo "main";;
#   rev-parse HEAD) echo "abc1234";;
#   *) exit 1;;
# '
mock_command_multi() {
	local cmd_name="$1"
	local case_body="$2"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/${cmd_name}" <<EOF
#!/usr/bin/env bash
case "\$*" in
$case_body
esac
EOF
	chmod +x "${mock_bin}/${cmd_name}"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# =============================================================================
# Git-specific mocks
# =============================================================================

# Setup a mock git repository in the temp directory
# Usage: setup_mock_git_repo
# Note: Does not change the caller's working directory
setup_mock_git_repo() {
	local repo_dir="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$repo_dir"

	# Run git init in subshell to avoid leaking cwd changes
	(
		cd "$repo_dir" || exit 1

		git init -q
		git config user.email "test@test.com"
		git config user.name "Test User"

		# Create initial commit
		echo "initial" >README.md
		git add README.md
		git commit -q -m "Initial commit"
	) || return 1

	export MOCK_GIT_REPO="$repo_dir"
}

# Mock git with common operations
# Usage: mock_git "main" "abc1234567890"
mock_git() {
	local branch="${1:-main}"
	local sha="${2:-abc1234567890123456789012345678901234567}"
	local short_sha="${sha:0:7}"

	mock_command_multi "git" "
		rev-parse --abbrev-ref HEAD) echo \"$branch\";;
		rev-parse HEAD) echo \"$sha\";;
		rev-parse --short=7 HEAD) echo \"$short_sha\";;
		rev-parse --git-dir) echo \".git\";;
		rev-parse --show-toplevel) echo \"${BATS_TEST_TMPDIR}/repo\";;
		rev-parse --is-inside-work-tree) echo \"true\";;
		status --porcelain) echo \"\";;
		remote get-url origin) echo \"git@github.com:test/repo.git\";;
		describe --tags --match *) echo \"v1.0.0\";;
		tag -l *) echo \"v1.0.0\"; echo \"v0.9.0\";;
		rev-parse refs/tags/v1.0.0) echo \"$sha\";;
		rev-parse refs/tags/nonexistent) exit 1;;
		*) exit 0;;
	"
}

# =============================================================================
# curl/wget mocks
# =============================================================================

# Mock curl to return specific content
# Usage: mock_curl "response body" [exit_code]
mock_curl() {
	local response="${1:-}"
	local exit_code="${2:-0}"

	mock_command "curl" "$response" "$exit_code"
}

# Mock curl for file download (writes to -o argument)
# Usage: mock_curl_download "file content"
mock_curl_download() {
	local content="${1:-downloaded content}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	# Write content to a payload file to avoid sed escaping issues
	local payload_file="${mock_bin}/.curl_payload"
	printf '%s\n' "$content" >"$payload_file"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
# Parse -o argument to get output file
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        --output) output_file="\$2"; shift 2;;
        --output=*) output_file="\${1#*=}"; shift;;
        *) shift;;
    esac
done

if [[ -n "\$output_file" ]]; then
    cat '${payload_file}' > "\$output_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# =============================================================================
# Checksum tool mocks
# =============================================================================

# Mock sha256sum/shasum to return expected checksum
# Usage: mock_sha256 "expected_hash"
mock_sha256() {
	local hash="${1:-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855}"

	mock_command "sha256sum" "$hash  somefile"
	mock_command "shasum" "$hash  somefile"
}

# =============================================================================
# uname mocks for platform testing
# =============================================================================

# Mock uname to simulate different platforms
# Usage: mock_uname "Darwin" "arm64"
mock_uname() {
	local os="${1:-Linux}"
	local arch="${2:-x86_64}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/uname" <<EOF
#!/usr/bin/env bash
case "\$1" in
    -s) echo "$os";;
    -m) echo "$arch";;
    *) echo "$os";;
esac
EOF
	chmod +x "${mock_bin}/uname"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# =============================================================================
# Git commit/tag helpers for conventional-commit tests
# =============================================================================

# Add a conventional commit to the mock git repo
# Usage: add_commit "feat: add login"
add_commit() {
	local message="$1"
	(cd "$MOCK_GIT_REPO" && git commit -q --allow-empty -m "$message")
}

# Create a lightweight tag at the current HEAD in the mock repo
# Usage: tag_mock_repo "v1.0.0"
tag_mock_repo() {
	local tag="$1"
	(cd "$MOCK_GIT_REPO" && git tag "$tag")
}

# =============================================================================
# Helper to restore original PATH
# =============================================================================

# Save PATH before mocking
# Usage: save_path (call in setup)
save_path() {
	export ORIGINAL_PATH="$PATH"
}

# Restore original PATH
# Usage: restore_path (call in teardown)
restore_path() {
	if [[ -n "${ORIGINAL_PATH:-}" ]]; then
		export PATH="$ORIGINAL_PATH"
	fi
}
