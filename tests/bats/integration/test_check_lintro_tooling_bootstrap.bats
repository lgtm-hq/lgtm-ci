#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for check-lintro-tooling-bootstrap script

load "../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/quality/check-lintro-tooling-bootstrap.sh"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "check-lintro-tooling-bootstrap: reports no fallback when scripts exist" {
	local root="${BATS_TEST_TMPDIR}/tooling"
	mkdir -p "${root}/scripts/ci/quality"
	touch "${root}/scripts/ci/quality/resolve-lintro-image.sh"
	touch "${root}/scripts/ci/quality/validate-lintro-version.sh"

	run bash -c '
		export RESOLVE_SCRIPT="'"${root}"'/scripts/ci/quality/resolve-lintro-image.sh"
		export VALIDATE_SCRIPT="'"${root}"'/scripts/ci/quality/validate-lintro-version.sh"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	run grep -F "needs-fallback=false" "$GITHUB_OUTPUT"
	assert_success
}

@test "check-lintro-tooling-bootstrap: reports fallback when scripts are missing" {
	run bash -c '
		export RESOLVE_SCRIPT="'"${BATS_TEST_TMPDIR}"'/missing-resolve.sh"
		export VALIDATE_SCRIPT="'"${BATS_TEST_TMPDIR}"'/missing-validate.sh"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	run grep -F "needs-fallback=true" "$GITHUB_OUTPUT"
	assert_success
}
