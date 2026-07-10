#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/build-rust-binary.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/build-rust-binary.sh"

setup() {
	setup_temp_dir
	save_path
}

teardown() {
	restore_path
	teardown_temp_dir
}

@test "build-rust-binary.sh: fails without TARGET" {
	run env -u TARGET PACKAGES=cli bash "$SCRIPT"
	assert_failure
	assert_output --partial "TARGET and PACKAGES are required"
}

@test "build-rust-binary.sh: fails without PACKAGES" {
	run env -u PACKAGES TARGET=x86_64-unknown-linux-gnu bash "$SCRIPT"
	assert_failure
	assert_output --partial "TARGET and PACKAGES are required"
}

@test "build-rust-binary.sh: invokes cargo build for each package" {
	mock_command_record "cargo"

	run env \
		TARGET=x86_64-unknown-linux-gnu \
		PACKAGES='cli, server' \
		bash "$SCRIPT"
	assert_success
	assert_output --partial "Building cli with cargo for target x86_64-unknown-linux-gnu"
	assert_output --partial "Building server with cargo for target x86_64-unknown-linux-gnu"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_cargo"
	assert_output --partial "build --release --target x86_64-unknown-linux-gnu -p cli"
	assert_output --partial "build --release --target x86_64-unknown-linux-gnu -p server"
}

@test "build-rust-binary.sh: uses cross when USE_CROSS=true" {
	mock_command_record "cross"

	run env \
		TARGET=aarch64-unknown-linux-gnu \
		PACKAGES=cli \
		USE_CROSS=true \
		bash "$SCRIPT"
	assert_success
	assert_output --partial "Building cli with cross for target aarch64-unknown-linux-gnu"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_cross"
	assert_output --partial "build --release --target aarch64-unknown-linux-gnu -p cli"
}
