#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/testing/rust/fail-on-coverage.sh"
}

@test "fail-on-coverage succeeds when Rust exit code is zero" {
	RUST_COVERAGE_EXIT_CODE=0 COVERAGE_NAME=Rust run bash "$SCRIPT"
	[ "$status" -eq 0 ]
}

@test "fail-on-coverage fails when Rust exit code is non-zero" {
	RUST_COVERAGE_EXIT_CODE=1 COVERAGE_NAME=Rust run bash "$SCRIPT"
	[ "$status" -eq 1 ]
}

@test "fail-on-coverage fails when Web exit code is non-zero" {
	WEB_COVERAGE_EXIT_CODE=2 COVERAGE_NAME=Web run bash "$SCRIPT"
	[ "$status" -eq 2 ]
}
