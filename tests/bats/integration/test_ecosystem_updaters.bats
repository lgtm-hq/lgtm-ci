#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/ecosystems/

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	ECOSYSTEMS_DIR="$PROJECT_ROOT/scripts/ci/release/ecosystems"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# Helpers: create mock version files
# =============================================================================

create_package_json() {
	local dir="$1" version="${2:-1.0.0}" indent="${3:-2}"
	local spaces=""
	if [[ "$indent" == "tab" ]]; then
		printf '{\n\t"name": "test-pkg",\n\t"version": "%s"\n}\n' "$version" >"$dir/package.json"
	else
		spaces=$(printf '%*s' "$indent" '')
		printf '{\n%s"name": "test-pkg",\n%s"version": "%s"\n}\n' "$spaces" "$spaces" "$version" >"$dir/package.json"
	fi
}

create_cargo_toml() {
	local dir="$1" version="${2:-1.0.0}"
	cat >"$dir/Cargo.toml" <<EOF
[package]
name = "test-crate"
version = "$version"
edition = "2021"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
EOF
}

create_pyproject_toml() {
	local dir="$1" version="${2:-1.0.0}" name="${3:-test_pkg}"
	cat >"$dir/pyproject.toml" <<EOF
[project]
name = "$name"
version = "$version"
description = "A test package"

[build-system]
requires = ["setuptools"]
EOF
}

create_init_py() {
	local dir="$1" pkg="$2" version="${3:-1.0.0}"
	mkdir -p "$dir/$pkg"
	cat >"$dir/$pkg/__init__.py" <<EOF
"""Test package."""

__version__ = "$version"

__all__ = ["__version__"]
EOF
}

create_uv_lock() {
	# Minimal uv.lock with the own package plus one registry dependency,
	# matching the structure uv generates (PEP 503 normalized names).
	local dir="$1" pkg="$2" version="${3:-1.0.0}"
	cat >"$dir/uv.lock" <<EOF
version = 1
revision = 3
requires-python = ">=3.11"

[[package]]
name = "$pkg"
version = "$version"
source = { editable = "." }

[[package]]
name = "requests"
version = "2.32.3"
source = { registry = "https://pypi.org/simple" }
EOF
}

create_uv_mock() {
	# Mock 'uv' that records its calls and emulates 'uv lock' by
	# rewriting the own-package version in uv.lock (reads NEXT_VERSION
	# from the environment, like the real invocation would resolve it
	# from pyproject.toml).
	local pkg="$1"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_uv"
	: >"$calls_file"
	cat >"$mock_bin/uv" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'$calls_file'
python3 '$ECOSYSTEMS_DIR/update-uv-lock-version.py' uv.lock '$pkg' "\$NEXT_VERSION"
EOF
	chmod +x "$mock_bin/uv"
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

create_version_rb() {
	local dir="$1" gem="$2" version="${3:-1.0.0}"
	local gem_path="${gem//-//}"
	mkdir -p "$dir/lib/$gem_path"
	cat >"$dir/lib/$gem_path/version.rb" <<EOF
# frozen_string_literal: true

module TestGem
  VERSION = "$version"
end
EOF
}

create_gemspec() {
	local dir="$1" gem="$2"
	# Dynamic gemspec that loads version from lib/<gem>/version.rb — the
	# standard ruby convention that lets 'bundle lock --update' pick up
	# version changes made to version.rb.
	local gem_path="${gem//-//}"
	cat >"$dir/$gem.gemspec" <<EOF
require_relative "lib/${gem_path}/version"
Gem::Specification.new do |spec|
  spec.name = "$gem"
  spec.version = TestGem::VERSION
  spec.summary = "Test gem"
  spec.authors = ["Test"]
  spec.files = []
end
EOF
}

create_gemfile_lock() {
	local dir="$1" gem="$2" version="${3:-1.0.0}"
	cat >"$dir/Gemfile.lock" <<EOF
PATH
  remote: .
  specs:
    $gem ($version)

GEM
  remote: https://rubygems.org/
  specs:

PLATFORMS
  ruby

DEPENDENCIES
  $gem!

BUNDLED WITH
   2.4.10
EOF
}

create_gemfile() {
	local dir="$1" gem="$2"
	cat >"$dir/Gemfile" <<EOF
source "https://rubygems.org"
gemspec
EOF
}

create_version_swift() {
	local dir="$1" version="${2:-1.0.0}"
	mkdir -p "$dir/Sources/TestLib"
	cat >"$dir/Sources/TestLib/Version.swift" <<EOF
public enum Version {
    public static let string = "$version"
}
EOF
}

create_pubspec_yaml() {
	local dir="$1" version="${2:-1.0.0}"
	cat >"$dir/pubspec.yaml" <<EOF
name: test_app
version: $version
description: A test app
EOF
}

create_build_gradle() {
	local dir="$1" version="${2:-1.0.0}"
	cat >"$dir/build.gradle.kts" <<EOF
plugins {
    kotlin("jvm") version "1.9.0"
}

version = "$version"

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib")
}
EOF
}

