#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/publish/version.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR

	PKG_DIR="${BATS_TEST_TMPDIR}/project"
	mkdir -p "$PKG_DIR"
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# extract_pypi_version tests
# =============================================================================

@test "extract_pypi_version: extracts version from PEP 621 project table" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
version = "1.2.3"

[build-system]
requires = ["setuptools"]
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_version \"$PKG_DIR\""
	assert_success
	assert_output "1.2.3"
}

@test "extract_pypi_version: falls back to tool.poetry table" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[tool.poetry]
name = "my-package"
version = "2.0.0"

[build-system]
requires = ["poetry-core"]
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_version \"$PKG_DIR\""
	assert_success
	assert_output "2.0.0"
}

@test "extract_pypi_version: prefers project table over tool.poetry" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
version = "1.2.3"

[tool.poetry]
version = "2.0.0"

[build-system]
requires = ["setuptools"]
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_version \"$PKG_DIR\""
	assert_success
	assert_output "1.2.3"
}

@test "extract_pypi_version: handles inline tables and complex TOML" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
version = "3.0.0"
dependencies = [
    {name = "foo", version = "1.0"},
]
description = """
A package with
multi-line description
"""

[build-system]
requires = ["setuptools"]
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_version \"$PKG_DIR\""
	assert_success
	assert_output "3.0.0"
}

@test "extract_pypi_version: returns 1 for missing file" {
	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_version \"/nonexistent\""
	assert_failure
}

@test "extract_pypi_version: returns 1 when no version found" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_version \"$PKG_DIR\""
	assert_failure
}

@test "extract_pypi_version: defaults to current directory" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
EOF

	# With no version found, should return 1
	run bash -c "cd \"$PKG_DIR\" && source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_version"
	assert_failure
}

# =============================================================================
# extract_pypi_name tests
# =============================================================================

@test "extract_pypi_name: extracts name from PEP 621 project table" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[project]
name = "my-package"
version = "1.2.3"
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_name \"$PKG_DIR\""
	assert_success
	assert_output "my-package"
}

@test "extract_pypi_name: falls back to tool.poetry table" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[tool.poetry]
name = "poetry-pkg"
version = "1.0.0"
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_name \"$PKG_DIR\""
	assert_success
	assert_output "poetry-pkg"
}

@test "extract_pypi_name: returns 1 for missing file" {
	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_name \"/nonexistent\""
	assert_failure
}

@test "extract_pypi_name: returns 1 when no name found" {
	cat >"$PKG_DIR/pyproject.toml" <<'EOF'
[build-system]
requires = ["setuptools"]
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_pypi_name \"$PKG_DIR\""
	assert_failure
}

# =============================================================================
# extract_npm_version tests
# =============================================================================

@test "extract_npm_version: extracts from package.json" {
	cat >"$PKG_DIR/package.json" <<'EOF'
{
  "name": "my-package",
  "version": "1.0.0"
}
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_npm_version \"$PKG_DIR\""
	assert_success
	assert_output "1.0.0"
}

@test "extract_npm_version: returns 1 for missing file" {
	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_npm_version \"/nonexistent\""
	assert_failure
}

@test "extract_npm_version: returns 1 when no version field" {
	cat >"$PKG_DIR/package.json" <<'EOF'
{
  "name": "my-package"
}
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_npm_version \"$PKG_DIR\""
	assert_failure
}

@test "extract_npm_version: handles prerelease version" {
	cat >"$PKG_DIR/package.json" <<'EOF'
{
  "name": "my-package",
  "version": "1.0.0-beta.1"
}
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_npm_version \"$PKG_DIR\""
	assert_success
	assert_output "1.0.0-beta.1"
}

# =============================================================================
# extract_gem_version tests
# =============================================================================

@test "extract_gem_version: extracts from gemspec file" {
	cat >"$PKG_DIR/mygem.gemspec" <<'EOF'
Gem::Specification.new do |s|
  s.name = "mygem"
  s.version = "1.0.0"
end
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_gem_version \"$PKG_DIR/mygem.gemspec\""
	assert_success
	assert_output "1.0.0"
}

