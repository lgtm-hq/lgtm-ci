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
	run tar -tzf "myapp-2.0.0-${target}.tar.gz"
	assert_success
	assert_output --partial 'myapp'
	run bash -c 'tar -tzf "myapp-2.0.0-'"${target}"'.tar.gz" | grep -c / || true'
	assert_success
	assert_equal 0 "$output"
}

@test "package-rust-binary: skips empty package entries without shifting binary names" {
	local target="x86_64-unknown-linux-musl"
	mkdir -p "target/${target}/release"
	printf 'elf' >"target/${target}/release/cli-bin"
	printf 'elf' >"target/${target}/release/server-bin"

	run env \
		VERSION=3.0.0 \
		TARGET="$target" \
		PACKAGES='cli,,server' \
		BINARY_NAMES='cli-bin,wrong-name,server-bin' \
		ARCHIVE_FORMAT=tar.gz \
		bash "$SCRIPT"
	assert_success

	[[ -f cli-3.0.0-${target}.tar.gz ]]
	[[ -f server-3.0.0-${target}.tar.gz ]]
	[[ ! -f wrong-name-3.0.0-${target}.tar.gz ]]
}

@test "package-rust-binary: uses TARGET not ARCHIVE_FORMAT for Windows exe suffix" {
	local target="x86_64-pc-windows-msvc"
	mkdir -p "target/${target}/release"
	printf 'MZ' >"target/${target}/release/myapp.exe"

	run env \
		VERSION=4.0.0 \
		TARGET="$target" \
		PACKAGES=myapp \
		BINARY_NAMES=myapp \
		ARCHIVE_FORMAT=tar.gz \
		bash "$SCRIPT"
	assert_success

	run tar -tzf "myapp-4.0.0-${target}.tar.gz"
	assert_success
	assert_output --partial 'myapp.exe'
}

@test "package-rust-binary: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}
