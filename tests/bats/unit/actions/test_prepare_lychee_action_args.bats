#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/prepare-lychee-action-args.sh"
	setup_temp_dir
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "prepare-lychee-action-args strips format and output flags" {
	export RAW_ARGS="--no-progress --format markdown --output lychee-report.md --offline 'apps/site/dist/**/*.html'"
	export LYCHEE_ROOT_DIR="apps/site/dist"
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q -- '--root-dir apps/site/dist' "$GITHUB_OUTPUT"
	! grep -q -- '--format' "$GITHUB_OUTPUT" || false
	! grep -q -- '--output' "$GITHUB_OUTPUT" || false
}

@test "prepare-lychee-action-args requires LYCHEE_ROOT_DIR" {
	export RAW_ARGS="--offline"
	unset LYCHEE_ROOT_DIR
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 1 ]
	[[ "$output" == *"LYCHEE_ROOT_DIR is required"* ]]
}

@test "prepare-lychee-action-args requires RAW_ARGS" {
	unset RAW_ARGS
	export LYCHEE_ROOT_DIR="dist"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 1 ]
	[[ "$output" == *"RAW_ARGS is required"* ]]
}