@test "extract_gem_version: auto-detects gemspec in directory" {
	cat >"$PKG_DIR/mygem.gemspec" <<'EOF'
Gem::Specification.new do |s|
  s.name = "mygem"
  s.version = "2.0.0"
end
EOF

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_gem_version \"$PKG_DIR\""
	assert_success
	assert_output "2.0.0"
}

@test "extract_gem_version: returns 1 for missing gemspec" {
	local empty_dir="${BATS_TEST_TMPDIR}/empty"
	mkdir -p "$empty_dir"

	run bash -c "source \"\$LIB_DIR/publish/version.sh\" && extract_gem_version \"$empty_dir\""
	assert_failure
}

@test "extract_gem_version: returns 1 for file without version" {
	cat >"$PKG_DIR/bad.gemspec" <<'EOF'
Gem::Specification.new do |s|
  s.name = "mygem"
end
EOF

	run bash -c "
		# Skip ruby eval for this test
		command() {
			if [[ \"\$2\" == \"ruby\" ]]; then return 1; fi
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/publish/version.sh\"
		extract_gem_version \"$PKG_DIR/bad.gemspec\"
	"
	assert_failure
}

# =============================================================================
# is_prerelease_version tests
# =============================================================================

@test "is_prerelease_version: detects semver prerelease 1.0.0-alpha.1" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "1.0.0-alpha.1" && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_prerelease_version: detects semver prerelease 1.0.0-beta" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "1.0.0-beta" && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_prerelease_version: detects python prerelease 1.0.0a1" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "1.0.0a1" && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_prerelease_version: detects python prerelease 1.0.0b2" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "1.0.0b2" && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_prerelease_version: detects python prerelease 1.0.0rc1" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "1.0.0rc1" && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_prerelease_version: detects dev version 1.0.0dev1" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "1.0.0dev1" && echo "yes"'
	assert_success
	assert_output "yes"
}

@test "is_prerelease_version: returns false for stable 1.0.0" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "1.0.0" || echo "stable"'
	assert_success
	assert_output "stable"
}

@test "is_prerelease_version: strips v prefix" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && is_prerelease_version "v1.0.0-rc.1" && echo "yes"'
	assert_success
	assert_output "yes"
}

# =============================================================================
# get_dist_tag_for_version tests
# =============================================================================

@test "get_dist_tag_for_version: returns alpha for alpha prerelease" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0-alpha.1"'
	assert_success
	assert_output "alpha"
}

@test "get_dist_tag_for_version: returns beta for beta prerelease" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0-beta.1"'
	assert_success
	assert_output "beta"
}

@test "get_dist_tag_for_version: returns rc for rc prerelease" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0-rc.1"'
	assert_success
	assert_output "rc"
}

@test "get_dist_tag_for_version: returns next for dev version" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0-dev.1"'
	assert_success
	assert_output "next"
}

@test "get_dist_tag_for_version: returns next for next version" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0-next.1"'
	assert_success
	assert_output "next"
}

@test "get_dist_tag_for_version: returns latest for stable version" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0"'
	assert_success
	assert_output "latest"
}

@test "get_dist_tag_for_version: returns alpha for python-style a version" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0a1"'
	assert_success
	assert_output "alpha"
}

@test "get_dist_tag_for_version: returns beta for python-style b version" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "1.0.0b1"'
	assert_success
	assert_output "beta"
}

@test "get_dist_tag_for_version: strips v prefix" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && get_dist_tag_for_version "v1.0.0"'
	assert_success
	assert_output "latest"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "version.sh: exports extract_pypi_version function" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && declare -f extract_pypi_version >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "version.sh: exports extract_pypi_name function" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && declare -f extract_pypi_name >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "version.sh: exports is_prerelease_version function" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && declare -f is_prerelease_version >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "version.sh: exports get_dist_tag_for_version function" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && declare -f get_dist_tag_for_version >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "version.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/publish/version.sh"
		source "$LIB_DIR/publish/version.sh"
		declare -f extract_pypi_version >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "version.sh: sets _PUBLISH_VERSION_LOADED guard" {
	run bash -c 'source "$LIB_DIR/publish/version.sh" && echo "${_PUBLISH_VERSION_LOADED}"'
	assert_success
	assert_output "1"
}
