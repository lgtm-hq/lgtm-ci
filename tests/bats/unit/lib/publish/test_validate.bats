#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/publish/validate.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# validate_pypi_package tests
# =============================================================================

@test "validate_pypi_package: returns 1 for missing dist directory" {
	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/validate.sh"
		validate_pypi_package "/nonexistent/dist" 2>&1
	'
	assert_failure
	assert_output --partial "Distribution directory not found"
}

@test "validate_pypi_package: returns 1 for empty dist directory" {
	local dist_dir="${BATS_TEST_TMPDIR}/dist"
	mkdir -p "$dist_dir"

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_pypi_package \"$dist_dir\" 2>&1
	"
	assert_failure
	assert_output --partial "No distribution files found"
}

@test "validate_pypi_package: passes with wheel files and no twine" {
	local dist_dir="${BATS_TEST_TMPDIR}/dist"
	mkdir -p "$dist_dir"
	touch "$dist_dir/package-1.0.0-py3-none-any.whl"

	run bash -c "
		command() {
			if [[ \"\$2\" == \"twine\" ]] || [[ \"\$2\" == \"uv\" ]]; then return 1; fi
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_pypi_package \"$dist_dir\" 2>&1
	"
	assert_success
	assert_output --partial "twine not available"
}

@test "validate_pypi_package: passes with tar.gz files" {
	local dist_dir="${BATS_TEST_TMPDIR}/dist"
	mkdir -p "$dist_dir"
	touch "$dist_dir/package-1.0.0.tar.gz"

	run bash -c "
		command() {
			if [[ \"\$2\" == \"twine\" ]] || [[ \"\$2\" == \"uv\" ]]; then return 1; fi
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_pypi_package \"$dist_dir\" 2>&1
	"
	assert_success
}

@test "validate_pypi_package: runs twine check when available" {
	local dist_dir="${BATS_TEST_TMPDIR}/dist"
	mkdir -p "$dist_dir"
	touch "$dist_dir/package-1.0.0.tar.gz"
	mock_command "twine" "Checking dist/package-1.0.0.tar.gz: PASSED"

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_pypi_package \"$dist_dir\" 2>&1
	"
	assert_success
	assert_output --partial "twine check passed"
}

@test "validate_pypi_package: fails when twine check fails" {
	local dist_dir="${BATS_TEST_TMPDIR}/dist"
	mkdir -p "$dist_dir"
	touch "$dist_dir/package-1.0.0.tar.gz"
	mock_command "twine" "ERROR" 1

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_pypi_package \"$dist_dir\" 2>&1
	"
	assert_failure
	assert_output --partial "twine check failed"
}

# =============================================================================
# validate_npm_package tests
# =============================================================================

@test "validate_npm_package: returns 1 for missing package.json" {
	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_npm_package \"/nonexistent\" 2>&1
	"
	assert_failure
	assert_output --partial "package.json not found"
}

@test "validate_npm_package: returns 1 for missing name field" {
	local pkg_dir="${BATS_TEST_TMPDIR}/npm-pkg"
	mkdir -p "$pkg_dir"
	cat >"$pkg_dir/package.json" <<'EOF'
{
  "version": "1.0.0"
}
EOF

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_npm_package \"$pkg_dir\" 2>&1
	"
	assert_failure
	assert_output --partial "Missing required field: name"
}

@test "validate_npm_package: returns 1 for missing version field" {
	local pkg_dir="${BATS_TEST_TMPDIR}/npm-pkg"
	mkdir -p "$pkg_dir"
	cat >"$pkg_dir/package.json" <<'EOF'
{
  "name": "my-package"
}
EOF

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_npm_package \"$pkg_dir\" 2>&1
	"
	assert_failure
	assert_output --partial "Missing required field: version"
}

@test "validate_npm_package: returns 1 for invalid name format" {
	local pkg_dir="${BATS_TEST_TMPDIR}/npm-pkg"
	mkdir -p "$pkg_dir"
	cat >"$pkg_dir/package.json" <<'EOF'
{
  "name": "INVALID_NAME",
  "version": "1.0.0"
}
EOF

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_npm_package \"$pkg_dir\" 2>&1
	"
	assert_failure
	assert_output --partial "Invalid package name format"
}

@test "validate_npm_package: passes with valid package.json" {
	local pkg_dir="${BATS_TEST_TMPDIR}/npm-pkg"
	mkdir -p "$pkg_dir"
	cat >"$pkg_dir/package.json" <<'EOF'
{
  "name": "my-package",
  "version": "1.0.0"
}
EOF

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_npm_package \"$pkg_dir\" 2>&1
	"
	assert_success
	assert_output --partial "validation passed"
}

@test "validate_npm_package: accepts scoped package names" {
	local pkg_dir="${BATS_TEST_TMPDIR}/npm-pkg"
	mkdir -p "$pkg_dir"
	cat >"$pkg_dir/package.json" <<'EOF'
{
  "name": "@scope/my-package",
  "version": "1.0.0"
}
EOF

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_npm_package \"$pkg_dir\" 2>&1
	"
	assert_success
	assert_output --partial "validation passed"
}

# =============================================================================
# validate_gem_package tests
# =============================================================================

@test "validate_gem_package: returns 1 for missing gemspec" {
	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_gem_package \"/nonexistent\" 2>&1
	"
	assert_failure
	assert_output --partial "Gemspec not found"
}

@test "validate_gem_package: returns 1 for directory without gemspec" {
	local gem_dir="${BATS_TEST_TMPDIR}/gem"
	mkdir -p "$gem_dir"

	run bash -c "
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_gem_package \"$gem_dir\" 2>&1
	"
	assert_failure
	assert_output --partial "No gemspec found"
}

@test "validate_gem_package: auto-detects gemspec in directory" {
	local gem_dir="${BATS_TEST_TMPDIR}/gem"
	mkdir -p "$gem_dir"
	cat >"$gem_dir/mygem.gemspec" <<'EOF'
Gem::Specification.new do |s|
  s.name = "mygem"
  s.version = "1.0.0"
end
EOF

	run bash -c "
		# Mock gem command to avoid actual build
		command() {
			if [[ \"\$2\" == \"gem\" ]]; then return 1; fi
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_gem_package \"$gem_dir\" 2>&1
	"
	assert_success
	assert_output --partial "validation passed"
}

@test "validate_gem_package: returns 1 for missing name field" {
	local gemspec="${BATS_TEST_TMPDIR}/bad.gemspec"
	cat >"$gemspec" <<'EOF'
Gem::Specification.new do |s|
  s.version = "1.0.0"
end
EOF

	run bash -c "
		command() {
			if [[ \"\$2\" == \"gem\" ]]; then return 1; fi
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/log.sh\"
		source \"\$LIB_DIR/publish/validate.sh\"
		validate_gem_package \"$gemspec\" 2>&1
	"
	assert_failure
	assert_output --partial "Missing required field: name"
}

# =============================================================================
# validate_version_format tests
# =============================================================================

@test "validate_version_format: accepts valid semver 1.2.3" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "1.2.3" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_version_format: accepts semver with prerelease 1.0.0-alpha.1" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "1.0.0-alpha.1" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_version_format: accepts semver with build metadata 1.0.0+build" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "1.0.0+build" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_version_format: accepts v prefix" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "v1.2.3" && echo "valid"'
	assert_success
	assert_output "valid"
}

@test "validate_version_format: rejects two-part version 1.2" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "1.2" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_version_format: rejects non-numeric abc" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "abc" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_version_format: rejects empty string" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "" || echo "invalid"'
	assert_success
	assert_output "invalid"
}

@test "validate_version_format: accepts complex prerelease 1.0.0-beta.2.rc.1" {
	run bash -c 'source "$LIB_DIR/publish/validate.sh" && validate_version_format "1.0.0-beta.2.rc.1" && echo "valid"'
	assert_success
	assert_output "valid"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "validate.sh: exports validate_pypi_package function" {
	run bash -c 'source "$LIB_DIR/log.sh" && source "$LIB_DIR/publish/validate.sh" && declare -f validate_pypi_package >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "validate.sh: exports validate_npm_package function" {
	run bash -c 'source "$LIB_DIR/log.sh" && source "$LIB_DIR/publish/validate.sh" && declare -f validate_npm_package >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "validate.sh: exports validate_version_format function" {
	run bash -c 'source "$LIB_DIR/log.sh" && source "$LIB_DIR/publish/validate.sh" && declare -f validate_version_format >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "validate.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/validate.sh"
		source "$LIB_DIR/publish/validate.sh"
		declare -f validate_pypi_package >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "validate.sh: sets _PUBLISH_VALIDATE_LOADED guard" {
	run bash -c 'source "$LIB_DIR/log.sh" && source "$LIB_DIR/publish/validate.sh" && echo "${_PUBLISH_VALIDATE_LOADED}"'
	assert_success
	assert_output "1"
}
