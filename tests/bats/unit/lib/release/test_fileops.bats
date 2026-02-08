#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/fileops.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# update_changelog_file tests
# =============================================================================

@test "update_changelog_file: creates new file when it does not exist" {
	local file="${BATS_TEST_TMPDIR}/CHANGELOG.md"

	run bash -c "source \"\$LIB_DIR/release/fileops.sh\" && update_changelog_file \"$file\" \"## [1.0.0] - 2024-01-01\" \"1.0.0\""
	assert_success
	[[ -f "$file" ]]
	run cat "$file"
	assert_output --partial "# Changelog"
	assert_output --partial "## [1.0.0] - 2024-01-01"
	assert_output --partial "Keep a Changelog"
}

@test "update_changelog_file: inserts after header section" {
	local file="${BATS_TEST_TMPDIR}/CHANGELOG.md"
	cat >"$file" <<'EOF'
# Changelog

All notable changes.

## [0.1.0] - 2023-01-01

- Initial release
EOF

	run bash -c "source \"\$LIB_DIR/release/fileops.sh\" && update_changelog_file \"$file\" \"## [1.0.0] - 2024-01-01

### Features
- New feature\" \"1.0.0\""
	assert_success
	run cat "$file"
	assert_output --partial "## [1.0.0] - 2024-01-01"
	assert_output --partial "## [0.1.0] - 2023-01-01"
}

@test "update_changelog_file: prepends when first line is version header" {
	local file="${BATS_TEST_TMPDIR}/CHANGELOG.md"
	cat >"$file" <<'EOF'
## [0.1.0] - 2023-01-01

- Initial release
EOF

	run bash -c "source \"\$LIB_DIR/release/fileops.sh\" && update_changelog_file \"$file\" \"## [1.0.0] - 2024-01-01\" \"1.0.0\""
	assert_success
	run cat "$file"
	# New version should appear before old version
	assert_output --partial "## [1.0.0] - 2024-01-01"
	assert_output --partial "## [0.1.0] - 2023-01-01"
}

@test "update_changelog_file: appends when no version sections exist" {
	local file="${BATS_TEST_TMPDIR}/CHANGELOG.md"
	cat >"$file" <<'EOF'
# Changelog

All notable changes to this project.
EOF

	run bash -c "source \"\$LIB_DIR/release/fileops.sh\" && update_changelog_file \"$file\" \"## [1.0.0] - 2024-01-01\" \"1.0.0\""
	assert_success
	run cat "$file"
	assert_output --partial "## [1.0.0] - 2024-01-01"
}

@test "update_changelog_file: cleans up temp file on success" {
	local file="${BATS_TEST_TMPDIR}/CHANGELOG.md"
	echo "# Changelog" >"$file"
	echo "" >>"$file"
	echo "## [0.1.0] - 2023-01-01" >>"$file"

	run bash -c "source \"\$LIB_DIR/release/fileops.sh\" && update_changelog_file \"$file\" \"## [1.0.0]\" \"1.0.0\""
	assert_success
	# No temp files should remain
	local temps
	temps=$(ls "${BATS_TEST_TMPDIR}"/.changelog.* 2>/dev/null | wc -l)
	[[ "$temps" -eq 0 ]]
}

# =============================================================================
# generate_compare_url tests
# =============================================================================

@test "generate_compare_url: generates correct URL" {
	run bash -c 'source "$LIB_DIR/release/fileops.sh" && generate_compare_url "owner/repo" "v1.0.0" "v1.1.0"'
	assert_success
	assert_output "https://github.com/owner/repo/compare/v1.0.0...v1.1.0"
}

@test "generate_compare_url: returns 1 for missing repo" {
	run bash -c 'source "$LIB_DIR/release/fileops.sh" && generate_compare_url "" "v1.0.0" "v1.1.0"'
	assert_failure
}

@test "generate_compare_url: returns 1 for missing from_tag" {
	run bash -c 'source "$LIB_DIR/release/fileops.sh" && generate_compare_url "owner/repo" "" "v1.1.0"'
	assert_failure
}

@test "generate_compare_url: returns 1 for missing to_tag" {
	run bash -c 'source "$LIB_DIR/release/fileops.sh" && generate_compare_url "owner/repo" "v1.0.0" ""'
	assert_failure
}

# =============================================================================
# Function export tests
# =============================================================================

@test "fileops.sh: update_changelog_file function is available" {
	run bash -c 'source "$LIB_DIR/release/fileops.sh" && declare -f update_changelog_file >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "fileops.sh: generate_compare_url function is available" {
	run bash -c 'source "$LIB_DIR/release/fileops.sh" && declare -f generate_compare_url >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "fileops.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/release/fileops.sh"
		source "$LIB_DIR/release/fileops.sh"
		declare -f update_changelog_file >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "fileops.sh: sets _RELEASE_FILEOPS_LOADED guard" {
	run bash -c 'source "$LIB_DIR/release/fileops.sh" && echo "${_RELEASE_FILEOPS_LOADED}"'
	assert_success
	assert_output "1"
}
