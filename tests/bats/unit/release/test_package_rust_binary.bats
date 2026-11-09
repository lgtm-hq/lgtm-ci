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
	# A stand-in file, not an executable: packaging only needs a path. The
	# compile+run proof for the Windows leg is the consumer fixture's
	# rust-release-build.yml job on windows-latest (#1076).
	printf 'stand-in' >"target/${target}/release/myapp.exe"

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
	# A stand-in file, not an executable: packaging only needs a path. The
	# compile+run proof for the Windows leg is the consumer fixture's
	# rust-release-build.yml job on windows-latest (#1076).
	printf 'stand-in' >"target/${target}/release/myapp.exe"

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

# Run the packager with PATH limited to the given tools (no sha256sum/shasum
# unless listed), from the current directory.
_run_packager_with_tools() {
	local bin="${BATS_TEST_TMPDIR}/tools-bin" tool real
	mkdir -p "$bin"
	for tool in "$@"; do
		real="$(command -v "$tool")"
		ln -sf "$real" "${bin}/${tool}"
	done
	run env PATH="$bin" \
		VERSION=4.0.0 \
		TARGET=x86_64-unknown-linux-musl \
		PACKAGES=myapp \
		BINARY_NAMES=myapp \
		ARCHIVE_FORMAT=tar.gz \
		"$BASH" "$SCRIPT"
}

_packager_tools=(mkdir cp rm tar gzip awk cat dirname)

_stage_myapp() {
	mkdir -p "target/x86_64-unknown-linux-musl/release"
	printf 'elf' >"target/x86_64-unknown-linux-musl/release/myapp"
}

@test "package-rust-binary: checksum line is '<digest>  <archive>' (sha256sum)" {
	command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not installed"
	_stage_myapp
	_run_packager_with_tools "${_packager_tools[@]}" sha256sum
	assert_success
	local archive="myapp-4.0.0-x86_64-unknown-linux-musl.tar.gz" expected
	expected="$(sha256sum "$archive" | awk '{print $1}')"
	run cat "SHA256SUMS-x86_64-unknown-linux-musl"
	assert_success
	assert_output "${expected}  ${archive}"
}

@test "package-rust-binary: falls back to shasum when sha256sum is absent" {
	command -v shasum >/dev/null 2>&1 || skip "shasum not installed"
	_stage_myapp
	_run_packager_with_tools "${_packager_tools[@]}" shasum perl
	assert_success
	local archive="myapp-4.0.0-x86_64-unknown-linux-musl.tar.gz" expected
	expected="$(shasum -a 256 "$archive" | awk '{print $1}')"
	run cat "SHA256SUMS-x86_64-unknown-linux-musl"
	assert_output "${expected}  ${archive}"
}

@test "package-rust-binary: fails with a clear message when no sha256 tool exists" {
	_stage_myapp
	_run_packager_with_tools "${_packager_tools[@]}"
	assert_failure
	assert_output --partial "No sha256 tool available"
}