run_ecosystem() {
	local script="$1"
	local dir="$2"
	local version="${3:-9.8.7}"
	local config="${4:-"{}"}"
	NEXT_VERSION="$version" \
		ECOSYSTEM_CONFIG_JSON="$config" \
		run bash -c "cd '$dir' && '$ECOSYSTEMS_DIR/$script' 2>&1"
}

run_ecosystem_without_cmd() {
	# Run an ecosystem script with a named command hidden from PATH via a
	# shim directory that wraps every other binary. This preserves
	# access to jq/sed/awk/etc. while making 'command -v <cmd>' fail.
	# Exec wrappers are used instead of symlinks so interpreters that
	# derive context from their executable path (e.g. Python venvs
	# locating pyvenv.cfg) keep working through the shim.
	local hidden_cmd="$1"
	local script="$2"
	local dir="$3"
	local version="${4:-9.8.7}"
	local config="${5:-"{}"}"
	local shim_dir="${BATS_TEST_TMPDIR}/shim_bin_$$"
	mkdir -p "$shim_dir"
	local d f name
	while IFS= read -r d; do
		[[ -d "$d" ]] || continue
		for f in "$d"/*; do
			[[ -x "$f" && ! -d "$f" ]] || continue
			name=$(basename "$f")
			[[ "$name" == "$hidden_cmd" ]] && continue
			[[ -e "$shim_dir/$name" ]] && continue
			# Absolute interpreter path: shebangs cannot point at
			# another script, and /usr/bin/env would resolve bash
			# through this same shim.
			printf '#!%s\nexec "%s" "$@"\n' "$BASH" "$f" >"$shim_dir/$name"
			chmod +x "$shim_dir/$name"
		done
	done < <(echo "$PATH" | tr ':' '\n')
	NEXT_VERSION="$version" \
		ECOSYSTEM_CONFIG_JSON="$config" \
		PATH="$shim_dir" \
		run bash -c "cd '$dir' && '$ECOSYSTEMS_DIR/$script' 2>&1"
}

run_ecosystem_no_bundle() {
	run_ecosystem_without_cmd "bundle" "$@"
}

run_runner() {
	local dir="$1"
	local ecosystems="$2"
	local version="${3:-9.8.7}"
	local config="${4:-"{}"}"
	NEXT_VERSION="$version" \
		ECOSYSTEMS="$ecosystems" \
		ECOSYSTEM_CONFIG="$config" \
		run bash -c "cd '$dir' && '$ECOSYSTEMS_DIR/_runner.sh' 2>&1"
}

# =============================================================================
# Tests: node.sh
# =============================================================================

@test "node: updates package.json version" {
	create_package_json "$BATS_TEST_TMPDIR" "1.0.0"

	run_ecosystem "node.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(jq -r '.version' "$BATS_TEST_TMPDIR/package.json")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "node: preserves 4-space indentation" {
	create_package_json "$BATS_TEST_TMPDIR" "1.0.0" 4

	run_ecosystem "node.sh" "$BATS_TEST_TMPDIR"
	assert_success

	# Check that indentation is 4 spaces
	INDENT=$(awk '/^[[:space:]]/ { match($0, /^[[:space:]]+/); print RLENGTH; exit }' "$BATS_TEST_TMPDIR/package.json")
	[[ "$INDENT" == "4" ]]
}

@test "node: preserves tab indentation" {
	create_package_json "$BATS_TEST_TMPDIR" "1.0.0" "tab"

	run_ecosystem "node.sh" "$BATS_TEST_TMPDIR"
	assert_success

	# Check that indentation is a tab
	head -2 "$BATS_TEST_TMPDIR/package.json" | tail -1 | grep -q $'^\t'
}

@test "node: fails when package.json missing" {
	run_ecosystem "node.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "not found"
}

# =============================================================================
# Tests: rust.sh
# =============================================================================

@test "rust: updates Cargo.toml version" {
	create_cargo_toml "$BATS_TEST_TMPDIR" "1.0.0"

	run_ecosystem "rust.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk -F'"' '/^\[package\]/ { in_pkg=1 } /^\[/ && !/^\[package\]/ { in_pkg=0 } in_pkg && /^version/ { print $2; exit }' "$BATS_TEST_TMPDIR/Cargo.toml")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "rust: does not touch dependency versions" {
	create_cargo_toml "$BATS_TEST_TMPDIR" "1.0.0"

	run_ecosystem "rust.sh" "$BATS_TEST_TMPDIR"
	assert_success

	# serde version should still be 1.0
	grep -q 'serde = { version = "1.0"' "$BATS_TEST_TMPDIR/Cargo.toml"
}

@test "rust: fails when Cargo.toml missing" {
	run_ecosystem "rust.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "not found"
}

# =============================================================================
# Tests: python.sh (__init__.py only — pyproject needs tomlkit)
# =============================================================================

@test "python: updates __init__.py __version__ (with tomlkit)" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test_pkg"
	create_init_py "$BATS_TEST_TMPDIR" "test_pkg" "1.0.0"

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/test_pkg/__init__.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: handles __version__=\"x\" without spaces (with tomlkit)" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test_pkg"
	mkdir -p "$BATS_TEST_TMPDIR/test_pkg"
	printf '__version__="1.0.0"\n' >"$BATS_TEST_TMPDIR/test_pkg/__init__.py"

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/test_pkg/__init__.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: auto-derives __init__.py from standard layout" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "my_app"
	create_init_py "$BATS_TEST_TMPDIR" "my_app" "1.0.0"

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/my_app/__init__.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: auto-derives __init__.py from src layout" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "my_app"
	# Use src/ layout instead of flat layout
	mkdir -p "$BATS_TEST_TMPDIR/src/my_app"
	cat >"$BATS_TEST_TMPDIR/src/my_app/__init__.py" <<EOF
"""My app."""

__version__ = "1.0.0"
EOF

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/src/my_app/__init__.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: verifies __init__.py after update when file has leading docstring" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "0.64.2" "lintro"
	mkdir -p "$BATS_TEST_TMPDIR/lintro"
	cat >"$BATS_TEST_TMPDIR/lintro/__init__.py" <<EOF
"""Lintro - A unified CLI core for code formatting, linting, and quality assurance."""

__version__ = "0.64.2"
EOF

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/lintro/__init__.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: normalizes hyphenated package name (PEP 503)" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	# pyproject has hyphenated name, but filesystem uses underscores
	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "my-cool-pkg"
	create_init_py "$BATS_TEST_TMPDIR" "my_cool_pkg" "1.0.0"

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/my_cool_pkg/__init__.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: skips __init__.py gracefully when none exists" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	# Only pyproject.toml, no package with __version__ (lgtm-ci case)
	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "lgtm-ci"

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success
	assert_line --partial "skipping"

	# pyproject.toml version should still be updated
	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-pyproject-field.py" "$BATS_TEST_TMPDIR/pyproject.toml" version)
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: uses config path overrides for pyproject and init" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	# Use paths that auto-discovery would NEVER find:
	# - pyproject in a non-standard subdirectory
	# - init file with a non-standard name and path that doesn't match
	#   the auto-derivation patterns (pkg/__init__.py or src/pkg/__init__.py)
	mkdir -p "$BATS_TEST_TMPDIR/custom/lib"
	create_pyproject_toml "$BATS_TEST_TMPDIR/custom" "1.0.0" "turbo-themes"
	cat >"$BATS_TEST_TMPDIR/custom/lib/version_info.py" <<EOF
"""Version info."""

__version__ = "1.0.0"
EOF

	# Also create a decoy at the auto-discoverable location to prove the
	# override is used instead of auto-discovery
	mkdir -p "$BATS_TEST_TMPDIR/custom/turbo_themes"
	cat >"$BATS_TEST_TMPDIR/custom/turbo_themes/__init__.py" <<EOF
"""Decoy — should NOT be touched."""

__version__ = "0.0.0"
EOF

	local config='{"pyproject":"custom/pyproject.toml","init":"custom/lib/version_info.py"}'
	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR" "9.8.7" "$config"
	assert_success

	# Verify pyproject.toml was updated
	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-pyproject-field.py" "$BATS_TEST_TMPDIR/custom/pyproject.toml" version)
	[[ "$ACTUAL" == "9.8.7" ]]

	# Verify the override init file was updated
	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/custom/lib/version_info.py")
	[[ "$ACTUAL" == "9.8.7" ]]

	# Verify the auto-discoverable decoy was NOT touched
	DECOY=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/custom/turbo_themes/__init__.py")
	[[ "$DECOY" == "0.0.0" ]]
}

@test "python: fails when pyproject.toml missing" {
	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "not found"
}

@test "python: re-locks uv.lock via uv lock when present" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test-pkg"
	create_uv_lock "$BATS_TEST_TMPDIR" "test-pkg" "1.0.0"
	create_uv_mock "test-pkg"

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success
	assert_line --partial "Re-locking"

	# uv was invoked with 'lock' (no --upgrade)
	grep -qx "lock" "$BATS_TEST_TMPDIR/mock_calls_uv"

	# Own package re-locked; dependency untouched
	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "test-pkg")
	[[ "$ACTUAL" == "9.8.7" ]]
	DEP=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "requests")
	[[ "$DEP" == "2.32.3" ]]
}

@test "python: updates uv.lock via tomlkit fallback when uv unavailable" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test-pkg"
	create_uv_lock "$BATS_TEST_TMPDIR" "test-pkg" "1.0.0"

	run_ecosystem_without_cmd "uv" "python.sh" "$BATS_TEST_TMPDIR"
	assert_success
	assert_line --partial "tomlkit fallback"

	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "test-pkg")
	[[ "$ACTUAL" == "9.8.7" ]]
	DEP=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "requests")
	[[ "$DEP" == "2.32.3" ]]
}

@test "python: normalizes package name for uv.lock lookup (PEP 503)" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	# pyproject has a mixed-case, dotted/underscored name; uv.lock
	# records the normalized form (lowercase, [-_.] runs to a dash)
	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "My_Cool.Pkg"
	create_uv_lock "$BATS_TEST_TMPDIR" "my-cool-pkg" "1.0.0"

	run_ecosystem_without_cmd "uv" "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "my-cool-pkg")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: skips uv.lock re-lock when absent" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test_pkg"
	create_init_py "$BATS_TEST_TMPDIR" "test_pkg" "1.0.0"

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success
	assert_line --partial "No uv.lock found"

	# pyproject.toml still updated
	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-pyproject-field.py" "$BATS_TEST_TMPDIR/pyproject.toml" version)
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: falls back to tomlkit when uv lock fails" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test-pkg"
	create_uv_lock "$BATS_TEST_TMPDIR" "test-pkg" "1.0.0"
	# uv exists but fails (e.g. blocked egress on hardened runners)
	mock_command "uv" "error: network unreachable" 1

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_success
	assert_line --partial "uv lock failed"

	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "test-pkg")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: finds workspace-root uv.lock for subdirectory pyproject" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	# uv workspace layout: member pyproject in a subdirectory, single
	# lockfile at the workspace root.
	mkdir -p "$BATS_TEST_TMPDIR/pkg"
	create_pyproject_toml "$BATS_TEST_TMPDIR/pkg" "1.0.0" "test-pkg"
	cat >"$BATS_TEST_TMPDIR/uv.lock" <<EOF
version = 1
revision = 3
requires-python = ">=3.11"

[[package]]
name = "test-pkg"
version = "1.0.0"
source = { editable = "pkg" }

[[package]]
name = "requests"
version = "2.32.3"
source = { registry = "https://pypi.org/simple" }
EOF

	run_ecosystem_without_cmd "uv" "python.sh" "$BATS_TEST_TMPDIR" \
		"9.8.7" '{"pyproject": "pkg/pyproject.toml"}'
	assert_success
	assert_line --partial "tomlkit fallback"

	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "test-pkg")
	[[ "$ACTUAL" == "9.8.7" ]]
	DEP=$(python3 "$ECOSYSTEMS_DIR/read-uv-lock-version.py" "$BATS_TEST_TMPDIR/uv.lock" "requests")
	[[ "$DEP" == "2.32.3" ]]
}

@test "python: uv.lock fallback updates local entry, not same-name registry entry" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test-pkg"
	# Same-name registry entry listed BEFORE the local project entry:
	# the fallback must update the editable entry only.
	cat >"$BATS_TEST_TMPDIR/uv.lock" <<EOF
version = 1
revision = 3
requires-python = ">=3.11"

[[package]]
name = "test-pkg"
version = "0.0.1"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "test-pkg"
version = "1.0.0"
source = { editable = "." }
EOF

	run_ecosystem_without_cmd "uv" "python.sh" "$BATS_TEST_TMPDIR"
	assert_success

	# Local (editable) entry re-locked; registry entry untouched
	python3 - "$BATS_TEST_TMPDIR/uv.lock" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
versions = {}
for pkg in data["package"]:
    source = pkg.get("source", {})
    kind = "registry" if "registry" in source else "local"
    versions[kind] = pkg["version"]
assert versions["local"] == "9.8.7", versions
assert versions["registry"] == "0.0.1", versions
PY
}

@test "python: fails when uv lock does not update own-package version" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	create_pyproject_toml "$BATS_TEST_TMPDIR" "1.0.0" "test-pkg"
	create_uv_lock "$BATS_TEST_TMPDIR" "test-pkg" "1.0.0"
	# No-op uv: 'uv lock' succeeds but leaves uv.lock unchanged
	mock_command "uv" ""

	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "uv.lock verification failed"
}

# =============================================================================
# Tests: ruby.sh
# =============================================================================

@test "ruby: updates version.rb" {
	create_gemspec "$BATS_TEST_TMPDIR" "test-gem"
	create_version_rb "$BATS_TEST_TMPDIR" "test-gem" "1.0.0"

	run_ecosystem "ruby.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk -F'"' '/VERSION =/ {print $2; exit}' "$BATS_TEST_TMPDIR/lib/test/gem/version.rb")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "ruby: auto-detects gem name from gemspec" {
	create_gemspec "$BATS_TEST_TMPDIR" "my-gem"
	create_version_rb "$BATS_TEST_TMPDIR" "my-gem" "1.0.0"

	run_ecosystem "ruby.sh" "$BATS_TEST_TMPDIR"
	assert_success
	assert_line --partial "Auto-detected gem name: my-gem"
}

@test "ruby: fails when no gemspec and no config" {
	run_ecosystem "ruby.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "No gem name configured"
}

@test "ruby: updates Gemfile.lock via regex fallback when bundle unavailable" {
	create_gemspec "$BATS_TEST_TMPDIR" "test-gem"
	create_version_rb "$BATS_TEST_TMPDIR" "test-gem" "1.0.0"
	create_gemfile_lock "$BATS_TEST_TMPDIR" "test-gem" "1.0.0"

	run_ecosystem_no_bundle "ruby.sh" "$BATS_TEST_TMPDIR"
	assert_success
	assert_line --partial "regex fallback"
	grep -q "test-gem (9.8.7)" "$BATS_TEST_TMPDIR/Gemfile.lock"
}

@test "ruby: updates Gemfile.lock via bundle lock when bundle available" {
	if ! command -v bundle >/dev/null 2>&1; then
		skip "bundle not available"
	fi
	create_gemspec "$BATS_TEST_TMPDIR" "test-gem"
	create_version_rb "$BATS_TEST_TMPDIR" "test-gem" "1.0.0"
	create_gemfile "$BATS_TEST_TMPDIR" "test-gem"
	create_gemfile_lock "$BATS_TEST_TMPDIR" "test-gem" "1.0.0"

	run_ecosystem "ruby.sh" "$BATS_TEST_TMPDIR"
	assert_success
	grep -q "test-gem (9.8.7)" "$BATS_TEST_TMPDIR/Gemfile.lock"
}

# =============================================================================
# Tests: swift.sh
# =============================================================================

@test "swift: updates Version.swift" {
	create_version_swift "$BATS_TEST_TMPDIR" "1.0.0"

	run_ecosystem "swift.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk -F'"' '/static let .* = "/ {print $2; exit}' "$BATS_TEST_TMPDIR/Sources/TestLib/Version.swift")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "swift: errors on multiple Version.swift files" {
	create_version_swift "$BATS_TEST_TMPDIR" "1.0.0"
	mkdir -p "$BATS_TEST_TMPDIR/Sources/OtherLib"
	cp "$BATS_TEST_TMPDIR/Sources/TestLib/Version.swift" "$BATS_TEST_TMPDIR/Sources/OtherLib/Version.swift"

	run_ecosystem "swift.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "Multiple Version.swift"
}

@test "swift: fails when no Version.swift found" {
	run_ecosystem "swift.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "No Version.swift found"
}

@test "swift: errors when file has multiple candidate constants" {
	mkdir -p "$BATS_TEST_TMPDIR/Sources/TestLib"
	cat >"$BATS_TEST_TMPDIR/Sources/TestLib/Version.swift" <<'EOF'
public enum Info {
    public static let name = "MyLib"
    public static let version = "1.0.0"
}
EOF
	run_ecosystem "swift.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "2 candidate constants"
}

# =============================================================================
# Tests: dart.sh
# =============================================================================

@test "dart: updates pubspec.yaml version" {
	create_pubspec_yaml "$BATS_TEST_TMPDIR" "1.0.0"

	run_ecosystem "dart.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(sed -n 's/^version: //p' "$BATS_TEST_TMPDIR/pubspec.yaml")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "dart: fails when pubspec.yaml missing" {
	run_ecosystem "dart.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "not found"
}

# =============================================================================
# Tests: kotlin.sh
# =============================================================================

@test "kotlin: updates build.gradle.kts version" {
	create_build_gradle "$BATS_TEST_TMPDIR" "1.0.0"

	run_ecosystem "kotlin.sh" "$BATS_TEST_TMPDIR"
	assert_success

	ACTUAL=$(awk -F'"' '/version[[:space:]]*=[[:space:]]*"/ {print $2; exit}' "$BATS_TEST_TMPDIR/build.gradle.kts")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "kotlin: fails when build.gradle.kts missing" {
	run_ecosystem "kotlin.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "not found"
}

# =============================================================================
# Tests: _runner.sh
# =============================================================================

@test "runner: runs a single valid ecosystem" {
	create_pubspec_yaml "$BATS_TEST_TMPDIR" "1.0.0"

	run_runner "$BATS_TEST_TMPDIR" "dart"
	assert_success
	assert_line --partial "All ecosystem updaters completed"

	ACTUAL=$(sed -n 's/^version: //p' "$BATS_TEST_TMPDIR/pubspec.yaml")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "runner: runs multiple ecosystems" {
	create_pubspec_yaml "$BATS_TEST_TMPDIR" "1.0.0"
	create_build_gradle "$BATS_TEST_TMPDIR" "1.0.0"

	run_runner "$BATS_TEST_TMPDIR" "dart,kotlin"
	assert_success
	assert_line --partial "All ecosystem updaters completed"

	DART_VER=$(sed -n 's/^version: //p' "$BATS_TEST_TMPDIR/pubspec.yaml")
	KOTLIN_VER=$(awk -F'"' '/version[[:space:]]*=[[:space:]]*"/ {print $2; exit}' "$BATS_TEST_TMPDIR/build.gradle.kts")
	[[ "$DART_VER" == "9.8.7" ]]
	[[ "$KOTLIN_VER" == "9.8.7" ]]
}

@test "runner: rejects unknown ecosystem via allowlist" {
	run_runner "$BATS_TEST_TMPDIR" "evil"
	assert_failure
	assert_line --partial "Unknown ecosystem: evil"
	assert_line --partial "allowed:"
}

@test "runner: rejects invalid semver" {
	run bash -c "
		cd '$BATS_TEST_TMPDIR'
		export NEXT_VERSION='not-a-version'
		export ECOSYSTEMS='dart'
		export ECOSYSTEM_CONFIG='{}'
		'$ECOSYSTEMS_DIR/_runner.sh' 2>&1
	"
	assert_failure
	assert_line --partial "not valid semver"
}

@test "runner: handles whitespace in ecosystem list" {
	create_pubspec_yaml "$BATS_TEST_TMPDIR" "1.0.0"

	run_runner "$BATS_TEST_TMPDIR" " dart , "
	assert_success

	ACTUAL=$(sed -n 's/^version: //p' "$BATS_TEST_TMPDIR/pubspec.yaml")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "runner: passes ECOSYSTEM_CONFIG overrides to scripts" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not available"
	fi

	# Use non-discoverable paths: pyproject in a non-standard dir and init
	# at a custom path that auto-derivation would never find
	mkdir -p "$BATS_TEST_TMPDIR/custom/lib"
	create_pyproject_toml "$BATS_TEST_TMPDIR/custom" "1.0.0" "turbo-themes"
	cat >"$BATS_TEST_TMPDIR/custom/lib/ver.py" <<EOF
"""Version."""

__version__ = "1.0.0"
EOF

	local config
	config='{"python":{"pyproject":"custom/pyproject.toml","init":"custom/lib/ver.py"}}'

	run_runner "$BATS_TEST_TMPDIR" "python" "9.8.7" "$config"
	assert_success
	assert_line --partial "Config overrides:"

	# Verify the config was used: pyproject at custom path was updated
	ACTUAL=$(python3 "$ECOSYSTEMS_DIR/read-pyproject-field.py" "$BATS_TEST_TMPDIR/custom/pyproject.toml" version)
	[[ "$ACTUAL" == "9.8.7" ]]

	# Verify the custom init file was updated
	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/custom/lib/ver.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "runner: passes gem config override to ruby" {
	# No gemspec — without the config override, auto-detection would fail
	# with "No gem name configured and no .gemspec found". Only the config
	# provides the gem name, proving the runner wires it through.
	# No Gemfile.lock either — isolates the test to version.rb only.
	create_version_rb "$BATS_TEST_TMPDIR" "custom-gem" "1.0.0"

	local config='{"ruby":{"gem":"custom-gem"}}'

	run_runner "$BATS_TEST_TMPDIR" "ruby" "9.8.7" "$config"
	assert_success
	assert_line --partial "Config overrides:"

	ACTUAL=$(awk -F'"' '/VERSION =/ {print $2; exit}' "$BATS_TEST_TMPDIR/lib/custom/gem/version.rb")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "runner: rejects non-object ECOSYSTEM_CONFIG" {
	# Valid JSON string (not an object) — exercises type validation
	run bash -c '
		cd "'"$BATS_TEST_TMPDIR"'"
		export NEXT_VERSION="1.0.0"
		export ECOSYSTEMS="dart"
		export ECOSYSTEM_CONFIG="\"not-an-object\""
		"'"$ECOSYSTEMS_DIR"'/_runner.sh" 2>&1
	'
	assert_failure
	assert_line --partial "not a valid JSON object"
}

@test "runner: rejects non-object per-ecosystem config value" {
	create_pubspec_yaml "$BATS_TEST_TMPDIR" "1.0.0"

	local config='{"dart":"string-not-object"}'
	run_runner "$BATS_TEST_TMPDIR" "dart" "9.8.7" "$config"
	assert_failure
	assert_line --partial "must be a JSON object"
}

@test "runner: fails if any ecosystem fails" {
	create_pubspec_yaml "$BATS_TEST_TMPDIR" "1.0.0"
	# kotlin will fail because build.gradle.kts doesn't exist

	run_runner "$BATS_TEST_TMPDIR" "dart,kotlin"
	assert_failure
	assert_line --partial "One or more ecosystem updaters failed"

	# dart should still have been updated before kotlin failed
	ACTUAL=$(sed -n 's/^version: //p' "$BATS_TEST_TMPDIR/pubspec.yaml")
	[[ "$ACTUAL" == "9.8.7" ]]
}
