#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/publish/homebrew.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR

	# Source log functions for mocking
	# shellcheck source=/dev/null
	source "$LIB_DIR/log.sh" 2>/dev/null || true
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# escape_ruby_string tests
# =============================================================================

@test "escape_ruby_string: returns empty string for empty input" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && escape_ruby_string ""'
	assert_success
	assert_output ""
}

@test "escape_ruby_string: returns unchanged string without special chars" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && escape_ruby_string "simple text"'
	assert_success
	assert_output "simple text"
}

@test "escape_ruby_string: escapes double quotes" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && escape_ruby_string "say \"hello\""'
	assert_success
	assert_output 'say \"hello\"'
}

@test "escape_ruby_string: escapes backslashes" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && escape_ruby_string "path\\to\\file"'
	assert_success
	assert_output 'path\\to\\file'
}

@test "escape_ruby_string: escapes both quotes and backslashes" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && escape_ruby_string "say \"hello\\world\""'
	assert_success
	assert_output 'say \"hello\\world\"'
}

# =============================================================================
# update_formula_version tests
# =============================================================================

@test "update_formula_version: fails when formula file missing" {
	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		update_formula_version "/nonexistent/formula.rb" "http://new-url" "abc123" 2>&1
	'
	assert_failure
	assert_output --partial "Formula not found"
}

@test "update_formula_version: updates url in formula" {
	local formula="${BATS_TEST_TMPDIR}/test.rb"
	cat >"$formula" <<'EOF'
class Test < Formula
  desc "Test formula"
  homepage "https://example.com"
  url "https://old.example.com/test-1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
end
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		update_formula_version '$formula' 'https://new.example.com/test-2.0.0.tar.gz' 'abc123def456' '2.0.0' 2>&1
	"
	assert_success

	# Verify the URL was updated
	run grep 'url "https://new.example.com/test-2.0.0.tar.gz"' "$formula"
	assert_success
}

@test "update_formula_version: updates sha256 in formula" {
	local formula="${BATS_TEST_TMPDIR}/test.rb"
	cat >"$formula" <<'EOF'
class Test < Formula
  desc "Test formula"
  url "https://example.com/test-1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
end
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		update_formula_version '$formula' 'https://new.example.com/test.tar.gz' 'newsha256hash' 2>&1
	"
	assert_success

	# Verify SHA256 was updated
	run grep 'sha256 "newsha256hash"' "$formula"
	assert_success
}

@test "update_formula_version: only updates first url (not resource blocks)" {
	local formula="${BATS_TEST_TMPDIR}/test.rb"
	cat >"$formula" <<'EOF'
class Test < Formula
  desc "Test formula"
  url "https://example.com/main-1.0.0.tar.gz"
  sha256 "main000000000000000000000000000000000000000000000000000000000000"

  resource "dep" do
    url "https://example.com/dep-1.0.0.tar.gz"
    sha256 "dep0000000000000000000000000000000000000000000000000000000000"
  end
end
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		update_formula_version '$formula' 'https://new.example.com/main-2.0.0.tar.gz' 'newmainsha' 2>&1
	"
	assert_success

	# Resource URL should remain unchanged
	run grep 'url "https://example.com/dep-1.0.0.tar.gz"' "$formula"
	assert_success
}

@test "update_formula_version: restores backup on failure" {
	local formula="${BATS_TEST_TMPDIR}/test.rb"
	local original_content='class Test < Formula
  url "https://example.com/test.tar.gz"
  sha256 "original"
end'
	echo "$original_content" >"$formula"

	# Force awk to fail by replacing it with a command that always fails
	run bash -c "
		awk() { return 1; }
		export -f awk
		source \"\$LIB_DIR/publish/homebrew.sh\"
		update_formula_version '$formula' 'https://new.example.com/test.tar.gz' 'newhash' 2>&1
	"
	assert_failure

	# Verify original content was preserved via backup restore
	local current_content
	current_content=$(cat "$formula")
	[[ "$current_content" == "$original_content" ]]
}

# =============================================================================
# calculate_sha256_from_url tests
# =============================================================================

