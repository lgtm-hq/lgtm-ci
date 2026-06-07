#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/read-cargo-version.sh

load "../../helpers/common"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export PROJECT_ROOT
	cd "$BATS_TEST_TMPDIR"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_read() {
	local version_file="${1:-Cargo.toml}"
	run bash -c "
		cd '$BATS_TEST_TMPDIR'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export VERSION_FILE='$version_file'
		'$PROJECT_ROOT/scripts/ci/release/read-cargo-version.sh' 2>&1
	"
}

@test "read-cargo-version: reads workspace.package version" {
	cat >Cargo.toml <<'EOF'
[workspace.package]
version = "0.4.2"
EOF

	run_read
	assert_success
	assert_line --partial "version=0.4.2"
	assert_line --partial "found=true"
}

@test "read-cargo-version: fails when manifest is missing" {
	run_read "missing.toml"
	assert_failure
}

@test "read-cargo-version: fails when version is invalid semver" {
	cat >Cargo.toml <<'EOF'
[package]
name = "demo"
version = "not-semver"
EOF

	run_read
	assert_failure
}
