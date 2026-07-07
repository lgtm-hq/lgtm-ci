#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/lib/cargo/version.sh

load "../../../../helpers/common"

LIB="${PROJECT_ROOT}/scripts/ci/lib/cargo/version.sh"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR"
	# shellcheck source=/dev/null
	source "$LIB"
}

teardown() {
	teardown_temp_dir
}

@test "parse_cargo_version: reads indented workspace.package version" {
	cat >Cargo.toml <<'EOF'
[workspace.package]
  version = "1.2.3"
EOF

	run parse_cargo_version Cargo.toml
	assert_success
	assert_output "1.2.3"
}

@test "parse_cargo_version: returns failure when version key is absent" {
	cat >Cargo.toml <<'EOF'
[package]
name = "demo"
EOF

	run parse_cargo_version Cargo.toml
	assert_failure
}

@test "parse_cargo_version: returns failure when manifest is missing" {
	run parse_cargo_version missing.toml
	assert_failure
}