@test "calculate_sha256_from_url: fails on download error" {
	mock_command "curl" "" 1

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		calculate_sha256_from_url "https://example.com/nonexistent.tar.gz" 2>&1
	'
	assert_failure
	assert_output --partial "Failed to download"
}

@test "calculate_sha256_from_url: returns sha256 hash" {
	# Create mock that writes known content
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
# Find -o argument and write known content
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) echo "test content" > "$2"; exit 0;;
        *) shift;;
    esac
done
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export PATH="${mock_bin}:$PATH"

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		calculate_sha256_from_url "https://example.com/test.tar.gz"
	'
	assert_success
	# Output should be a 64-character hex string (SHA256)
	[[ ${#output} -eq 64 ]]
}

# =============================================================================
# calculate_resource_checksums tests
# =============================================================================

@test "calculate_resource_checksums: fails when requirements file missing" {
	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		calculate_resource_checksums "/nonexistent/requirements.txt" 2>&1
	'
	assert_failure
	assert_output --partial "Requirements file not found"
}

@test "calculate_resource_checksums: skips comment lines" {
	local req_file="${BATS_TEST_TMPDIR}/requirements.txt"
	cat >"$req_file" <<'EOF'
# This is a comment
   # Indented comment
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		calculate_resource_checksums '$req_file' 2>&1
	"
	assert_success
	# Output should be empty (no resource blocks)
	refute_output --partial "resource"
}

@test "calculate_resource_checksums: skips empty lines" {
	local req_file="${BATS_TEST_TMPDIR}/requirements.txt"
	cat >"$req_file" <<'EOF'



EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		calculate_resource_checksums '$req_file' 2>&1
	"
	assert_success
	refute_output --partial "resource"
}

@test "calculate_resource_checksums: skips lines with environment markers" {
	local req_file="${BATS_TEST_TMPDIR}/requirements.txt"
	cat >"$req_file" <<'EOF'
package==1.0.0; python_version<"3.9"
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		calculate_resource_checksums '$req_file' 2>&1
	"
	# Should warn and skip, not error
	assert_success
	assert_output --partial "Skipping requirement with environment markers"
}

@test "calculate_resource_checksums: skips unparseable requirements" {
	local req_file="${BATS_TEST_TMPDIR}/requirements.txt"
	cat >"$req_file" <<'EOF'
package>=1.0.0
another~=2.0
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		calculate_resource_checksums '$req_file' 2>&1
	"
	assert_success
	assert_output --partial "Skipping unparseable requirement"
}

@test "calculate_resource_checksums: strips inline comments" {
	local req_file="${BATS_TEST_TMPDIR}/requirements.txt"
	cat >"$req_file" <<'EOF'
package==1.0.0  # inline comment
EOF

	# Mock get_pypi_download_url and get_pypi_sha256
	mock_command "curl" '{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test.tar.gz","digests":{"sha256":"abc123"}}]}' 0

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		calculate_resource_checksums '$req_file' 2>&1
	"
	# Should attempt to process 'package' not 'package # inline comment'
	assert_success
}

@test "calculate_resource_checksums: removes extras from package name" {
	local req_file="${BATS_TEST_TMPDIR}/requirements.txt"
	cat >"$req_file" <<'EOF'
package[dev,test]==1.0.0
EOF

	# Mock curl to return valid PyPI response
	mock_command "curl" '{"urls":[{"packagetype":"sdist","url":"https://pypi.org/package-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}' 0

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		calculate_resource_checksums '$req_file' 2>&1
	"
	# Should use 'package' not 'package[dev,test]'
	assert_success
}

# =============================================================================
# clone_homebrew_tap tests
# =============================================================================

@test "clone_homebrew_tap: clones new repository" {
	mock_command_record "git" "" 0

	local target_dir="${BATS_TEST_TMPDIR}/tap"

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		clone_homebrew_tap 'owner/homebrew-tap' '$target_dir' 2>&1
	"
	assert_success

	# Verify git clone was called
	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_git")
	[[ "$calls" == *"clone"* ]]
	[[ "$calls" == *"https://github.com/owner/homebrew-tap.git"* ]]
}

@test "clone_homebrew_tap: updates existing repository" {
	local target_dir="${BATS_TEST_TMPDIR}/tap"
	mkdir -p "$target_dir/.git"

	mock_command_record "git" "" 0

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		clone_homebrew_tap 'owner/homebrew-tap' '$target_dir' 2>&1
	"
	assert_success

	# Verify git fetch was called instead of clone
	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_git")
	[[ "$calls" == *"fetch"* ]]
}

@test "clone_homebrew_tap: fails on clone error" {
	mock_command "git" "" 1

	local target_dir="${BATS_TEST_TMPDIR}/tap"

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		clone_homebrew_tap 'owner/homebrew-tap' '$target_dir' 2>&1
	"
	assert_failure
	assert_output --partial "Failed to clone"
}

# =============================================================================
# commit_formula_update tests
# =============================================================================

@test "commit_formula_update: commits formula changes" {
	setup_mock_git_repo
	local tap_dir="$MOCK_GIT_REPO"

	# Create formula file
	mkdir -p "$tap_dir/Formula"
	echo 'class Test < Formula; end' >"$tap_dir/Formula/test.rb"

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		commit_formula_update '$tap_dir' 'test' '1.2.3' 2>&1
	"
	assert_success
	assert_output --partial "Committed formula update"
}

@test "commit_formula_update: configures git in CI environment" {
	setup_mock_git_repo
	local tap_dir="$MOCK_GIT_REPO"

	mkdir -p "$tap_dir/Formula"
	echo 'class Test < Formula; end' >"$tap_dir/Formula/test.rb"

	run bash -c "
		export GITHUB_ACTIONS=true
		source \"\$LIB_DIR/publish/homebrew.sh\"
		commit_formula_update '$tap_dir' 'test' '1.2.3' 2>&1
	"
	assert_success
}

@test "commit_formula_update: warns when no changes to commit" {
	setup_mock_git_repo
	local tap_dir="$MOCK_GIT_REPO"

	# Create and commit formula file first
	mkdir -p "$tap_dir/Formula"
	echo 'class Test < Formula; end' >"$tap_dir/Formula/test.rb"
	(cd "$tap_dir" && git add Formula/test.rb && git commit -q -m "Add formula")

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		commit_formula_update '$tap_dir' 'test' '1.2.3' 2>&1
	"
	assert_success
	assert_output --partial "No changes to commit"
}

@test "commit_formula_update: uses correct commit message" {
	setup_mock_git_repo
	local tap_dir="$MOCK_GIT_REPO"

	mkdir -p "$tap_dir/Formula"
	echo 'class Myformula < Formula; end' >"$tap_dir/Formula/myformula.rb"

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		commit_formula_update '$tap_dir' 'myformula' '2.0.0' 2>&1
	"
	assert_success

	# Check commit message
	run bash -c "cd '$tap_dir' && git log -1 --format=%s"
	assert_output "Update myformula to 2.0.0"
}

# =============================================================================
# generate_formula_from_pypi tests (mocked)
# =============================================================================

@test "generate_formula_from_pypi: fails when download URL unavailable" {
	# Mock curl to return empty response
	mock_command "curl" "" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "nonexistent-package" "1.0.0" "Test package" 2>&1
	'
	assert_failure
	assert_output --partial "Could not get download URL"
}

@test "generate_formula_from_pypi: generates valid formula structure" {
	# Mock PyPI API response
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://files.pythonhosted.org/packages/test-1.0.0.tar.gz","digests":{"sha256":"abc123def456"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test-package" "1.0.0" "A test package" 2>&1
	'
	assert_success
	assert_output --partial "class TestPackage < Formula"
	assert_output --partial 'desc "A test package"'
	assert_output --partial 'depends_on "python@'
	assert_output --partial "virtualenv_install_with_resources"
}

@test "generate_formula_from_pypi: handles package names starting with digits" {
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/2to3-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "2to3" "1.0.0" "Python 2 to 3 converter" 2>&1
	'
	assert_success
	# Class name should be prefixed with Pkg since it starts with a digit
	assert_output --partial "class Pkg2to3 < Formula"
}

@test "generate_formula_from_pypi: escapes description with quotes" {
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test" "1.0.0" "A \"quoted\" description" 2>&1
	'
	assert_success
	assert_output --partial 'desc "A \"quoted\" description"'
}

@test "generate_formula_from_pypi: uses custom homepage" {
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test" "1.0.0" "Test" "false" "https://custom.example.com" 2>&1
	'
	assert_success
	assert_output --partial 'homepage "https://custom.example.com"'
}

@test "generate_formula_from_pypi: uses explicit license" {
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test" "1.0.0" "Test" "false" "" "MIT" 2>&1
	'
	assert_success
	assert_output --partial 'license "MIT"'
}

@test "generate_formula_from_pypi: uses custom python version" {
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test" "1.0.0" "Test" "false" "" "MIT" "3.11" 2>&1
	'
	assert_success
	assert_output --partial 'depends_on "python@3.11"'
}

@test "generate_formula_from_pypi: uses custom test command" {
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test" "1.0.0" "Test" "false" "" "MIT" "3.12" "system bin/\"test\", \"--help\"" 2>&1
	'
	assert_success
	assert_output --partial 'system bin/"test", "--help"'
}

@test "generate_formula_from_pypi: warns when no license found" {
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test-1.0.0.tar.gz","digests":{"sha256":"abc123"}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test" "1.0.0" "Test" "false" "" "" 2>&1
	'
	assert_success
	assert_output --partial "license not detected"
}

@test "generate_formula_from_pypi: fails when SHA256 unavailable" {
	# sdist present (so download URL succeeds) but sha256 is empty string
	# jq -r on "" returns empty, making -z check pass → "Could not get SHA256"
	local pypi_response='{"urls":[{"packagetype":"sdist","url":"https://pypi.org/test-1.0.0.tar.gz","digests":{"sha256":""}}]}'
	mock_command "curl" "$pypi_response" 0

	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		generate_formula_from_pypi "test" "1.0.0" "Test" 2>&1
	'
	assert_failure
	assert_output --partial "Could not get SHA256"
}

@test "update_formula_version: logs success with version" {
	local formula="${BATS_TEST_TMPDIR}/test.rb"
	cat >"$formula" <<'EOF'
class Test < Formula
  url "https://old.example.com/test-1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
end
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		update_formula_version '$formula' 'https://new.example.com/test.tar.gz' 'newhash' '3.0.0' 2>&1
	"
	assert_success
	assert_output --partial "Updated formula to version 3.0.0"
}

@test "update_formula_version: logs success without version" {
	local formula="${BATS_TEST_TMPDIR}/test.rb"
	cat >"$formula" <<'EOF'
class Test < Formula
  url "https://old.example.com/test.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
end
EOF

	run bash -c "
		source \"\$LIB_DIR/publish/homebrew.sh\"
		update_formula_version '$formula' 'https://new.example.com/test.tar.gz' 'newhash' 2>&1
	"
	assert_success
	assert_output --partial "Updated formula"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "homebrew.sh: exports escape_ruby_string function" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F escape_ruby_string'
	assert_success
}

@test "homebrew.sh: exports generate_formula_from_pypi function" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F generate_formula_from_pypi'
	assert_success
}

@test "homebrew.sh: exports update_formula_version function" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F update_formula_version'
	assert_success
}

@test "homebrew.sh: exports calculate_sha256_from_url function" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F calculate_sha256_from_url'
	assert_success
}

@test "homebrew.sh: exports calculate_resource_checksums function" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F calculate_resource_checksums'
	assert_success
}

@test "homebrew.sh: exports clone_homebrew_tap function" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F clone_homebrew_tap'
	assert_success
}

@test "homebrew.sh: exports commit_formula_update function" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F commit_formula_update'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "homebrew.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/publish/homebrew.sh"
		source "$LIB_DIR/publish/homebrew.sh"
		source "$LIB_DIR/publish/homebrew.sh"
		declare -F escape_ruby_string >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "homebrew.sh: sets _PUBLISH_HOMEBREW_LOADED guard" {
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && echo "${_PUBLISH_HOMEBREW_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Integration tests
# =============================================================================

@test "homebrew.sh: sources registry.sh automatically" {
	require_bash4
	run bash -c 'source "$LIB_DIR/publish/homebrew.sh" && declare -F get_pypi_download_url'
	assert_success
}
