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
	local config="${4:-{}}"
	NEXT_VERSION="$version" \
		ECOSYSTEM_CONFIG_JSON="$config" \
		run bash -c "cd '$dir' && '$ECOSYSTEMS_DIR/$script' 2>&1"
}

run_ecosystem_no_bundle() {
	# Run an ecosystem script with 'bundle' hidden from PATH via a shim
	# directory that symlinks every other binary. This preserves access
	# to jq/sed/awk/etc. while making 'command -v bundle' fail.
	local script="$1"
	local dir="$2"
	local version="${3:-9.8.7}"
	local shim_dir="${BATS_TEST_TMPDIR}/shim_bin_$$"
	mkdir -p "$shim_dir"
	local d f name
	while IFS= read -r d; do
		[[ -d "$d" ]] || continue
		for f in "$d"/*; do
			[[ -e "$f" ]] || continue
			name=$(basename "$f")
			[[ "$name" == "bundle" ]] && continue
			[[ -e "$shim_dir/$name" ]] && continue
			ln -sf "$f" "$shim_dir/$name"
		done
	done < <(echo "$PATH" | tr ':' '\n')
	NEXT_VERSION="$version" \
		ECOSYSTEM_CONFIG_JSON='{}' \
		PATH="$shim_dir" \
		run bash -c "cd '$dir' && '$ECOSYSTEMS_DIR/$script' 2>&1"
}

run_runner() {
	local dir="$1"
	local ecosystems="$2"
	local version="${3:-9.8.7}"
	local config="${4:-{}}"
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

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/.*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/test_pkg/__init__.py")
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

	ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/.*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$BATS_TEST_TMPDIR/test_pkg/__init__.py")
	[[ "$ACTUAL" == "9.8.7" ]]
}

@test "python: fails when pyproject.toml missing" {
	run_ecosystem "python.sh" "$BATS_TEST_TMPDIR"
	assert_failure
	assert_line --partial "not found"
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
