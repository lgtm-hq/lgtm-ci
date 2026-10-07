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

@test "build-rust-binary.sh: BUILDER=cross selects cross" {
	mock_command_record "cross"

	run env \
		TARGET=aarch64-unknown-linux-gnu \
		PACKAGES=cli \
		BUILDER=cross \
		bash "$SCRIPT"
	assert_success
	assert_output --partial "Building cli with cross for target aarch64-unknown-linux-gnu"
}

@test "build-rust-binary.sh: rejects cross with an MSVC target before building" {
	mock_command_record "cross"
	mock_command_record "cargo"

	run env \
		TARGET=x86_64-pc-windows-msvc \
		PACKAGES=cli \
		BUILDER=cross \
		bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "cross cannot build MSVC targets; use builder=xwin or a native Windows runner"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_cross"
	assert_output ""
	run cat "${BATS_TEST_TMPDIR}/mock_calls_cargo"
	assert_output ""
}

@test "build-rust-binary.sh: legacy USE_CROSS=true with an MSVC target is rejected too" {
	mock_command_record "cross"

	run env \
		TARGET=x86_64-pc-windows-msvc \
		PACKAGES=cli \
		USE_CROSS=true \
		bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "cross cannot build MSVC targets"
}

@test "build-rust-binary.sh: BUILDER=xwin runs cargo xwin build with the target architecture" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/cargo" <<EOF
#!/usr/bin/env bash
printf '%s|XWIN_ARCH=%s\n' "\$*" "\${XWIN_ARCH:-unset}" >>'${BATS_TEST_TMPDIR}/mock_calls_cargo'
EOF
	chmod +x "${mock_bin}/cargo"
	export PATH="${mock_bin}:${PATH}"

	run env \
		TARGET=x86_64-pc-windows-msvc \
		PACKAGES=cli \
		BUILDER=xwin \
		bash "$SCRIPT"
	assert_success
	assert_output --partial "Building cli with cargo xwin for target x86_64-pc-windows-msvc"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_cargo"
	assert_output "xwin build --release --target x86_64-pc-windows-msvc -p cli|XWIN_ARCH=x86_64"
}

@test "build-rust-binary.sh: BUILDER=xwin keeps a caller-provided XWIN_ARCH" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/cargo" <<EOF
#!/usr/bin/env bash
printf 'XWIN_ARCH=%s\n' "\${XWIN_ARCH:-unset}" >>'${BATS_TEST_TMPDIR}/mock_calls_cargo'
EOF
	chmod +x "${mock_bin}/cargo"
	export PATH="${mock_bin}:${PATH}"

	run env \
		TARGET=aarch64-pc-windows-msvc \
		PACKAGES=cli \
		BUILDER=xwin \
		XWIN_ARCH=aarch64 \
		bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_cargo"
	assert_output "XWIN_ARCH=aarch64"
}

@test "build-rust-binary.sh: rejects xwin with a non-MSVC target" {
	mock_command_record "cargo"

	run env \
		TARGET=x86_64-pc-windows-gnu \
		PACKAGES=cli \
		BUILDER=xwin \
		bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "xwin only builds *-pc-windows-msvc targets"
}

@test "build-rust-binary.sh: rejects an unknown BUILDER" {
	mock_command_record "cargo"

	run env \
		TARGET=x86_64-unknown-linux-gnu \
		PACKAGES=cli \
		BUILDER=zig \
		bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "unknown BUILDER 'zig'"
}
