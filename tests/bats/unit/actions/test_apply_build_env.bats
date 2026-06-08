#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/apply-build-env.sh"
	setup_temp_dir
	export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
	: >"$GITHUB_ENV"
}

teardown() {
	teardown_temp_dir
}

@test "apply-build-env writes valid KEY=value lines" {
	export BUILD_ENV=$'ASTRO_BASE=/\n# comment\n\nFOO=bar'
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^ASTRO_BASE=/$' "$GITHUB_ENV"
	grep -q '^FOO=bar$' "$GITHUB_ENV"
	! grep -q '^#' "$GITHUB_ENV" || false
}

@test "apply-build-env rejects GITHUB_ENV heredoc injection lines" {
	export BUILD_ENV=$'FOO<<EOF\ninjected\nEOF'
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 1 ]
	[[ "$output" == *"Invalid build-env line rejected"* ]]
	! grep -q '^FOO=' "$GITHUB_ENV" || false
}

@test "apply-build-env rejects keys with invalid characters" {
	export BUILD_ENV='bad-key=value'
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 1 ]
	[[ "$output" == *"Invalid build-env line rejected"* ]]
}
