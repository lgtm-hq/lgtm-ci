#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/validate-version-update-script.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/workspace"
	mkdir -p "$GITHUB_WORKSPACE/scripts/ci"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_validator() {
	run bash "$PROJECT_ROOT/scripts/ci/release/validate-version-update-script.sh"
}

@test "validate-version-update-script: resolves script inside workspace" {
	local script="$GITHUB_WORKSPACE/scripts/ci/update-version.sh"
	local expected
	printf '#!/usr/bin/env bash\n' >"$script"
	expected="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script")"

	export RAW_SCRIPT_PATH="$script"

	run_validator

	assert_success
	assert_output --partial "Validated version update script: $expected"
	assert_file_contains "$GITHUB_OUTPUT" "resolved=$expected"
	[[ -x "$script" ]]
}

@test "validate-version-update-script: fails when script is missing" {
	export RAW_SCRIPT_PATH="$GITHUB_WORKSPACE/scripts/ci/missing.sh"

	run_validator

	assert_failure
	assert_output --partial "version-update-script not found"
}

@test "validate-version-update-script: rejects script outside workspace" {
	local script="$BATS_TEST_TMPDIR/outside.sh"
	printf '#!/usr/bin/env bash\n' >"$script"

	export RAW_SCRIPT_PATH="$script"

	run_validator

	assert_failure
	assert_output --partial "version-update-script resolves outside the workspace"
}

@test "validate-version-update-script: rejects symlink to script outside workspace" {
	local outside="$BATS_TEST_TMPDIR/outside.sh"
	local script="$GITHUB_WORKSPACE/scripts/ci/update-version.sh"
	printf '#!/usr/bin/env bash\n' >"$outside"
	ln -s "$outside" "$script"

	export RAW_SCRIPT_PATH="$script"

	run_validator

	assert_failure
	assert_output --partial "version-update-script resolves outside the workspace"
}
