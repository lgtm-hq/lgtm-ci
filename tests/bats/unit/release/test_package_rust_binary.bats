#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/package-rust-binary.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/package-rust-binary.sh"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR"
}

teardown() {
	teardown_temp_dir
}

@test "package-rust-binary: zip archive contains the Windows executable" {
	local target="x86_64-pc-windows-msvc"
	mkdir -p "target/${target}/release"
	printf 'MZ' >"target/${target}/release/myapp.exe"

	run env \
		VERSION=1.2.3 \
		TARGET="$target" \
		PACKAGES=myapp \
		BINARY_NAMES=myapp \
		ARCHIVE_FORMAT=zip \
		bash "$SCRIPT"
	assert_success

	[[ -f myapp-1.2.3-${target}.zip ]]
	run unzip -l "myapp-1.2.3-${target}.zip"
	assert_success
	assert_output --partial 'myapp.exe'
}

@test "package-rust-binary: writes per-target SHA256SUMS manifest" {
	local target="x86_64-unknown-linux-musl"
	mkdir -p "target/${target}/release"
	printf 'elf' >"target/${target}/release/myapp"

	run env \
		VERSION=2.0.0 \
		TARGET="$target" \
		PACKAGES=myapp \
		BINARY_NAMES=myapp \
		ARCHIVE_FORMAT=tar.gz \
		bash "$SCRIPT"
	assert_success

	[[ -f "SHA256SUMS-${target}" ]]
	run grep -F 'myapp-2.0.0-'"${target}"'.tar.gz' "SHA256SUMS-${target}"
	assert_success
}

@test "package-rust-binary: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}
