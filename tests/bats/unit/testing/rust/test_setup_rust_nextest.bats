#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Behavioral tests for scripts/ci/testing/rust/setup-rust-nextest.sh

load "../../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/testing/rust/setup-rust-nextest.sh"

setup() {
	setup_temp_dir
	export CALLS_FILE="${BATS_TEST_TMPDIR}/mock_calls"
	: >"$CALLS_FILE"
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/cargo-binstall" <<EOF
#!/usr/bin/env bash
printf 'binstall %s\n' "\$*" >>'${CALLS_FILE}'
exit 0
EOF
	chmod +x "${mock_bin}/cargo-binstall"
	cat >"${mock_bin}/cargo" <<EOF
#!/usr/bin/env bash
printf 'cargo %s\n' "\$*" >>'${CALLS_FILE}'
exit 0
EOF
	chmod +x "${mock_bin}/cargo"
	cat >"${mock_bin}/cargo-nextest" <<'EOF'
#!/usr/bin/env bash
echo "cargo-nextest 0.0.0"
exit 0
EOF
	chmod +x "${mock_bin}/cargo-nextest"
	export MOCK_BIN="$mock_bin"
}

teardown() {
	teardown_temp_dir
}

@test "setup-rust-nextest: installs the annotated nextest pin via cargo-binstall" {
	run env PATH="${MOCK_BIN}:${PATH}" INSTALL_COVERAGE_TOOLS=false bash "$SCRIPT"
	assert_success
	run cat "$CALLS_FILE"
	assert_output --partial "binstall cargo-nextest --version 0.9.92"
}

@test "setup-rust-nextest: installs llvm-cov when coverage tools are requested" {
	cat >"${MOCK_BIN}/rustup" <<EOF
#!/usr/bin/env bash
printf 'rustup %s\n' "\$*" >>'${CALLS_FILE}'
exit 0
EOF
	chmod +x "${MOCK_BIN}/rustup"
	cat >"${MOCK_BIN}/cargo-llvm-cov" <<'EOF'
#!/usr/bin/env bash
echo "cargo-llvm-cov 0.0.0"
exit 0
EOF
	chmod +x "${MOCK_BIN}/cargo-llvm-cov"
	run env PATH="${MOCK_BIN}:${PATH}" INSTALL_COVERAGE_TOOLS=true bash "$SCRIPT"
	assert_success
	run cat "$CALLS_FILE"
	assert_output --partial "binstall cargo-llvm-cov --version 0.8.6"
}

@test "setup-rust-nextest: env override wins over the annotated default" {
	run env PATH="${MOCK_BIN}:${PATH}" CARGO_NEXTEST_VERSION=0.9.1 \
		INSTALL_COVERAGE_TOOLS=false bash "$SCRIPT"
	assert_success
	run cat "$CALLS_FILE"
	assert_output --partial "binstall cargo-nextest --version 0.9.1"
	refute_output --partial "--version 0.9.92"
}
