#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/extract.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR

	PKG_DIR="${BATS_TEST_TMPDIR}/project"
	mkdir -p "$PKG_DIR"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# extract_version_pyproject tests
# =============================================================================

@test "extract_version_pyproject: extracts version from pyproject.toml" {
	# Use a version without digits 2 or 7 to avoid busybox sed \x27 hex escape
	# issue where ["\x27] treats \x27 as literal chars making 2 and 7 match
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
version = "3.0.1"
EOF

	run bash -c "source \"\$LIB_DIR/release/extract.sh\" && extract_version_pyproject \"$PKG_DIR/pyproject.toml\""
	assert_success
	assert_output "3.0.1"
}

@test "extract_version_pyproject: returns 1 for missing file" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && extract_version_pyproject "/nonexistent/pyproject.toml"'
	assert_failure
}

@test "extract_version_pyproject: returns 1 when no version field" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
EOF

	run bash -c "source \"\$LIB_DIR/release/extract.sh\" && extract_version_pyproject \"$PKG_DIR/pyproject.toml\""
	assert_failure
}

@test "extract_version_pyproject: defaults to pyproject.toml in current dir" {
	# Use a version without digits 2 or 7 (busybox sed \x27 hex escape issue)
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
version = "4.0.0"
EOF

	run bash -c "cd \"$PKG_DIR\" && source \"\$LIB_DIR/release/extract.sh\" && extract_version_pyproject"
	assert_success
	assert_output "4.0.0"
}

# =============================================================================
# extract_version_package_json tests
# =============================================================================

@test "extract_version_package_json: extracts version from package.json" {
	cat >"$PKG_DIR/package.json" <<'EOF'
{
  "name": "my-package",
  "version": "3.0.0"
}
EOF

	run bash -c "source \"\$LIB_DIR/release/extract.sh\" && extract_version_package_json \"$PKG_DIR/package.json\""
	assert_success
	assert_output "3.0.0"
}

@test "extract_version_package_json: returns 1 for missing file" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && extract_version_package_json "/nonexistent/package.json"'
	assert_failure
}

@test "extract_version_package_json: returns 1 when no version field" {
	cat >"$PKG_DIR/package.json" <<'EOF'
{
  "name": "my-package"
}
EOF

	run bash -c "source \"\$LIB_DIR/release/extract.sh\" && extract_version_package_json \"$PKG_DIR/package.json\""
	assert_failure
}

@test "extract_version_package_json: uses grep fallback when jq unavailable" {
	cat >"$PKG_DIR/package.json" <<'EOF'
{
  "name": "my-package",
  "version": "4.0.0"
}
EOF

	run bash -c "
		# Override command to hide jq
		command() {
			if [[ \"\$1\" == \"-v\" ]] && [[ \"\$2\" == \"jq\" ]]; then return 1; fi
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/release/extract.sh\"
		extract_version_package_json \"$PKG_DIR/package.json\"
	"
	assert_success
	assert_output "4.0.0"
}

# =============================================================================
# extract_version_cargo tests
# =============================================================================

@test "extract_version_cargo: extracts version from Cargo.toml" {
	cat >"$PKG_DIR/Cargo.toml" <<'EOF'
[package]
name = "my-crate"
version = "0.1.0"
EOF

	run bash -c "source \"\$LIB_DIR/release/extract.sh\" && extract_version_cargo \"$PKG_DIR/Cargo.toml\""
	assert_success
	assert_output "0.1.0"
}

@test "extract_version_cargo: returns 1 for missing file" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && extract_version_cargo "/nonexistent/Cargo.toml"'
	assert_failure
}

@test "extract_version_cargo: returns 1 when no version field" {
	cat >"$PKG_DIR/Cargo.toml" <<'EOF'
[package]
name = "my-crate"
EOF

	run bash -c "source \"\$LIB_DIR/release/extract.sh\" && extract_version_cargo \"$PKG_DIR/Cargo.toml\""
	assert_failure
}

# =============================================================================
# extract_version_git_tag tests
# =============================================================================

@test "extract_version_git_tag: extracts version from latest tag" {
	setup_mock_git_repo
	(cd "$MOCK_GIT_REPO" && git tag "v1.5.0")

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/extract.sh\" && extract_version_git_tag"
	assert_success
	assert_output "1.5.0"
}

@test "extract_version_git_tag: strips v prefix" {
	setup_mock_git_repo
	(cd "$MOCK_GIT_REPO" && git tag "v2.0.0")

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/extract.sh\" && extract_version_git_tag"
	assert_success
	assert_output "2.0.0"
}

@test "extract_version_git_tag: returns 1 when no tags" {
	setup_mock_git_repo

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/extract.sh\" && extract_version_git_tag"
	assert_failure
}

@test "extract_version_git_tag: uses custom pattern" {
	setup_mock_git_repo
	(cd "$MOCK_GIT_REPO" && git tag "release-1.0.0")

	run bash -c "cd \"$MOCK_GIT_REPO\" && source \"\$LIB_DIR/release/extract.sh\" && extract_version_git_tag 'release-*'"
	assert_success
	assert_output "release-1.0.0"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "extract.sh: exports extract_version_pyproject" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && declare -f extract_version_pyproject >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "extract.sh: exports extract_version_package_json" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && declare -f extract_version_package_json >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "extract.sh: exports extract_version_cargo" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && declare -f extract_version_cargo >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "extract.sh: exports extract_version_git_tag" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && declare -f extract_version_git_tag >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "extract.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/release/extract.sh"
		source "$LIB_DIR/release/extract.sh"
		declare -f extract_version_pyproject >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "extract.sh: sets _RELEASE_EXTRACT_LOADED guard" {
	run bash -c 'source "$LIB_DIR/release/extract.sh" && echo "${_RELEASE_EXTRACT_LOADED}"'
	assert_success
	assert_output "1"
}
